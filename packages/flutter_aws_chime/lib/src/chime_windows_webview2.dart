import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_webview2_runtime.dart';

/// Internal Windows port of the macOS WebKit -> Chime MethodChannel protocol.
///
/// This Windows bridge is enabled by default but requires a working runtime;
/// successful JS execution is not evidence of a supported AWS media call.
class ChimeWindowsWebview2Transport {
  ChimeWindowsWebview2Transport(
    this.onNativeCall, {
    AwsWindowsWebView2Runtime? runtime,
  }) : _runtime = runtime ?? AwsWindowsWebView2Runtime.instance;

  static const int _localScreenTileId = -2;
  final FutureOr<void> Function(MethodCall) onNativeCall;
  final AwsWindowsWebView2Runtime _runtime;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  final _devices = <Map<String, dynamic>>[];
  String? _selectedCameraId;
  String? _localAttendeeId;
  Map<String, Map<String, dynamic>> _participants = {};
  Map<String, Map<String, dynamic>> _tracks = {};

  void reserve() {
    _subscription ??= _runtime.events.listen(_onEvent);
  }

  void release() {
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    _subscription = null;
    _selectedCameraId = null;
    _localAttendeeId = null;
    _runtime.clearSelectedScreenShareSource();
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
          _localAttendeeId = args['AttendeeId']?.toString().trim();
          await _runtime.invoke('invoke', name: 'create', payload: payload);
          try {
            await _runtime.invoke('invoke', name: 'join');
          } catch (_) {
            _localAttendeeId = null;
            await _runtime
                .invoke('invoke', name: 'dispose')
                .catchError((Object _) => null);
            rethrow;
          }
          return _success();
        case 'stop':
          _localAttendeeId = null;
          try {
            await _runtime.stopScreenShareCapture();
          } catch (_) {}
          _runtime.clearSelectedScreenShareSource();
          try {
            await _runtime.detachProcessedVideoSource();
          } catch (_) {}
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
          final devices = await _fetchNormalizedDevices();
          _devices
            ..clear()
            ..addAll(devices);
          return _success(
            _devices
                .where((d) => d['kind'] == 'audioOutput')
                .map((d) => d['label']?.toString() ?? '')
                .where((label) => label.isNotEmpty)
                .toList(growable: false),
          );
        case 'listMediaDevices':
          final devices = await _fetchNormalizedDevices();
          _devices
            ..clear()
            ..addAll(devices);
          return _success(devices);
        case 'initialAudioSelection':
          final first = _devices
              .where((d) => d['kind'] == 'audioOutput')
              .map((d) => d['label']?.toString() ?? '')
              .where((label) => label.isNotEmpty);
          return _success(first.isEmpty ? null : first.first);
        case 'updateAudioDevice':
          final label = rawArguments?.toString() ?? '';
          if (_devices.isEmpty) {
            _devices.addAll(await _fetchNormalizedDevices());
          }
          final candidates = _devices.where(
            (d) => d['kind'] == 'audioOutput' && d['label'] == label,
          );
          if (candidates.isEmpty) {
            return _failure('invalid_argument', 'Unknown Chime audio output.');
          }
          await _command('selectAudioOutput', candidates.first);
          return _success();
        case 'selectDevice':
          final device = args['device'];
          if (device is Map && device['kind']?.toString() == 'camera') {
            _selectedCameraId = device['id']?.toString();
          }
          await _command('selectDevice', args);
          return _success();
        case 'sendMessage':
          await _command('sendMessage', args);
          return _success();
        case 'listScreenShareSources':
          final sources = await _runtime.listScreenShareSources();
          return _success(sources);
        case 'selectScreenShareSource':
          final sourceId = args['id']?.toString().trim() ?? '';
          if (sourceId.isEmpty) {
            return _failure(
              'invalid_argument',
              'Screen share source id is required.',
            );
          }
          _runtime.selectScreenShareSource(sourceId);
          return _success();
        case 'setScreenShareEnabled':
          final enabled = args['enabled'] == true;
          if (!enabled) {
            try {
              await _command('setScreenShareEnabled', {'enabled': false});
            } finally {
              _removeLocalScreenTracks();
              await _runtime.stopScreenShareCapture();
            }
            return _success();
          }
          final sourceId = await _runtime.startScreenShareCapture();
          try {
            await _command('setScreenShareEnabled', {
              'enabled': true,
              'processedSourceId': sourceId,
            });
          } catch (_) {
            await _runtime.stopScreenShareCapture();
            rethrow;
          }
          _ensureLocalScreenTrackPublished();
          return _success();
        case 'setCameraPosition':
          final devices = await _fetchNormalizedDevices();
          _devices
            ..clear()
            ..addAll(devices);
          final cameras = _devices
              .where((d) => d['kind'] == 'camera')
              .toList(growable: false);
          if (cameras.isEmpty) {
            return _failure(
              'method_not_implemented',
              'No camera device is available on Windows.',
            );
          }
          final desired = (args['position']?.toString().toLowerCase() == 'back')
              ? 'back'
              : 'front';
          final byLabel = cameras.cast<Map<String, dynamic>?>().firstWhere(
            (c) =>
                (c!['label']?.toString().toLowerCase() ?? '').contains(desired),
            orElse: () => null,
          );
          final target =
              byLabel ??
              cameras.firstWhere(
                (c) => c['id']?.toString() != _selectedCameraId,
                orElse: () => cameras.first,
              );
          _selectedCameraId = target['id']?.toString();
          await _command('selectDevice', {'device': target});
          return _success();
        case 'probeProcessedVideoInput':
          final supported = await _runtime.probeProcessedVideoInput();
          return _success(supported);
        case 'attachProcessedVideoSource':
          final sourceId = args['sourceId']?.toString().trim() ?? '';
          if (sourceId.isEmpty) {
            return _failure(
              'invalid_argument',
              'A processed video sourceId is required.',
            );
          }
          await _runtime.attachProcessedVideoSource(sourceId);
          return _success();
        case 'detachProcessedVideoSource':
          await _runtime.detachProcessedVideoSource();
          return _success();
        default:
          return _failure(
            'method_not_implemented',
            'Chime Windows does not implement $method.',
          );
      }
    } catch (error) {
      return _failure('native_error', error.toString());
    }
  }

  Future<List<Map<String, dynamic>>> _fetchNormalizedDevices() async {
    final raw = await _command('listDevices', const {});
    final decoded = raw is String
        ? (raw.trim().isEmpty ? const <Object?>[] : _tryDecodeList(raw))
        : (raw is List ? raw : const <Object?>[]);
    final result = <Map<String, dynamic>>[];
    final countsByKind = <String, int>{};
    for (final item in decoded) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final kind = map['kind']?.toString() ?? '';
      final id = map['id']?.toString() ?? '';
      if (kind.isEmpty || id.isEmpty) continue;
      final index = (countsByKind[kind] ?? 0) + 1;
      countsByKind[kind] = index;
      var label = map['label']?.toString().trim() ?? '';
      if (label.isEmpty) {
        label = switch (kind) {
          'audioOutput' =>
            id == 'default' || index == 1
                ? 'System Default Speaker'
                : 'Speaker $index',
          'microphone' =>
            id == 'default' || index == 1
                ? 'System Default Microphone'
                : 'Microphone $index',
          'camera' => index == 1 ? 'Default Camera' : 'Camera $index',
          _ => '$kind $index',
        };
      }
      result.add({...map, 'id': id, 'label': label, 'kind': kind});
    }
    return result;
  }

  List<Object?> _tryDecodeList(String raw) {
    try {
      final parsed = jsonDecode(raw);
      return parsed is List ? parsed : const <Object?>[];
    } catch (_) {
      return const <Object?>[];
    }
  }

  Future<dynamic> _command(String name, Map<String, dynamic> args) => _runtime
      .invoke('invoke', name: 'command', payload: {'name': name, 'args': args});

  Map<String, dynamic> _chimePayload(Map<String, dynamic> data) {
    const required = [
      'MeetingId',
      'ExternalMeetingId',
      'MediaRegion',
      'AudioHostUrl',
      'AudioFallbackUrl',
      'SignalingUrl',
      'TurnControlUrl',
      'ExternalUserId',
      'AttendeeId',
      'JoinToken',
    ];
    if (required.any((field) => (data[field]?.toString() ?? '').isEmpty)) {
      throw const FormatException('Chime join credentials are incomplete.');
    }
    final displayName = (data['DisplayName']?.toString().trim() ?? '');
    return {
      'provider': 'chime',
      'participantId': data['AttendeeId'],
      'displayName': displayName.isNotEmpty
          ? displayName
          : data['ExternalUserId'],
      'role': 'participant',
      'meeting': {
        'MeetingId': data['MeetingId'],
        'ExternalMeetingId': data['ExternalMeetingId'],
        'MediaRegion': data['MediaRegion'],
        'MediaPlacement': {
          for (final key in [
            'AudioHostUrl',
            'AudioFallbackUrl',
            'SignalingUrl',
            'TurnControlUrl',
          ])
            key: data[key],
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
    unawaited(Future<void>.sync(() => onNativeCall(MethodCall(name, args))));
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
        if (event['state'] == 'ended' || event['state'] == 'disconnected') {
          _emit('audioSessionDidStop');
        }
      case 'snapshot':
        _onSnapshot(event);
      case 'screenCaptureStopped':
        _removeLocalScreenTracks();
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
        // Only treat pre-join signaling failures as session termination; live
        // call feature errors (such as cancelled screen capture) must not drop
        // an active meeting, while genuine disconnects emit state='ended'.
        if (_participants.isEmpty) {
          _emit('meetingEvent', {
            'type': 'audioSessionStopped',
            'statusCode': event['message']?.toString() ?? 'native_error',
          });
        }
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
      final old = _tracks[entry.key];
      if (old == null) {
        _emit('videoTileAdd', _tile(entry.key, entry.value));
      } else {
        final oldW = (old['width'] as num?)?.toInt() ?? 0;
        final oldH = (old['height'] as num?)?.toInt() ?? 0;
        final newW = (entry.value['width'] as num?)?.toInt() ?? 0;
        final newH = (entry.value['height'] as num?)?.toInt() ?? 0;
        if (oldW != newW || oldH != newH) {
          _emit('meetingEvent', {
            'type': 'videoTileSizeChanged',
            'videoTile': _tile(entry.key, entry.value),
          });
        }
      }
    }
    for (final entry in _tracks.entries) {
      if (!tracks.containsKey(entry.key)) {
        _emit('videoTileRemove', _tile(entry.key, entry.value));
      }
    }
    _tracks = tracks;
  }

  void _ensureLocalScreenTrackPublished() {
    final localId = _localAttendeeId;
    if (localId == null || localId.isEmpty) return;
    final trackKey = 'chime:screen:$localId';
    if (_tracks.containsKey(trackKey)) return;
    final entry = <String, dynamic>{
      'id': trackKey,
      'participantId': localId,
      'width': _runtime.localScreenWidth,
      'height': _runtime.localScreenHeight,
      'isLocal': true,
      'isScreenShare': true,
    };
    _tracks = {..._tracks, trackKey: entry};
    _emit('videoTileAdd', _tile(trackKey, entry));
  }

  void _removeLocalScreenTracks() {
    final removed = <MapEntry<String, Map<String, dynamic>>>[];
    final remaining = <String, Map<String, dynamic>>{};
    for (final entry in _tracks.entries) {
      if (entry.value['isScreenShare'] == true &&
          entry.value['isLocal'] == true) {
        removed.add(entry);
      } else {
        remaining[entry.key] = entry.value;
      }
    }
    if (removed.isEmpty) return;
    _tracks = remaining;
    for (final entry in removed) {
      _emit('videoTileRemove', _tile(entry.key, entry.value));
    }
  }

  Map<String, dynamic> _tile(String id, Map<String, dynamic> value) {
    final isLocalScreen =
        value['isLocal'] == true && value['isScreenShare'] == true;
    return {
      'tileId': isLocalScreen
          ? _localScreenTileId
          : (int.tryParse(id.split(':').last) ?? id.hashCode),
      'attendeeId': value['participantId'] ?? '',
      'videoStreamContentWidth': value['width'] ?? 0,
      'videoStreamContentHeight': value['height'] ?? 0,
      'isLocalTile': value['isLocal'] == true,
      'isContent': value['isScreenShare'] == true,
    };
  }

  Map<String, dynamic> _success([Object? data]) => {
    'success': true,
    'data': data,
  };
  Map<String, dynamic> _failure(String code, String message) => {
    'success': false,
    'code': code,
    'message': message,
  };
}
