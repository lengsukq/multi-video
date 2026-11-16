import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_realtime_chat_core/flutter_realtime_chat_core.dart';

import 'ivs_chat_engine.dart';
import 'ivs_chat_join_info.dart';

typedef IvsChatSocketConnector = Future<WebSocket> Function(
  Uri endpoint,
  String token,
);

Future<WebSocket> _connectIvsChatSocket(Uri endpoint, String token) =>
    WebSocket.connect(endpoint.toString(), protocols: [token]);

/// Windows Amazon IVS Chat transport using the public native WSS Messaging
/// API. It is separate from IVS Real-Time broadcast and needs no WebView2.
class WindowsIvsChatEngine implements IvsChatEngine {
  WindowsIvsChatEngine({IvsChatSocketConnector? connector})
      : _connector = connector ?? _connectIvsChatSocket;

  final IvsChatSocketConnector _connector;
  IvsChatJoinInfo? _info;
  IvsChatEngineEvents _events = const IvsChatEngineEvents();
  IvsChatTokenProvider? _tokenProvider;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  final _pending = <String, Completer<void>>{};
  final _seenMessages = <String>{};
  int _generation = 0;
  int _nextRequestId = 0;
  bool _active = false;
  bool _connected = false;
  bool _disposed = false;
  bool _reconnecting = false;

  static Uri endpointForRegion(String region) {
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(region)) {
      throw ArgumentError.value(region, 'region', 'Invalid IVS Chat region');
    }
    return Uri(scheme: 'wss', host: 'edge.ivschat.$region.amazonaws.com');
  }

  @override
  Future<void> connect(
    IvsChatJoinInfo info,
    IvsChatEngineEvents events, {
    IvsChatTokenProvider? tokenProvider,
  }) async {
    if (_disposed || _active) {
      throw StateError('IVS Chat Windows engine is disposed or already active.');
    }
    _active = true;
    _info = info;
    _tokenProvider = tokenProvider;
    _events = events;
    final generation = ++_generation;
    try {
      await _establish(info, generation, reconnecting: false);
    } catch (_) {
      _active = false;
      ++_generation;
      await _closeSocket();
      rethrow;
    }
  }

  Future<void> _establish(
    IvsChatJoinInfo info,
    int generation, {
    required bool reconnecting,
  }) async {
    if (!_active || _disposed || generation != _generation) {
      throw StateError('IVS Chat connection was cancelled.');
    }
    if (DateTime.now().millisecondsSinceEpoch >= info.tokenExpirationTimeMs) {
      throw StateError('The IVS Chat connection token has expired.');
    }
    _events.onConnecting?.call(reconnecting);
    final socket = await _connector(endpointForRegion(info.region), info.token)
        .timeout(const Duration(seconds: 20));
    if (!_active || _disposed || generation != _generation) {
      await socket.close();
      throw StateError('IVS Chat connection was cancelled.');
    }
    _socket = socket;
    _connected = true;
    _subscription = socket.listen(
      (dynamic data) => _handlePayload(data),
      onError: (Object _) => _handleClosed(generation),
      onDone: () => _handleClosed(generation),
      cancelOnError: true,
    );
    _events.onConnected?.call();
  }

  void _handleClosed(int generation) {
    if (!_active || generation != _generation) return;
    _connected = false;
    _failPending(StateError('IVS Chat connection was interrupted.'));
    if (_reconnecting) return;
    _reconnecting = true;
    unawaited(_reconnect(generation));
  }

  Future<void> _reconnect(int generation) async {
    try {
      for (var attempt = 1; attempt <= 3; attempt++) {
        if (!_active || _disposed || generation != _generation) return;
        final provider = _tokenProvider;
        if (provider == null) break; // Do not reuse one-use IVS tokens.
        try {
          await Future<void>.delayed(Duration(seconds: attempt));
          if (!_active || _disposed || generation != _generation) return;
          final fresh = await provider();
          if (!_active || _disposed || generation != _generation) return;
          if (fresh.roomArn != _info?.roomArn || fresh.region != _info?.region) {
            throw StateError('Refreshed IVS Chat token changed chat room.');
          }
          await _closeSocket();
          await _establish(fresh, generation, reconnecting: true);
          _info = fresh;
          return;
        } catch (_) {
          // Retry only with another fresh backend-issued token.
        }
      }
      if (_active && !_disposed && generation == _generation) {
        _active = false;
        _events.onDisconnected?.call('reconnectFailed');
        _events.onError?.call(-1, 'IVS Chat reconnection failed.');
      }
    } finally {
      _reconnecting = false;
    }
  }

  void _handlePayload(dynamic data) {
    if (!_active || data is! String) return;
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map) return;
      final event = Map<String, dynamic>.from(decoded);
      final requestId = event['RequestId']?.toString() ?? '';
      switch (event['Type']) {
        case 'MESSAGE':
          final id = event['Id']?.toString() ?? '';
          final senderRaw = event['Sender'];
          if (id.isEmpty || senderRaw is! Map) return;
          final sender = Map<String, dynamic>.from(senderRaw);
          final userId = sender['UserId']?.toString() ?? '';
          if (userId.isEmpty) return;
          final attr = sender['Attributes'] is Map
              ? Map<String, dynamic>.from(sender['Attributes'] as Map)
              : const <String, dynamic>{};
          if (_seenMessages.add(id)) {
            if (_seenMessages.length > 2000) _seenMessages.clear();
            _events.onMessage?.call({
              'id': id,
              'userId': attr['userId']?.toString() ?? userId,
              'displayName': attr['displayName']?.toString() ?? userId,
              'message': event['Content']?.toString() ?? '',
              'timestampMs': DateTime.tryParse(
                  event['SendTime']?.toString() ?? '')?.millisecondsSinceEpoch ??
                  DateTime.now().millisecondsSinceEpoch,
              'attributes': {
                'providerUserId': userId,
                if (attr['avatarUrl'] != null)
                  'avatarUrl': attr['avatarUrl'].toString(),
                if (attr['participantId'] != null)
                  'participantId': attr['participantId'].toString(),
              },
            });
          }
          _finishPending(requestId);
        case 'EVENT':
          final attributes = event['Attributes'] is Map
              ? Map<String, dynamic>.from(event['Attributes'] as Map)
              : const <String, dynamic>{};
          switch (event['EventName']) {
            case 'DELETE_MESSAGE':
              final messageId = attributes['MessageID']?.toString() ?? '';
              if (messageId.isNotEmpty) _events.onMessageDeleted?.call(messageId);
            case 'DISCONNECT_USER':
              final userId = attributes['UserId']?.toString() ?? '';
              if (userId.isNotEmpty) _events.onUserDisconnected?.call(userId);
          }
          _finishPending(requestId);
        case 'ERROR':
          final code = (event['ErrorCode'] as num?)?.toInt() ?? -1;
          final pending = _pending.remove(requestId);
          if (pending != null && !pending.isCompleted) {
            pending.completeError(RealtimeException(
              code: code == 403 ? RealtimeErrorCode.forbidden :
                    code == 401 ? RealtimeErrorCode.unauthorized :
                    RealtimeErrorCode.providerError,
              message: 'IVS Chat rejected the requested operation ($code).',
              providerId: IvsChatJoinInfo.providerIdValue,
            ));
          } else {
            _events.onError?.call(code, 'IVS Chat reported an error ($code).');
          }
      }
    } catch (_) {
      _events.onError?.call(-1, 'IVS Chat returned a malformed message.');
    }
  }

  void _finishPending(String requestId) {
    final pending = _pending.remove(requestId);
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  Future<void> _send(String action, Map<String, Object?> values) async {
    final socket = _socket;
    if (!_active || !_connected || socket == null) {
      throw StateError('IVS Chat Windows engine is not connected.');
    }
    final id = 'chat-${DateTime.now().microsecondsSinceEpoch}-${++_nextRequestId}';
    final pending = Completer<void>();
    _pending[id] = pending;
    try {
      socket.add(jsonEncode({'Action': action, 'RequestId': id, ...values}));
      await pending.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw const RealtimeException(
          code: RealtimeErrorCode.timeout,
          providerId: IvsChatJoinInfo.providerIdValue,
          message: 'Amazon IVS Chat did not confirm the request in time.',
        ),
      );
    } finally {
      _pending.remove(id);
    }
  }

  @override
  Future<void> sendMessage(String message) {
    final info = _info;
    if (info == null) throw StateError('IVS Chat has no active room.');
    return _send('SEND_MESSAGE', {
      'Content': message,
      'Attributes': <String, String>{
        'userId': info.userId,
        'displayName': info.displayName,
        'participantId': info.participantId,
      },
    });
  }

  @override
  Future<void> deleteMessage(String messageId) =>
      _send('DELETE_MESSAGE', {'Id': messageId, 'Reason': 'Moderator action'});

  @override
  Future<void> disconnectUser(String userId) =>
      _send('DISCONNECT_USER', {'UserId': userId, 'Reason': 'Moderator action'});

  void _failPending(Object error) {
    for (final value in _pending.values) {
      if (!value.isCompleted) value.completeError(error);
    }
    _pending.clear();
  }

  Future<void> _closeSocket() async {
    await _subscription?.cancel();
    _subscription = null;
    final socket = _socket;
    _socket = null;
    _connected = false;
    if (socket != null) await socket.close(WebSocketStatus.normalClosure);
  }

  @override
  Future<void> disconnect() async {
    if (!_active && _socket == null) return;
    final wasActive = _active;
    _active = false;
    ++_generation;
    _failPending(StateError('IVS Chat was disconnected.'));
    await _closeSocket();
    if (wasActive) _events.onDisconnected?.call('clientDisconnect');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;
    _info = null;
    _tokenProvider = null;
    _seenMessages.clear();
  }
}
