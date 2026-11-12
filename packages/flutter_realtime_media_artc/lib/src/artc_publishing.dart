part of 'artc_media_session.dart';

class _ArtcPublishing {
  _ArtcPublishing(this._session);
  final _ArtcMediaSession _session;

  Future<List<MediaScreenShareSource>> listScreenShareSources() {
    _session._requireActive();
    final engine = _session._engine;
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.windows ||
        engine is! ArtcDesktopScreenCapture) {
      throw const RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        providerId: ArtcJoinInfo.providerIdValue,
        message: 'ARTC desktop source selection is unavailable here.',
      );
    }
    return (engine as ArtcDesktopScreenCapture).listDesktopScreenSources();
  }

  Future<void> selectScreenShareSource(MediaScreenShareSource source) async {
    await listScreenShareSources();
    final engine = _session._engine as ArtcDesktopScreenCapture;
    await engine.selectDesktopScreenSource(source);
  }
  String get providerId => _session.providerId;
  MediaCapabilities get capabilities => _session.capabilities;
  MediaRole get role => _session.role;
  MediaSessionState get state => _session.state;
  MediaSnapshot get snapshot => _session.snapshot;
  Duration get cleanupTimeout => _session.cleanupTimeout;

  ArtcMediaVideoTrack? _localScreenTrack;
  bool _screenShareEnabled = false;
  ProcessedVideoSource? _iosScreenCaptureSource;
  static const _iosNativeChannel = MethodChannel(
    'com.oneplusdream.flutter_realtime_media_artc/methods',
  );

  Future<void> _startIosSystemScreenCapture() async {
    final capture = IosSystemScreenCapture.instance;
    if (!await capture.isAvailable) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        providerId: providerId,
        message:
            'ARTC cross-app screen sharing without an extension requires iOS 27+.',
      );
    }
    ProcessedVideoSource? source;
    try {
      source = await capture.start();
      await _iosNativeChannel.invokeMethod<void>(
        'attachIosScreenCaptureKitSource',
        {'sourceId': source.id},
      );
      _iosScreenCaptureSource = source;
      capture.onSystemStopped(_onIosSystemScreenCaptureStopped);
    } catch (_) {
      try {
        await _iosNativeChannel.invokeMethod<void>(
          'detachIosScreenCaptureKitSource',
        );
      } finally {
        await capture.stop();
      }
      rethrow;
    }
  }

  Future<void> _stopIosSystemScreenCapture() async {
    _iosScreenCaptureSource = null;
    try {
      await _iosNativeChannel.invokeMethod<void>(
        'detachIosScreenCaptureKitSource',
      );
    } finally {
      await IosSystemScreenCapture.instance.stop();
    }
  }

  Future<void> _onIosSystemScreenCaptureStopped() async {
    if (_iosScreenCaptureSource == null) return;
    await _setScreenShareEnabled(false);
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
    providerId: 'artc',
    channelName: 'com.oneplusdream.flutter_realtime_media_artc/methods',
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
      _session._capabilities.canPublishAudio,
      'publishing audio',
    );
    await _session._engine!.setMuted(muted);
    _session._setSnapshot(_session._snapshot.copyWith(localMuted: muted));
    _session._emit(MediaLocalMediaChanged(muted: muted));
  }

  Future<void> _setVideoEnabled(bool enabled) async {
    _session._requireActive();
    _session._requireCapability(
      _session._capabilities.canPublishVideo,
      'publishing video',
    );
    await _processedSink.setEnabled(enabled);
    await _session._engine!.setVideoEnabled(enabled);
    if (_session._joinInfo case final info?) {
      final localTrack = enabled
          ? ArtcMediaVideoTrack(
              userId: info.userId,
              local: true,
              generation: _session._mapper._trackGeneration,
            )
          : null;
      final participants = _session._snapshot.participants
          .map(
            (item) => item.isLocal
                ? item.copyWith(
                    isVideoEnabled: enabled,
                    videoTrack: localTrack,
                    clearVideoTrack: !enabled,
                  )
                : item,
          )
          .toList();
      _session._setSnapshot(
        _session._snapshot.copyWith(
          participants: participants,
          localVideoEnabled: enabled,
        ),
      );
      if (enabled) {
        _session._emit(MediaTrackPublished(localTrack!));
      } else {
        _session._emit(
          MediaTrackUnpublished(
            trackId:
                'artc:${info.userId}:camera:$_session._mapper._trackGeneration',
            participantId: info.userId,
          ),
        );
      }
    }
    _session._emit(MediaLocalMediaChanged(videoEnabled: enabled));
  }

  Future<void> _switchCamera(MediaCameraPosition position) async {
    _session._requireActive();
    _session._requireCapability(
      _session._capabilities.canSwitchCamera,
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
  }

  Future<void> _setScreenShareEnabled(bool enabled) async {
    _session._requireActive();
    _session._requireCapability(capabilities.canScreenShare, 'screen sharing');
    if (_screenShareEnabled == enabled) return;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      if (enabled) {
        await _startIosSystemScreenCapture();
      } else {
        await _stopIosSystemScreenCapture();
      }
    } else {
      await _session._engine!.setScreenShareEnabled(enabled);
    }
    // The vendor will also send a publish-state callback. Reconciliation is
    // idempotent whether that callback arrives before or after this response.
    _syncLocalScreenShare(enabled);
  }

  void _syncLocalScreenShare(bool enabled) {
    if (_screenShareEnabled == enabled) return;
    _screenShareEnabled = enabled;
    final info = _session._joinInfo;
    if (info == null) return;
    final previous = _localScreenTrack;
    _localScreenTrack = enabled
        ? ArtcMediaVideoTrack(
            userId: info.userId,
            local: true,
            screenShare: true,
            generation: _session._mapper._trackGeneration,
          )
        : null;
    _session._setSnapshot(
      _session._snapshot.copyWith(
        localScreenShareEnabled: enabled,
        contentShareTrack:
            _session._mapper._remoteScreens.values.lastOrNull ??
            _localScreenTrack,
        clearContentShareTrack:
            _session._mapper._remoteScreens.isEmpty &&
            _localScreenTrack == null,
      ),
    );
    if (_localScreenTrack case final next?) {
      _session._emit(MediaTrackPublished(next));
    } else if (previous != null) {
      _session._emit(
        MediaTrackUnpublished(
          trackId: previous.id,
          participantId: info.userId,
          wasScreenShare: true,
        ),
      );
    }
  }

  Future<List<MediaAudioDevice>> _listAudioDevices() async {
    _session._requireActive();
    _session._requireCapability(
      _session._capabilities.canEnumerateAudioDevices,
      'audio device enumeration',
    );
    return const [];
  }

  Future<void> _selectAudioDevice(MediaAudioDevice device) async {
    _session._requireActive();
    _session._requireCapability(
      _session._capabilities.canEnumerateAudioDevices,
      'audio device selection',
    );
  }
}
