import 'dart:async';

import 'package:flutter_realtime_media_aws_desktop/aws_windows_webview2_runtime.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'ivs_engine.dart';
import 'ivs_join_info.dart';

/// Windows IVS Stage via an explicitly opted-in *unsupported by AWS* WebView2
/// experiment. This bridge must never advertise production capability.
class WindowsIvsWebView2Engine implements IvsEngine {
  WindowsIvsWebView2Engine({AwsWindowsWebView2Runtime? runtime})
      : _runtime = runtime ?? AwsWindowsWebView2Runtime.ivs;

  final AwsWindowsWebView2Runtime _runtime;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  IvsEngineEvents _events = const IvsEngineEvents();
  final Map<String, Map<String, dynamic>> _participants = {};
  final Set<String> _videoParticipants = {};
  String? _localUserId;
  bool _joined = false;
  bool _disposed = false;
  bool _reconnecting = false;

  @override
  Future<void> join(IvsJoinInfo info, IvsEngineEvents events) async {
    if (_disposed || _joined) {
      throw StateError('IVS Windows Stage is disposed or already joined.');
    }
    _events = events;
    _localUserId = info.participantId;
    _subscription ??= _runtime.events.listen(_onEvent);
    try {
      await _runtime.invoke('invoke', name: 'create', payload: {
        'provider': 'ivs',
        'participantId': info.participantId,
        'displayName': info.displayName,
        'role': info.role.wireName,
        'ivs': {
          'token': info.token,
          'stageArn': info.stageArn,
          'tokenParticipantId': info.tokenParticipantId,
          'capabilities': info.capabilities,
          'expiresAtMs': info.expiresAtMs,
          if (info.region != null) 'region': info.region,
        },
      });
      try {
        await _runtime.invoke('invoke', name: 'join');
        _joined = true;
      } catch (_) {
        await _runtime.invoke('invoke', name: 'dispose')
            .catchError((Object _) => null);
        rethrow;
      }
    } catch (_) {
      await _subscription?.cancel();
      _subscription = null;
      rethrow;
    }
  }

  @override
  Future<void> exchangeToken(String token) =>
      _command('exchangeToken', {'token': token});

  @override
  Future<void> setMuted(bool muted) => _command('setMuted', {'muted': muted});

  @override
  Future<void> setVideoEnabled(bool enabled) =>
      _command('setVideoEnabled', {'enabled': enabled});

  @override
  Future<void> switchCamera(MediaCameraPosition position) async {
    throw const RealtimeException(
      code: RealtimeErrorCode.unsupportedFeature,
      providerId: 'ivs',
      message: 'IVS Windows camera position switching is not implemented.',
    );
  }

  @override
  Future<void> requestStats() async {
    // The JS Stage bridge asynchronously emits its own available metrics.
    // Never fabricate stats when the Web SDK does not expose them.
  }

  Future<void> _command(String name, Map<String, Object?> args) async {
    if (!_joined || _disposed) throw StateError('IVS Windows Stage is inactive.');
    await _runtime.invoke('invoke', name: 'command', payload: {
      'name': name,
      'args': args,
    });
  }

  void _onEvent(Map<String, dynamic> event) {
    if (_disposed) return;
    switch (event['type']) {
      case 'state':
        final state = event['state'];
        if (state == 'reconnecting' || state == 'disconnected') {
          if (!_reconnecting) _events.onReconnecting?.call();
          _reconnecting = true;
        } else if (state == 'connected') {
          if (_reconnecting) _events.onRecovered?.call();
          _reconnecting = false;
        }
      case 'snapshot':
        _onSnapshot(event);
      case 'stats':
        _events.onStats?.call(Map<String, Object?>.from(event));
      case 'error':
        _events.onError?.call(-1,
            event['message']?.toString() ?? 'IVS Web Stage reported an error.');
    }
  }

  void _onSnapshot(Map<String, dynamic> event) {
    final current = <String, Map<String, dynamic>>{};
    final rawParticipants = event['participants'];
    if (rawParticipants is List) {
      for (final item in rawParticipants) {
        if (item is! Map) continue;
        final p = Map<String, dynamic>.from(item);
        final id = p['id']?.toString() ?? '';
        if (id.isEmpty || id == _localUserId || p['isLocal'] == true) continue;
        current[id] = p;
        if (!_participants.containsKey(id)) {
          _events.onParticipantJoined?.call(
            id, p['displayName']?.toString() ?? id);
        }
        final oldMuted = _participants[id]?['isMuted'];
        final muted = p['isMuted'] == true;
        if (oldMuted == null || oldMuted != muted) {
          _events.onRemoteAudioChanged?.call(id, !muted);
        }
      }
    }
    final videos = <String>{};
    final rawTracks = event['tracks'];
    if (rawTracks is List) {
      for (final item in rawTracks) {
        if (item is! Map || item['isLocal'] == true ||
            item['isScreenShare'] == true) {
          continue;
        }
        final id = item['participantId']?.toString() ?? '';
        if (current.containsKey(id)) videos.add(id);
      }
    }
    for (final id in current.keys) {
      final hadVideo = _videoParticipants.contains(id);
      if (hadVideo != videos.contains(id)) {
        _events.onRemoteVideoChanged?.call(id, videos.contains(id));
      }
    }
    for (final id in _participants.keys) {
      if (current.containsKey(id)) continue;
      if (_videoParticipants.contains(id)) {
        _events.onRemoteVideoChanged?.call(id, false);
      }
      _events.onParticipantLeft?.call(id);
    }
    _participants
      ..clear()
      ..addAll(current);
    _videoParticipants
      ..clear()
      ..addAll(videos);
  }

  @override
  Future<void> leave() async {
    if (!_joined) return;
    _joined = false;
    try {
      await _runtime.invoke('invoke', name: 'leave');
    } finally {
      _participants.clear();
      _videoParticipants.clear();
      _reconnecting = false;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    try {
      await leave();
    } finally {
      _disposed = true;
      await _subscription?.cancel();
      _subscription = null;
      try {
        await _runtime.invoke('invoke', name: 'dispose');
      } catch (_) {
        // The browser might already have torn down the Stage.
      }
      await _runtime.dispose();
    }
  }
}
