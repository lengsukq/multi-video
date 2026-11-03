part of 'trtc_media_session.dart';

class _TrtcPublishing {
  _TrtcPublishing(this._session);
  final _TrtcSessionBase _session;
  String get providerId => _session.providerId;
  MediaCapabilities get capabilities => _session.capabilities;
  MediaRole get role => _session.role;
  MediaSessionState get state => _session.state;
  MediaSnapshot get snapshot => _session.snapshot;
  Duration get cleanupTimeout => _session.cleanupTimeout;

  final _processedSink = NativeProcessedVideoSink(providerId: 'trtc');
  bool supportsProcessedVideoSource(ProcessedVideoSource source) =>
      role != MediaRole.viewer &&
      capabilities.canBlurBackground &&
      _processedSink.supports(source) &&
      source.platform ==
          (defaultTargetPlatform == TargetPlatform.android
              ? ProcessedVideoPlatform.android
              : defaultTargetPlatform == TargetPlatform.iOS
              ? ProcessedVideoPlatform.ios
              : defaultTargetPlatform == TargetPlatform.windows
              ? ProcessedVideoPlatform.windows
              : ProcessedVideoPlatform.macos);
  Future<void> attachProcessedVideoSource(ProcessedVideoSource source) async {
    _session._requireConnected();
    if (!supportsProcessedVideoSource(source)) {
      throw const RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'Processed video is unavailable.',
      );
    }
    _session._engine!.stopLocalPreview();
    await _processedSink.attach(source);
  }

  Future<void> detachProcessedVideoSource() => _processedSink.detach();

  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async {
    _session._requireConnected();
    if (!capabilities.canEnumerateCameras ||
        (kinds != null && !kinds.contains(MediaDeviceKind.camera))) {
      return const [];
    }
    return List.unmodifiable([
      for (final camera in await ProcessedVideoBridge().listCameras())
        MediaDevice(
          id: camera.id,
          label: camera.label,
          kind: MediaDeviceKind.camera,
        ),
    ]);
  }

  Future<void> selectMediaDevice(MediaDevice device) async {
    _session._requireConnected();
    if (device.kind != MediaDeviceKind.camera ||
        !capabilities.canSelectCamera) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        providerId: providerId,
        message: 'This media device cannot be selected.',
      );
    }
    if (_processedSink.source == null) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        providerId: providerId,
        message: 'Prepare the SDK video source before selecting a camera.',
      );
    }
    await _processedSink.selectCamera(device.id);
  }

  Future<void> setMuted(bool muted) async {
    _session._requireConnected();
    try {
      _session._engine!.muteLocalAudio(muted);
      final info = _session._joinInfo!;
      final local = _session._mapper._findParticipant(info.userId);
      if (local != null) {
        _session._mapper._replaceParticipant(local.copyWith(isMuted: muted));
      }
      _session._setSnapshot(_session._snapshot.copyWith(localMuted: muted));
      _session._eventController.add(MediaLocalMediaChanged(muted: muted));
    } catch (error, stack) {
      throw _session._mapError(error, 'setMuted', stack: stack);
    }
  }

  Future<void> toggleMute() => setMuted(!_session._snapshot.localMuted);

  Future<void> setVideoEnabled(bool enabled) async {
    _session._requireConnected();
    if (_session._snapshot.localVideoEnabled == enabled) return;
    try {
      await _processedSink.setEnabled(enabled);
      _session._engine!.muteLocalVideo(!enabled);
      if (!enabled) _session._engine!.stopLocalPreview();
      final info = _session._joinInfo!;
      final local = _session._mapper._findParticipant(info.userId);
      TrtcMediaVideoTrack? track;
      if (enabled) {
        track = _session._mapper._makeVideoTrack(info.userId, local: true);
      }
      if (local != null) {
        _session._mapper._replaceParticipant(
          local.copyWith(
            clearVideoTrack: !enabled,
            videoTrack: track,
            isVideoEnabled: enabled,
          ),
        );
      }
      _session._setSnapshot(
        _session._snapshot.copyWith(localVideoEnabled: enabled),
      );
      if (track != null) {
        _session._eventController.add(MediaTrackPublished(track));
      }
      if (!enabled) {
        _session._eventController.add(
          MediaTrackUnpublished(
            trackId: 'trtc:${info.userId}:camera',
            participantId: info.userId,
          ),
        );
      }
      _session._eventController.add(
        MediaLocalMediaChanged(videoEnabled: enabled),
      );
    } catch (error, stack) {
      throw _session._mapError(error, 'setVideoEnabled', stack: stack);
    }
  }

  Future<void> setScreenShareEnabled(bool enabled) async {
    _session._requireConnected();
    if (!capabilities.canScreenShare) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'TRTC screen sharing is supported on Android and iOS only.',
        providerId: providerId,
      );
    }
    if (_session._snapshot.localScreenShareEnabled == enabled) return;
    try {
      if (enabled) {
        _session._engine!.startScreenCapture();
      } else {
        _session._engine!.stopScreenCapture();
      }
      _session._setSnapshot(
        _session._snapshot.copyWith(localScreenShareEnabled: enabled),
      );
    } catch (error, stack) {
      throw _session._mapError(error, 'screenShare', stack: stack);
    }
  }

  Future<void> switchCamera(MediaCameraPosition position) async {
    _session._requireConnected();
    try {
      if (_processedSink.source != null) {
        await _processedSink.selectCamera(
          position == MediaCameraPosition.front ? 'front' : 'back',
        );
        return;
      }
      final result = _session._engine!.switchCamera(
        position == MediaCameraPosition.front,
      );
      if (result < 0) {
        throw RealtimeException(
          code: RealtimeErrorCode.providerError,
          message: 'trtc.switchCamera failed.',
          details: {'code': result},
          providerId: providerId,
        );
      }
    } catch (error, stack) {
      throw _session._mapError(error, 'switchCamera', stack: stack);
    }
  }

  Future<List<MediaAudioDevice>> listAudioDevices() => Future.error(
    RealtimeException(
      code: RealtimeErrorCode.unsupportedFeature,
      message:
          'TRTC audio-device enumeration is not supported by this adapter.',
      providerId: providerId,
    ),
  );

  Future<void> selectAudioDevice(MediaAudioDevice device) => Future.error(
    RealtimeException(
      code: RealtimeErrorCode.unsupportedFeature,
      message: 'TRTC audio-device selection is not supported by this adapter.',
      providerId: providerId,
    ),
  );
}
