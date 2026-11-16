import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_webview2_runtime.dart';

/// Internal Windows port of the macOS WebKit -> Chime MethodChannel protocol.
///
/// This Windows bridge is enabled by default but requires a working runtime;
/// successful JS execution is not evidence of a supported AWS media call.
class ChimeWindowsWebview2Transport {
  ChimeWindowsWebview2Transport(this.onNativeCall);

  final FutureOr<void> Function(MethodCall) onNativeCall;
  final _runtime = AwsWindowsWebView2Runtime.instance;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  final _devices = <Map<String, dynamic>>[];
  Map<String, Map<String, dynamic>> _participants = {};
  Map<String, Map<String, dynamic>> _tracks = {};

  void reserve() {
    _subscription ??= _runtime.events.listen(_onEvent);
  }

  void release() {
    _subscription?.cancel();
    _subscription = null;
    _participants = {};
    _tracks = {};
    _devices.clear();
  }

  Future<Map<String, dynamic>> invoke(
    String method,
    Object? rawArguments,
  ) async {
    try {
      final args = rawArguments is Map
          ? Map<String, dynamic>.from(rawArguments)
          : const <String, dynamic>{};
      switch (method) {
        case 'manageAudioPermissions':
        case 'manageVideoPermissions':
          // Permission is requested by Chromium on actual device capture.
          // Do not silently request or grant camera access from pre-join.
          return _success();
        case 'join':
          final payload = _chimePayload(args);
          await _runtime.invoke('invoke', name: 'create', payload: payload);
          try {
            await _runtime.invoke('invoke', name: 'join');
          } catch (_) {
            await _runtime.invoke('invoke', name: 'dispose')
                .catchError((Object _) => null);
            rethrow;
          }
          return _success();
        case 'stop':
          try {
            await _runtime.invoke('invoke', name: 'leave');
          } finally {
            await _runtime.invoke('invoke', name: 'dispose');
          }
          return _success();
        case 'mute':
        case 'unmute':
          await _command('setMuted', {'muted': method == 'mute'});
          return _success();
        case 'startLocalVideo':
        case 'stopLocalVideo':
          await _command('setVideoEnabled', {
            'enabled': method == 'startLocalVideo',
          });
          return _success();
        case 'listAudioDevices':
          final raw = await _command('listDevices', const {});
          _devices
            ..clear()
            ..addAll(raw is List
                ? raw.whereType<Map>()
                    .map((e) => Map<String, dynamic>.from(e))
                : const <Map<String, dynamic>>[]);
          return _success(
            _devices.where((d) => d['kind'] == 'audioOutput')
                .map((d) => d['label']?.toString() ?? '')
                .where((label) => label.isNotEmpty)
                .toList(growable: false),
          );
        case 'initialAudioSelection':
          final first = _devices.where((d) => d['kind'] == 'audioOutput');
          return _success(
            first.isEmpty ? null : first.first['label']?.toString(),
          );
        case 'updateAudioDevice':
          final label = rawArguments?.toString() ?? '';
          final candidates = _devices.where((d) =>
              d['kind'] == 'audioOutput' && d['label'] == label);
          if (candidates.isEmpty) {
            return _failure('invalid_argument', 'Unknown Chime audio output.');
          }
          await _command('selectAudioOutput', candidates.first);
          return _success();
        case 'sendMessage':
          await _command('sendMessage', args);
          return _success();
        case 'setCameraPosition':
        case 'probeProcessedVideoInput':
        case 'attachProcessedVideoSource':
          return _failure('method_not_implemented',
              'Chime Windows WebView2 does not support this native feature.');
        default:
          return _failure('method_not_implemented',
              'Chime Windows does not implement $method.');
      }
    } catch (error) {
      return _failure('native_error', error.toString());
    }
  }

  Future<dynamic> _command(String name, Map<String, dynamic> args) =>
      _runtime.invoke('invoke', name: 'command',
          payload: {'name': name, 'args': args});

  Map<String, dynamic> _chimePayload(Map<String, dynamic> data) {
    const required = [
      'MeetingId', 'ExternalMeetingId', 'MediaRegion',
      'AudioHostUrl', 'AudioFallbackUrl', 'SignalingUrl',
      'TurnControlUrl', 'ExternalUserId', 'AttendeeId', 'JoinToken',
    ];
    if (required.any((field) => (data[field]?.toString() ?? '').isEmpty)) {
      throw const FormatException('Chime join credentials are incomplete.');
    }
    return {
      'provider': 'chime',
      'participantId': data['AttendeeId'],
      'displayName': data['ExternalUserId'],
      'role': 'participant',
      'meeting': {
        'MeetingId': data['MeetingId'],
        'ExternalMeetingId': data['ExternalMeetingId'],
        'MediaRegion': data['MediaRegion'],
        'MediaPlacement': {
          for (final key in [
            'AudioHostUrl', 'AudioFallbackUrl',
            'SignalingUrl', 'TurnControlUrl',
          ]) key: data[key],
        },
      },
      'attendee': {
        'ExternalUserId': data['ExternalUserId'],
        'AttendeeId': data['AttendeeId'],
        'JoinToken': data['JoinToken'],
      },
    };
  }

  void _emit(String name, [Map<String, dynamic>? args]) {
    unawaited(Future<void>.sync(() =>
        onNativeCall(MethodCall(name, args))));
  }

  void _onEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'state':
        final name = switch (event['state']) {
          'connecting' => 'audioSessionConnecting',
          'connected' => 'audioSessionStarted',
          'reconnecting' => 'audioSessionDropped',
          'ended' || 'disconnected' => 'audioSessionStopped',
          _ => null,
        };
        if (name != null) _emit('meetingEvent', {'type': name});
        if (event['state'] == 'ended' ||
            event['state'] == 'disconnected') {
          _emit('audioSessionDidStop');
        }
      case 'snapshot':
        _onSnapshot(event);
      case 'message':
        if (event['throttled'] == true) return;
        _emit('messageReceived', {
          'attendeeId': event['participantId'] ?? '',
          'externalUserId': event['displayName'] ?? '',
          'message': event['message'] ?? '',
          'topic': event['topic'] ?? 'chat',
          'timestampMs': event['timestampMs'] ?? 0,
          'throttled': false,
        });
      case 'error':
        _emit('meetingEvent', {
          'type': 'audioSessionStopped',
          'statusCode': 'native_error',
        });
    }
  }

  Map<String, Map<String, dynamic>> _index(dynamic values) {
    if (values is! List) return {};
    final indexed = <String, Map<String, dynamic>>{};
    for (final entry in values) {
      if (entry is! Map) continue;
      final value = Map<String, dynamic>.from(entry);
      final id = value['id']?.toString() ?? '';
      if (id.isNotEmpty) indexed[id] = value;
    }
    return indexed;
  }

  void _onSnapshot(Map<String, dynamic> next) {
    final participants = _index(next['participants']);
    for (final entry in participants.entries) {
      final id = entry.key;
      if (!_participants.containsKey(id)) {
        _emit('join', {
          'attendeeId': id,
          'externalUserId': entry.value['displayName'] ?? id,
        });
      }
      final muted = entry.value['isMuted'] == true;
      if (_participants[id]?['isMuted'] != muted) {
        _emit(muted ? 'mute' : 'unmute', {'attendeeId': id});
      }
    }
    for (final id in _participants.keys) {
      if (!participants.containsKey(id)) _emit('leave', {'attendeeId': id});
    }
    _participants = participants;

    final tracks = _index(next['tracks']);
    for (final entry in tracks.entries) {
      if (!_tracks.containsKey(entry.key)) {
        _emit('videoTileAdd', _tile(entry.key, entry.value));
      }
    }
    for (final entry in _tracks.entries) {
      if (!tracks.containsKey(entry.key)) {
        _emit('videoTileRemove', _tile(entry.key, entry.value));
      }
    }
    _tracks = tracks;
  }

  Map<String, dynamic> _tile(String id, Map<String, dynamic> value) {
    return {
      'tileId': int.tryParse(id.split(':').last) ?? id.hashCode,
      'attendeeId': value['participantId'] ?? '',
      'videoStreamContentWidth': value['width'] ?? 0,
      'videoStreamContentHeight': value['height'] ?? 0,
      'isLocalTile': value['isLocal'] == true,
      'isContent': value['isScreenShare'] == true,
    };
  }

  Map<String, dynamic> _success([Object? data]) =>
      {'success': true, 'data': data};
  Map<String, dynamic> _failure(String code, String message) =>
      {'success': false, 'code': code, 'message': message};
}
