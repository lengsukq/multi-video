import 'dart:async';
import 'dart:convert';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'provider_web_bridge.dart';
import 'provider_web_track.dart';
import 'provider_web_decoding.dart';
import 'provider_web_snapshot_decoder.dart';

abstract class ProviderWebSessionBase
    implements
        MediaSession,
        MediaDeviceController,
        MediaStatsProvider,
        MediaDataMessenger {
  ProviderWebSessionBase({
    required this.providerId,
    required this.role,
    required this.sessionId,
    required this.joinPayload,
    required MediaCapabilities capabilities,
  }) : _capabilities = capabilities,
       _snapshot = MediaSnapshot(role: role, capabilities: capabilities);

  @override
  final String providerId;

  @override
  final MediaRole role;

  final String sessionId;
  final Map<String, Object?> joinPayload;
  final MediaCapabilities _capabilities;

  MediaSnapshot _snapshot;
  MediaConnectionStats? _connectionStats;
  MediaBackgroundEffect _backgroundEffect = const MediaBackgroundEffect.none();
  ProcessedVideoSource? _processedVideoSource;
  bool _disposed = false;
  Future<void>? _joinFuture;
  RealtimeException? _joiningFailure;
  Future<void>? _leaveFuture;
  Future<void>? _disposeFuture;

  final Map<String, ProviderWebVideoTrack> _tracks = {};
  final StreamController<MediaSessionState> _stateController =
      StreamController<MediaSessionState>.broadcast();
  final StreamController<MediaSnapshot> _snapshotController =
      StreamController<MediaSnapshot>.broadcast();
  final StreamController<MediaEvent> _eventController =
      StreamController<MediaEvent>.broadcast();
  final StreamController<MediaConnectionStats> _statsController =
      StreamController<MediaConnectionStats>.broadcast();

  @override
  MediaCapabilities get capabilities => _capabilities;

  @override
  MediaSessionState get state => _snapshot.state;

  @override
  MediaSnapshot get snapshot => _snapshot;

  @override
  Stream<MediaSessionState> get states => _stateController.stream;

  @override
  Stream<MediaSnapshot> get snapshots => _snapshotController.stream;

  @override
  Stream<MediaEvent> get events => _eventController.stream;

  @override
  MediaConnectionStats? get connectionStats => _connectionStats;

  MediaBackgroundCapabilities get backgroundCapabilities =>
      MediaBackgroundCapabilities(
        canBlur: capabilities.canBlurBackground,
        canReplaceImage: capabilities.canReplaceBackgroundImage,
      );

  MediaBackgroundEffect get backgroundEffect => _backgroundEffect;

  Future<void> setBackgroundEffect(MediaBackgroundEffect effect) async {
    _ensureActive();
    if (!capabilities.canBlurBackground &&
        effect.type == MediaBackgroundEffectType.none) {
      _backgroundEffect = effect;
      return;
    }
    if (!backgroundCapabilities.supports(effect)) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message:
            '$providerId does not support the requested SDK video effect '
            'for this role or browser.',
        providerId: providerId,
      );
    }
    if (_backgroundEffect == effect) return;
    final source = _processedVideoSource;
    if (source == null) {
      if (effect.type == MediaBackgroundEffectType.none) {
        _backgroundEffect = effect;
        return;
      }
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message:
            'Attach an SDK processed video source before applying '
            'background effects.',
        providerId: providerId,
      );
    }
    await _command('setProcessedVideoEffect', {
      'sourceId': source.id,
      ...effect.toJson(),
    });
    _backgroundEffect = effect;
  }

  bool supportsProcessedVideoSourceInternal(ProcessedVideoSource source) =>
      const {'agora', 'trtc', 'artc', 'chime', 'ivs'}.contains(providerId) &&
      role != MediaRole.viewer &&
      source.platform == ProcessedVideoPlatform.web &&
      source.kind == ProcessedVideoSourceKind.mediaStreamTrack;

  Future<void> attachProcessedVideoSourceInternal(
    ProcessedVideoSource source,
  ) async {
    _ensureActive();
    if (!supportsProcessedVideoSourceInternal(source)) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message:
            '$providerId cannot publish the supplied SDK processed '
            'video source on Web.',
        providerId: providerId,
      );
    }
    await _command('attachProcessedVideoSource', {'sourceId': source.id});
    _processedVideoSource = source;
  }

  Future<void> detachProcessedVideoSourceInternal() async {
    if (_processedVideoSource == null) return;
    if (state == MediaSessionState.connected ||
        state == MediaSessionState.reconnecting) {
      await _command('detachProcessedVideoSource', const {});
    }
    _processedVideoSource = null;
    _backgroundEffect = const MediaBackgroundEffect.none();
  }

  @override
  Stream<MediaConnectionStats> get stats => _statsController.stream;

  @override
  Future<void> join(MediaJoinInfo joinInfo) {
    final current = _joinFuture;
    if (current != null) return current;
    late final Future<void> future;
    future = _join(joinInfo).whenComplete(() {
      if (identical(_joinFuture, future)) _joinFuture = null;
    });
    _joinFuture = future;
    return future;
  }

  Future<void> _join(MediaJoinInfo joinInfo) async {
    _ensureNotDisposed();
    if (joinInfo.providerId != providerId ||
        joinInfo.role != role ||
        joinInfo.roomCode.isEmpty ||
        joinInfo.participantId.isEmpty) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Join information does not match this $providerId session.',
        providerId: providerId,
      );
    }
    if (state != MediaSessionState.idle &&
        state != MediaSessionState.ended &&
        state != MediaSessionState.failed) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'This $providerId session is already active.',
        providerId: providerId,
      );
    }
    _joiningFailure = null;
    _setState(MediaSessionState.joining);
    try {
      ProviderWebBridge.registerHandler(sessionId, _onBridgeEvent);
      await ProviderWebBridge.create(
        providerId: providerId,
        sessionId: sessionId,
        joinPayload: joinInfo.payload,
      );
      _setState(MediaSessionState.connecting);
      await ProviderWebBridge.join(providerId, sessionId);
      _ensureNotDisposed();
      final failure = _joiningFailure;
      if (failure != null) throw failure;
      if (state == MediaSessionState.connecting) {
        _setState(MediaSessionState.connected);
      }
      _updateSnapshot(_snapshot.copyWith(clearLastError: true));
    } catch (error) {
      final mapped = _mapError('Unable to join the $providerId room.', error);
      if (!_disposed) {
        _setState(MediaSessionState.failed, error: mapped);
        _emit(MediaFailureEvent(mapped));
      }
      final cleanup = Cleanup();
      await cleanup.run(
        'bridge.join.rollback',
        () => ProviderWebBridge.dispose(providerId, sessionId),
      );
      cleanup.finish(domain: 'media.web', cause: mapped);
      throw mapped;
    }
  }

  @override
  Future<void> leave() {
    final current = _leaveFuture;
    if (current != null) return current;
    late final Future<void> future;
    future = _leave().whenComplete(() {
      if (identical(_leaveFuture, future)) _leaveFuture = null;
    });
    _leaveFuture = future;
    return future;
  }

  Future<void> _leave() async {
    if (_disposed ||
        state == MediaSessionState.ended ||
        state == MediaSessionState.idle) {
      return;
    }
    _setState(MediaSessionState.leaving);
    try {
      await ProviderWebBridge.leave(providerId, sessionId);
      _tracks.clear();
      _setState(MediaSessionState.ended);
      _updateSnapshot(
        _snapshot.copyWith(
          participants: const [],
          localMuted: true,
          localVideoEnabled: false,
          clearLocalParticipantId: true,
          clearContentShareTrack: true,
        ),
      );
    } catch (error) {
      final mapped = _mapError('Unable to leave the $providerId room.', error);
      _setState(MediaSessionState.failed, error: mapped);
      _emit(MediaFailureEvent(mapped));
      throw mapped;
    }
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    final cleanup = Cleanup();
    if (state.isActive || state == MediaSessionState.connecting) {
      await cleanup.run(
        'bridge.leave',
        () => ProviderWebBridge.leave(providerId, sessionId),
      );
    }
    await cleanup.run(
      'bridge.dispose',
      () => ProviderWebBridge.dispose(providerId, sessionId),
    );
    _setState(MediaSessionState.disposed);
    await cleanup.run('states', _stateController.close);
    await cleanup.run('snapshots', _snapshotController.close);
    await cleanup.run('events', _eventController.close);
    await cleanup.run('stats', _statsController.close);
    cleanup.finish(domain: providerId);
  }

  Future<void> setMuted(bool muted) async {
    _ensureActive();
    _requireCapability(capabilities.canPublishAudio, 'microphone control');
    await _command('setMuted', {'muted': muted});
    _updateSnapshot(_snapshot.copyWith(localMuted: muted));
    _emit(MediaLocalMediaChanged(muted: muted));
  }

  Future<void> toggleMute() => setMuted(!_snapshot.localMuted);

  Future<void> setVideoEnabled(bool enabled) async {
    _ensureActive();
    _requireCapability(capabilities.canPublishVideo, 'camera control');
    await _command('setVideoEnabled', {'enabled': enabled});
    _updateSnapshot(_snapshot.copyWith(localVideoEnabled: enabled));
    _emit(MediaLocalMediaChanged(videoEnabled: enabled));
  }

  Future<void> setScreenShareEnabled(bool enabled) async {
    _ensureActive();
    _requireCapability(capabilities.canScreenShare, 'screen sharing');
    await _command('setScreenShareEnabled', {'enabled': enabled});
  }

  Future<void> switchCamera(MediaCameraPosition position) async {
    _ensureActive();
    _requireCapability(capabilities.canSwitchCamera, 'camera switching');
    await _command('switchCamera', {'position': position.name});
  }

  Future<List<MediaAudioDevice>> listAudioDevices() async {
    _ensureActive();
    _requireCapability(capabilities.canEnumerateAudioDevices, 'audio devices');
    final devices = await listMediaDevices(
      kinds: const {MediaDeviceKind.audioOutput},
    );
    return devices
        .map(
          (device) =>
              MediaAudioDevice.fromLabel(device.label).copyWithId(device.id),
        )
        .toList(growable: false);
  }

  Future<void> selectAudioDevice(MediaAudioDevice device) async {
    _ensureActive();
    _requireCapability(
      capabilities.canSelectAudioOutput,
      'audio output selection',
    );
    await _command('selectAudioOutput', {
      'id': device.id,
      'label': device.label,
    });
  }

  @override
  Future<void> sendMessage(String message, {String topic = 'chat'}) async {
    _ensureActive();
    _requireCapability(capabilities.canSendData, 'sending data messages');
    if (message.trim().isEmpty || topic.trim().isEmpty) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Message and topic must not be empty.',
        providerId: providerId,
      );
    }
    await _command('sendMessage', {
      'message': message,
      'topic': topic,
      'lifetimeMs': 300000,
    });
  }

  @override
  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async {
    _ensureNotDisposed();
    _requireCapability(
      capabilities.canEnumerateMicrophones ||
          capabilities.canEnumerateCameras ||
          capabilities.canEnumerateAudioDevices,
      'device enumeration',
    );
    final requested = kinds ?? MediaDeviceKind.values.toSet();
    final values = await ProviderWebBridge.listDevices(providerId, sessionId);
    return values
        .map(_mediaDeviceFromJson)
        .where((device) => requested.contains(device.kind))
        .where(_deviceCanBeListed)
        .toList(growable: false);
  }

  @override
  Future<void> selectMediaDevice(MediaDevice device) async {
    _ensureActive();
    final supported = switch (device.kind) {
      MediaDeviceKind.microphone => capabilities.canSelectMicrophone,
      MediaDeviceKind.camera => capabilities.canSelectCamera,
      MediaDeviceKind.audioOutput => capabilities.canSelectAudioOutput,
    };
    _requireCapability(supported, '${device.kind.name} selection');
    await ProviderWebBridge.selectDevice(providerId, sessionId, {
      'id': device.id,
      'label': device.label,
      'kind': device.kind.name,
    });
  }

  MediaDevice _mediaDeviceFromJson(Map<String, Object?> json) {
    final kindName = json['kind']?.toString();
    final kind = switch (kindName) {
      'microphone' || 'audioinput' => MediaDeviceKind.microphone,
      'camera' || 'videoinput' => MediaDeviceKind.camera,
      'audioOutput' || 'audiooutput' => MediaDeviceKind.audioOutput,
      _ => MediaDeviceKind.camera,
    };
    return MediaDevice(
      id: json['id']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      kind: kind,
      groupId: json['groupId']?.toString(),
    );
  }

  bool _deviceCanBeListed(MediaDevice device) => switch (device.kind) {
    MediaDeviceKind.microphone => capabilities.canEnumerateMicrophones,
    MediaDeviceKind.camera => capabilities.canEnumerateCameras,
    MediaDeviceKind.audioOutput => capabilities.canEnumerateAudioDevices,
  };

  void _onBridgeEvent(String eventSessionId, Map<String, dynamic> event) {
    if (_disposed || eventSessionId != sessionId) return;
    switch (event['type']?.toString()) {
      case 'state':
        final next = webSessionState(event['state']?.toString());
        if (next != null) _setState(next, reason: event['reason']?.toString());
        break;
      case 'snapshot':
        _updateFromBridgeSnapshot(event);
        break;
      case 'stats':
        _updateStats(event);
        break;
      case 'message':
        if (event['throttled'] == true) break;
        final message = MediaMessage(
          participantId: event['participantId']?.toString() ?? '',
          displayName: event['displayName']?.toString() ?? '',
          message: event['message']?.toString() ?? '',
          topic: event['topic']?.toString() ?? 'chat',
          timestampMs:
              (event['timestampMs'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
          providerId: providerId,
        );
        _updateSnapshot(
          _snapshot.copyWith(messages: [..._snapshot.messages, message]),
        );
        _emit(MediaMessageReceived(message));
        break;
      case 'warning':
        final warningCode = event['code']?.toString() ?? 'warning';
        final warning = RealtimeException(
          code: RealtimeErrorCode.providerError,
          message: event['message']?.toString() ?? 'provider warning',
          providerId: providerId,
          domain: 'media.web',
          operation: warningCode,
          recoverable: true,
          suggestedAction: warningCode == 'audio-autoplay-blocked'
              ? 'interact-to-unmute-audio'
              : 'retry',
        );
        _emit(MediaFailureEvent(warning));
        break;
      case 'error':
        final supplied = event['error'];
        final error = supplied is RealtimeException
            ? supplied.withProvider(providerId)
            : ProviderWebBridge.mapFailure(
                providerId,
                'web.bridge.event',
                event['message']?.toString() ?? 'provider error',
                operation: 'event',
              );
        if (_joinFuture != null ||
            state == MediaSessionState.joining ||
            state == MediaSessionState.connecting) {
          _joiningFailure = error;
        }
        _setState(MediaSessionState.failed, error: error);
        _emit(MediaFailureEvent(error));
        break;
    }
  }

  void _updateFromBridgeSnapshot(Map<String, dynamic> event) {
    final update = decodeProviderWebSnapshot(
      providerId: providerId,
      sessionId: sessionId,
      event: event,
      previous: _snapshot,
      previousTracks: _tracks,
    );
    _tracks
      ..clear()
      ..addAll(update.tracks);
    for (final change in update.events) {
      _emit(change);
    }
    _updateSnapshot(update.snapshot);
  }

  void _updateStats(Map<String, dynamic> event) {
    if (!capabilities.canReportNetworkStats) return;
    final stats = MediaConnectionStats(
      timestampMs:
          webInt(event['timestampMs']) ?? DateTime.now().millisecondsSinceEpoch,
      upstreamQuality: webNetworkQuality(event['upstreamQuality']),
      downstreamQuality: webNetworkQuality(event['downstreamQuality']),
      rttMs: webInt(event['rttMs']),
      uplinkPacketLossPercent: webDouble(event['uplinkPacketLossPercent']),
      downlinkPacketLossPercent: webDouble(event['downlinkPacketLossPercent']),
      uploadKbps: webInt(event['uploadKbps']),
      downloadKbps: webInt(event['downloadKbps']),
      jitterMs: webInt(event['jitterMs']),
    );
    _connectionStats = stats;
    if (!_statsController.isClosed) _statsController.add(stats);
    _emit(MediaNetworkStatsUpdated(stats));
  }

  void _setState(
    MediaSessionState next, {
    String? reason,
    RealtimeException? error,
  }) {
    if (state == next) return;
    final previous = state;
    _updateSnapshot(
      _snapshot.copyWith(
        state: next,
        lastError: error,
        clearLastError: error == null && next != MediaSessionState.failed,
      ),
    );
    if (!_stateController.isClosed) _stateController.add(next);
    _emit(
      MediaConnectionStateChanged(
        previous: previous,
        current: next,
        reason: reason,
      ),
    );
  }

  void _updateSnapshot(MediaSnapshot value) {
    _snapshot = value;
    if (!_snapshotController.isClosed) _snapshotController.add(value);
  }

  void _emit(MediaEvent event) {
    if (!_eventController.isClosed) _eventController.add(event);
  }

  Future<void> _command(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    _ensureActive();
    final response = await _rawCommand(name, args);
    if (response.isNotEmpty) {
      try {
        final decoded = jsonDecode(response);
        if (decoded is Map && decoded['snapshot'] is Map) {
          _updateFromBridgeSnapshot(
            Map<String, dynamic>.from(decoded['snapshot'] as Map),
          );
        }
      } catch (error, stack) {
        throw normalizeRealtimeException(
          error,
          domain: 'media.web',
          operation: 'bridge.decode',
          providerId: providerId,
          stackTrace: stack,
        );
      }
    }
  }

  Future<String> _rawCommand(String name, Map<String, Object?> args) async =>
      ProviderWebBridge.command(providerId, sessionId, name, args);

  void _ensureActive() {
    _ensureNotDisposed();
    if (!state.isActive) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message:
            'Cannot control $providerId media while the session is $state.',
        providerId: providerId,
      );
    }
  }

  void _ensureNotDisposed() {
    if (_disposed || state == MediaSessionState.disposed) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'This $providerId session has been disposed.',
        providerId: providerId,
      );
    }
  }

  void _requireCapability(bool supported, String feature) {
    if (!supported) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message:
            '$providerId $feature is not supported in this browser session.',
        providerId: providerId,
      );
    }
  }

  RealtimeException _mapError(String fallback, Object error) {
    if (error is RealtimeException) return error.withProvider(providerId);
    return RealtimeException(
      code: error.toString().toLowerCase().contains('permission')
          ? RealtimeErrorCode.permissionDenied
          : RealtimeErrorCode.providerError,
      message: fallback,
      details: error,
      providerId: providerId,
    );
  }
}
