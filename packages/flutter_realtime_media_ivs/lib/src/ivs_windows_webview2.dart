import 'dart:async';
import 'dart:convert';

import 'package:flutter_realtime_media_aws_desktop/aws_windows_webview2_runtime.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'ivs_engine.dart';
import 'ivs_join_info.dart';

/// Windows IVS Stage via an explicitly opted-in *unsupported by AWS* WebView2
/// experiment. This bridge must never advertise production capability.
class WindowsIvsWebView2Engine implements IvsEngine {
  WindowsIvsWebView2Engine({AwsWindowsWebView2Runtime? runtime})
    : _runtime = runtime ?? AwsWindowsWebView2Runtime.ivs,
      _ownsRuntime = runtime != null;

  final AwsWindowsWebView2Runtime _runtime;
  final bool _ownsRuntime;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  IvsEngineEvents _events = const IvsEngineEvents();
  final Map<String, Map<String, dynamic>> _participants = {};
  final Set<String> _videoParticipants = {};
  Map<String, dynamic>? _joinPayload;
  String? _localUserId;
  bool _localMuted = true;
  bool _localVideoEnabled = false;
  Map<String, dynamic>? _selectedMicrophone;
  Map<String, dynamic>? _selectedCamera;
  bool _joined = false;
  bool _disposed = false;
  bool _reconnecting = false;
  bool _exchangingToken = false;

  @override
  Future<void> join(IvsJoinInfo info, IvsEngineEvents events) async {
    if (_disposed || _joined) {
      throw StateError('IVS Windows Stage is disposed or already joined.');
    }
    _events = events;
    _localUserId = info.participantId;
    _localMuted = true;
    _localVideoEnabled = false;
    final payload = <String, dynamic>{
      'provider': 'ivs',
      'participantId': info.participantId,
      'displayName': info.displayName,
      'role': info.role.wireName,
      'ivs': <String, dynamic>{
        'token': info.token,
        'stageArn': info.stageArn,
        'tokenParticipantId': info.tokenParticipantId,
        'capabilities': info.capabilities,
        'expiresAtMs': info.expiresAtMs,
        if (info.region != null) 'region': info.region,
      },
    };
    _joinPayload = payload;
    _subscription ??= _runtime.events.listen(_onEvent);
    try {
      await _runtime.invoke('invoke', name: 'create', payload: payload);
      try {
        await _runtime.invoke('invoke', name: 'join');
        _joined = true;
      } catch (_) {
        await _runtime
            .invoke('invoke', name: 'dispose')
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
  Future<void> exchangeToken(String token) async {
    if (!_joined || _disposed || _joinPayload == null) {
      throw StateError('IVS Windows Stage is inactive.');
    }
    final nextToken = token.trim();
    if (nextToken.isEmpty) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        providerId: 'ivs',
        message: 'Missing refreshed IVS token.',
      );
    }
    final wasMuted = _localMuted;
    final wasVideoEnabled = _localVideoEnabled;
    final ivsBlock = Map<String, dynamic>.from(
      _joinPayload!['ivs'] as Map<Object?, Object?>,
    )..['token'] = nextToken;
    final updatedPayload = <String, dynamic>{
      ..._joinPayload!,
      'ivs': ivsBlock,
    };
    _joinPayload = updatedPayload;
    _exchangingToken = true;
    try {
      await _runtime
          .invoke('invoke', name: 'leave')
          .catchError((Object _) => null);
      await _runtime
          .invoke('invoke', name: 'dispose')
          .catchError((Object _) => null);
      if (_disposed) return;
      await _runtime.invoke('invoke', name: 'create', payload: updatedPayload);
      await _runtime.invoke('invoke', name: 'join');
    } finally {
      _exchangingToken = false;
    }
    if (_selectedMicrophone != null) {
      await _command('selectDevice', {'device': _selectedMicrophone});
    }
    if (_selectedCamera != null) {
      await _command('selectDevice', {'device': _selectedCamera});
    }
    if (!wasMuted) await setMuted(false);
    if (wasVideoEnabled) await setVideoEnabled(true);
  }

  @override
  Future<void> setMuted(bool muted) async {
    await _command('setMuted', {'muted': muted});
    _localMuted = muted;
  }

  @override
  Future<void> setVideoEnabled(bool enabled) async {
    await _command('setVideoEnabled', {'enabled': enabled});
    _localVideoEnabled = enabled;
  }

  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async {
    if (!_joined || _disposed) {
      throw StateError('IVS Windows Stage is inactive.');
    }
    final raw = await _command('listDevices', const {});
    final decoded = raw is String
        ? (raw.trim().isEmpty ? const <Object?>[] : _tryDecodeList(raw))
        : (raw is List ? raw : const <Object?>[]);
    final requested = kinds ?? MediaDeviceKind.values.toSet();
    final devices = <MediaDevice>[];
    final counts = <MediaDeviceKind, int>{};
    for (final item in decoded) {
      if (item is! Map) continue;
      final kind = switch (item['kind']?.toString()) {
        'camera' => MediaDeviceKind.camera,
        'microphone' => MediaDeviceKind.microphone,
        'audioOutput' => MediaDeviceKind.audioOutput,
        _ => null,
      };
      final id = item['id']?.toString() ?? '';
      if (kind == null || id.isEmpty || !requested.contains(kind)) continue;
      final index = (counts[kind] ?? 0) + 1;
      counts[kind] = index;
      var label = item['label']?.toString().trim() ?? '';
      if (label.isEmpty) {
        label = switch (kind) {
          MediaDeviceKind.camera =>
            index == 1 ? 'Default Camera' : 'Camera $index',
          MediaDeviceKind.microphone =>
            index == 1 ? 'System Default Microphone' : 'Microphone $index',
          MediaDeviceKind.audioOutput =>
            index == 1 ? 'System Default Speaker' : 'Speaker $index',
        };
      }
      devices.add(MediaDevice(id: id, label: label, kind: kind));
    }
    return List.unmodifiable(devices);
  }

  Future<void> selectMediaDevice(MediaDevice device) async {
    final serialized = <String, Object?>{
      'id': device.id,
      'label': device.label,
      'kind': switch (device.kind) {
        MediaDeviceKind.camera => 'camera',
        MediaDeviceKind.microphone => 'microphone',
        MediaDeviceKind.audioOutput => 'audioOutput',
      },
    };
    if (device.kind == MediaDeviceKind.microphone) {
      _selectedMicrophone = serialized;
    } else if (device.kind == MediaDeviceKind.camera) {
      _selectedCamera = serialized;
    }
    await _command('selectDevice', {'device': serialized});
  }

  List<Object?> _tryDecodeList(String raw) {
    try {
      final parsed = jsonDecode(raw);
      return parsed is List ? parsed : const <Object?>[];
    } catch (_) {
      return const <Object?>[];
    }
  }

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

  Future<dynamic> _command(String name, Map<String, Object?> args) {
    if (!_joined || _disposed) {
      return Future<dynamic>.error(
        StateError('IVS Windows Stage is inactive.'),
      );
    }
    return _runtime.invoke(
      'invoke',
      name: 'command',
      payload: {'name': name, 'args': args},
    );
  }

  void _onEvent(Map<String, dynamic> event) {
    if (_disposed) return;
    switch (event['type']) {
      case 'state':
        final state = event['state'];
        if (state == 'reconnecting' || state == 'connecting') {
          if (!_reconnecting) _events.onReconnecting?.call();
          _reconnecting = true;
        } else if (state == 'connected') {
          if (_reconnecting) _events.onRecovered?.call();
          _reconnecting = false;
        } else if ((state == 'ended' || state == 'disconnected') &&
            !_exchangingToken &&
            _joined) {
          _joined = false;
          _reconnecting = false;
          _events.onDisconnected?.call();
        }
      case 'snapshot':
        _onSnapshot(event);
      case 'stats':
        _events.onStats?.call(Map<String, Object?>.from(event));
      case 'error':
        _events.onError?.call(
          -1,
          event['message']?.toString() ?? 'IVS Web Stage reported an error.',
        );
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
            id,
            p['displayName']?.toString() ?? id,
          );
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
        if (item is! Map ||
            item['isLocal'] == true ||
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
      if (_ownsRuntime) {
        await _runtime.dispose();
      }
    }
  }
}
