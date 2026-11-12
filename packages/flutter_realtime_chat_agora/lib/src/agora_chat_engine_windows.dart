import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import 'agora_chat_engine.dart';
import 'agora_chat_join_info.dart';

Future<AgoraChatEngine> createWindowsAgoraChatEngine() async =>
    WindowsAgoraChatEngine();

/// Windows Chat integration using the existing bundled Agora Chat JavaScript
/// provider in an isolated HTTPS WebView2 host. The Agora Flutter plugin does
/// not provide Windows native bindings.
///
/// Transport boot checks are NOT proof of chat credential acceptance or real
/// room message delivery; those require a genuine two-client test.
class WindowsAgoraChatEngine implements AgoraChatEngine {
  static const _channel = 'agora-chat-windows-v1';
  static const _origin = 'https://agora-chat-local.invalid';
  static int _sequence = 0;
  static WindowsAgoraChatEngine? _owner;

  final String _sessionId =
      'agora-windows-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
  WebviewController? _controller;
  Directory? _assets;
  StreamSubscription<dynamic>? _subscription;
  Future<void>? _startup;
  int _nextCallId = 0;
  final _pending = <int, Completer<dynamic>>{};
  AgoraChatJoinInfo? _info;
  AgoraChatEngineEvents _events = const AgoraChatEngineEvents();
  AgoraChatTokenProvider? _tokenProvider;
  bool _ready = false;
  bool _created = false;
  bool _connected = false;
  bool _disposed = false;
  bool _joining = false;
  bool _disconnectRequested = false;
  int _generation = 0;

  /// Verifies that the real native WebView2 instance can load Agora's bundled
  /// JavaScript provider and the Windows event/RPC bridge.
  Future<bool> probe() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return false;
    try {
      await (_startup ??= _initialize());
      return _ready;
    } catch (_) {
      _startup = null;
      return false;
    }
  }

  Future<void> _initialize() async {
    if (_disposed) throw StateError('Agora Chat Windows engine is disposed.');
    if (await WebviewController.getWebViewVersion() == null) {
      throw StateError('Microsoft Edge WebView2 Runtime is not installed.');
    }
    final directory =
        await Directory.systemTemp.createTemp('agora-chat-windows-');
    _assets = directory;
    WebviewController? browser;
    try {
      for (final entry in {
        'agora-chat-provider.js':
            'packages/flutter_realtime_provider_agora_chat/assets/agora-chat-provider.js',
        'windows_agora_chat_host.js':
            'packages/flutter_realtime_chat_agora/assets/windows_agora_chat_host.js',
      }.entries) {
        final content = await rootBundle.loadString(entry.value);
        await File('${directory.path}${Platform.pathSeparator}${entry.key}')
            .writeAsString(content, flush: true);
      }
      await File('${directory.path}${Platform.pathSeparator}index.html')
          .writeAsString('''
<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy"
 content="default-src 'self' https: wss: data: blob:;
 script-src 'self' 'unsafe-eval' 'unsafe-inline' https:;
 connect-src 'self' https: wss:; style-src 'self' 'unsafe-inline';">
</head><body><script src="agora-chat-provider.js"></script>
<script src="windows_agora_chat_host.js"></script></body></html>
''', flush: true);
      browser = WebviewController();
      await browser.initialize();
      await browser.setSize(const Size(720, 420));
      await browser.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await browser.addVirtualHostNameMapping(
        'agora-chat-local.invalid',
        directory.path,
        WebviewHostResourceAccessKind.deny,
      );
      _subscription = browser.webMessage.listen(_onMessage);
      final loaded = browser.loadingState
          .firstWhere((state) => state == LoadingState.navigationCompleted)
          .timeout(const Duration(seconds: 30));
      await browser.loadUrl('$_origin/index.html');
      await loaded;
      final result = await browser.executeScript('''JSON.stringify({
        origin: location.origin,
        secure: isSecureContext,
        provider: typeof AgoraChatBridge !== 'undefined',
        host: globalThis.__agoraWindowsChatHost === '$_channel',
        events: typeof globalThis.__flutterAgoraChatOnEvent === 'function',
        tokens: typeof globalThis.__flutterAgoraChatRequestToken === 'function'
      })''');
      final decoded = result is String ? jsonDecode(result) : result;
      if (decoded is! Map ||
          decoded['origin'] != _origin ||
          decoded['secure'] != true ||
          decoded['provider'] != true ||
          decoded['host'] != true ||
          decoded['events'] != true ||
          decoded['tokens'] != true) {
        throw StateError(
          'Agora Chat Windows browser or bundled JavaScript bridge failed readiness.',
        );
      }
      _controller = browser;
      _ready = true;
    } catch (_) {
      await _subscription?.cancel();
      _subscription = null;
      try {
        await browser?.dispose();
      } catch (_) {}
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
      _assets = null;
      rethrow;
    }
  }

  Future<dynamic> _invoke(String operation, {
    String name = '',
    Map<String, Object?> payload = const {},
  }) async {
    if (!await probe() || _controller == null) {
      throw StateError(
        'Agora Chat WebView2 or its JavaScript bridge is unavailable. '
        'Check the WebView2 Runtime and bundled provider assets.',
      );
    }
    final id = ++_nextCallId;
    final pending = Completer<dynamic>();
    _pending[id] = pending;
    try {
      await _controller!.postWebMessage(jsonEncode({
        'channel': _channel,
        'id': id,
        'operation': operation,
        'sessionId': _sessionId,
        'name': name,
        'payload': payload,
      }));
      return await pending.future.timeout(const Duration(seconds: 35));
    } finally {
      _pending.remove(id);
    }
  }

  void _onMessage(dynamic value) {
    if (value is! Map || _disposed) return;
    final body = Map<String, dynamic>.from(value);
    if (body['channel'] != _channel) return;
    switch (body['kind']) {
      case 'result':
        final pending = _pending[body['id']];
        if (pending == null || pending.isCompleted) return;
        if (body['success'] == true) {
          pending.complete(body['value']);
        } else {
          pending.completeError(
            StateError(body['message']?.toString() ??
                'Agora Chat Windows JavaScript operation failed.'),
          );
        }
      case 'event':
        if (body['sessionId'] != _sessionId || body['payload'] is! Map) return;
        final event = Map<String, Object?>.from(body['payload'] as Map);
        switch (body['eventType']) {
          case 'connecting':
            _events.onConnecting?.call(event['reconnecting'] == true);
          case 'connected':
            if (_connected) _events.onConnected?.call();
          case 'disconnected':
            _events.onDisconnected?.call(
                event['reason']?.toString() ?? 'unknown');
          case 'message':
            _events.onMessage?.call(event);
          case 'messageDeleted':
            final id = event['messageId']?.toString() ?? '';
            if (id.isNotEmpty) _events.onMessageDeleted?.call(id);
          case 'userDisconnected':
            final id = event['userId']?.toString() ?? '';
            if (id.isNotEmpty) _events.onUserDisconnected?.call(id);
          case 'error':
            _events.onError?.call(
              (event['code'] as num?)?.toInt() ?? -1,
              event['message']?.toString() ?? 'Agora Chat reported an error.',
            );
        }
      case 'tokenRequest':
        if (body['sessionId'] != _sessionId || body['id'] is! int) return;
        unawaited(_refreshToken(body['id'] as int));
    }
  }

  Future<void> _refreshToken(int id) async {
    String? token;
    try {
      final provider = _tokenProvider;
      final info = _info;
      if (!_connected || _disposed || _disconnectRequested ||
          provider == null || info == null) {
        throw StateError('No active Agora Chat token refresh provider.');
      }
      final fresh = await provider();
      if (_disposed || _disconnectRequested || !_connected) return;
      if (fresh.appKey != info.appKey ||
          fresh.chatRoomId != info.chatRoomId ||
          fresh.providerUserId != info.providerUserId) {
        throw StateError('Agora Chat token refresh changed the room identity.');
      }
      token = fresh.token;
      _info = fresh;
    } catch (_) {}
    if (_disposed || _controller == null) return;
    try {
      await _controller!.postWebMessage(jsonEncode({
        'channel': _channel,
        'id': id,
        'operation': 'tokenResult',
        'success': token != null,
        if (token != null) 'token': token,
      }));
    } catch (_) {
      // A disposed WebView2 host has no pending token request to fulfill.
    }
  }

  void _ensureJoining(int generation) {
    if (_disposed || _disconnectRequested || generation != _generation) {
      throw StateError('Agora Chat Windows join was cancelled.');
    }
  }

  @override
  Future<void> connect(
    AgoraChatJoinInfo info,
    AgoraChatEngineEvents events, {
    AgoraChatTokenProvider? tokenProvider,
  }) async {
    if (_disposed || _connected || _created || _joining ||
        (_owner != null && !identical(_owner, this))) {
      throw StateError('Another Agora Chat Windows room is already active.');
    }
    _owner = this;
    _joining = true;
    _disconnectRequested = false;
    final generation = ++_generation;
    _events = events;
    _info = info;
    _tokenProvider = tokenProvider;
    try {
      await _invoke('create', payload: info.json);
      _created = true;
      _ensureJoining(generation);
      await _invoke('connect');
      _ensureJoining(generation);
      _connected = true;
      events.onConnected?.call();
    } catch (_) {
      await dispose();
      rethrow;
    } finally {
      _joining = false;
    }
  }

  @override
  Future<void> sendMessage(String message) {
    final info = _info;
    if (!_connected || info == null) {
      throw StateError('Agora Chat Windows room is not connected.');
    }
    return _invoke('command', name: 'sendMessage', payload: {
      'message': message,
      'userId': info.userId,
      'displayName': info.displayName,
      if (info.avatarUrl != null) 'avatarUrl': info.avatarUrl,
      'participantId': info.participantId,
    });
  }

  @override
  Future<void> deleteMessage(String messageId) async => throw UnsupportedError(
    'Agora Chat moderation is not enabled by this adapter.',
  );

  @override
  Future<void> disconnectUser(String userId) async => throw UnsupportedError(
    'Agora Chat moderation is not enabled by this adapter.',
  );

  @override
  Future<void> disconnect() async {
    _disconnectRequested = true;
    ++_generation;
    _connected = false;
    try {
      if (_created && _ready) {
        await _invoke('disconnect');
      }
    } finally {
      if (identical(_owner, this)) _owner = null;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disconnectRequested = true;
    ++_generation;
    try {
      if (_created && _ready) {
        try {
          await _invoke('dispose');
        } catch (_) {
          // Browser disposal must still reclaim the connection and resources.
        }
      }
    } finally {
      _disposed = true;
      _created = false;
      _connected = false;
      _ready = false;
      _info = null;
      _tokenProvider = null;
      if (identical(_owner, this)) _owner = null;
      for (final waiter in _pending.values) {
        if (!waiter.isCompleted) {
          waiter.completeError(StateError('Agora Chat browser was disposed.'));
        }
      }
      _pending.clear();
      await _subscription?.cancel();
      _subscription = null;
      try {
        await _controller?.dispose();
      } catch (_) {}
      _controller = null;
      try {
        await _assets?.delete(recursive: true);
      } catch (_) {}
      _assets = null;
    }
  }
}
