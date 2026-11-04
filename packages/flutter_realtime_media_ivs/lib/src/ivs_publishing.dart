part of 'ivs_media_session.dart';

class _IvsPublishing {
  _IvsPublishing(this._session);
  final _IvsMediaSession _session;
  String get providerId => _session.providerId;
  MediaCapabilities get capabilities => _session.capabilities;
  MediaRole get role => _session.role;
  MediaSessionState get state => _session.state;
  MediaSnapshot get snapshot => _session.snapshot;
  Duration get cleanupTimeout => _session.cleanupTimeout;

  static const _iosChannel = MethodChannel(
    'com.oneplusdream.flutter_realtime_media_ivs/methods',
  );
  ProcessedVideoSource? _iosScreenSource;

  Future<void> _stopIosScreenCapture() async {
    if (_iosScreenSource == null) return;
    _iosScreenSource = null;
    try {
      await _iosChannel.invokeMethod<void>('detachIosScreenCaptureKitSource');
    } finally {
      await IosSystemScreenCapture.instance.stop();
      _session._setSnapshot(
        _session._snapshot.copyWith(
          localScreenShareEnabled: false,
          clearContentShareTrack: true,
        ),
      );
    }
  }

  Future<void> _onIosScreenStopped() async {
    if (_iosScreenSource != null) await _stopIosScreenCapture();
  }

  Future<void> _setScreenShareEnabled(bool enabled) async {
    _session._requireActive();
    _session._requireCapability(capabilities.canScreenShare, 'screen sharing');
    if ((_iosScreenSource != null) == enabled) return;
    if (!enabled) {
      await _stopIosScreenCapture();
      return;
    }
    final capture = IosSystemScreenCapture.instance;
    if (!await capture.isAvailable) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'IVS full-display sharing requires iOS 27+.',
        providerId: providerId,
      );
    }
    ProcessedVideoSource? source;
    try {
      source = await capture.start();
      await _iosChannel.invokeMethod<void>('attachIosScreenCaptureKitSource', {
        'sourceId': source.id,
      });
      _iosScreenSource = source;
      capture.onSystemStopped(_onIosScreenStopped);
      // IVS Stage permits one video stream per token. Screen sharing replaces
      // camera video; stop restores the existing camera stream/mute setting.
      _session._setSnapshot(
        _session._snapshot.copyWith(localScreenShareEnabled: true),
      );
    } catch (_) {
      if (source != null) {
        try {
          await _iosChannel.invokeMethod<void>(
            'detachIosScreenCaptureKitSource',
          );
        } catch (_) {
          // The native start failure remains the primary error.
        }
      }
      await capture.stop();
      rethrow;
    }
  }

  MediaCameraPosition _cameraPosition = MediaCameraPosition.front;
  bool _macEffectsInputAvailable = false;
  bool get _effectsPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          (defaultTargetPlatform == TargetPlatform.macOS &&
              _macEffectsInputAvailable));
  Future<void> _probeProcessedVideoInput() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return;
    try {
      _macEffectsInputAvailable =
          await MethodChannel(
            _processedSink.channelName,
          ).invokeMethod<bool>('probeProcessedVideoInput') ??
          false;
    } on MissingPluginException {
      _macEffectsInputAvailable = false;
    } on PlatformException {
      _macEffectsInputAvailable = false;
    }
  }

  final _processedSink = NativeProcessedVideoSink(
    providerId: 'ivs',
    channelName: 'com.oneplusdream.flutter_realtime_media_ivs/methods',
    attachMethod: 'attachProcessedVideoSource',
    detachMethod: 'detachProcessedVideoSource',
  );
  bool supportsProcessedVideoSource(ProcessedVideoSource source) =>
      capabilities.canPublishVideo &&
      _effectsPlatform &&
      _processedSink.supports(source) &&
      source.platform ==
          (defaultTargetPlatform == TargetPlatform.android
              ? ProcessedVideoPlatform.android
              : ProcessedVideoPlatform.macos);
  Future<void> attachProcessedVideoSource(ProcessedVideoSource source) async {
    _session._requireActive();
    if (!supportsProcessedVideoSource(source)) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        providerId: providerId,
        message:
            'Processed video input is unavailable for this role or platform.',
      );
    }
    await _processedSink.attach(source);
  }

  Future<void> detachProcessedVideoSource() => _processedSink.detach();

  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async {
    _session._requireActive();
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
    _session._requireActive();
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

  Future<void> _setMuted(bool muted) async {
    _session._requireActive();
    _session._requireCapability(
      capabilities.canPublishAudio,
      'publishing audio',
    );
    await _session._engine!.setMuted(muted);
    _session._setSnapshot(_session._snapshot.copyWith(localMuted: muted));
    _session._emit(MediaLocalMediaChanged(muted: muted));
  }

  Future<void> _setVideoEnabled(bool enabled) async {
    _session._requireActive();
    _session._requireCapability(
      capabilities.canPublishVideo,
      'publishing video',
    );
    await _processedSink.setEnabled(enabled);
    await _session._engine!.setVideoEnabled(enabled);
    final info = _session._joinInfo!;
    final track = enabled
        ? IvsMediaVideoTrack(
            userId: info.participantId,
            local: true,
            generation: _session._mapper._trackGeneration,
          )
        : null;
    _session._setSnapshot(
      _session._snapshot.copyWith(
        participants: _session._snapshot.participants
            .map(
              (item) => item.isLocal
                  ? item.copyWith(
                      isVideoEnabled: enabled,
                      videoTrack: track,
                      clearVideoTrack: !enabled,
                    )
                  : item,
            )
            .toList(),
        localVideoEnabled: enabled,
      ),
    );
    if (enabled) {
      _session._emit(MediaTrackPublished(track!));
    } else {
      _session._emit(
        MediaTrackUnpublished(
          trackId:
              'ivs:${info.participantId}:camera:${_session._mapper._trackGeneration}',
          participantId: info.participantId,
        ),
      );
    }
    _session._emit(MediaLocalMediaChanged(videoEnabled: enabled));
  }

  Future<void> _switchCamera(MediaCameraPosition position) async {
    _session._requireActive();
    _session._requireCapability(
      capabilities.canSwitchCamera,
      'switching cameras',
    );
    if (_cameraPosition == position) return;
    if (_processedSink.source != null) {
      await _processedSink.selectCamera(
        position == MediaCameraPosition.front ? 'front' : 'back',
      );
    } else {
      await _session._engine!.switchCamera(position);
    }
    _cameraPosition = position;
    _session._mapper._trackGeneration++;
    final info = _session._joinInfo;
    if (_session._snapshot.localVideoEnabled && info != null) {
      final track = IvsMediaVideoTrack(
        userId: info.participantId,
        local: true,
        generation: _session._mapper._trackGeneration,
      );
      _session._setSnapshot(
        _session._snapshot.copyWith(
          participants: _session._snapshot.participants
              .map(
                (item) => item.isLocal
                    ? item.copyWith(videoTrack: track, isVideoEnabled: true)
                    : item,
              )
              .toList(),
        ),
      );
      _session._emit(MediaTrackPublished(track));
    }
  }
}
