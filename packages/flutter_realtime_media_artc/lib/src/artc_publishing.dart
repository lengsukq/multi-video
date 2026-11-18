part of 'artc_media_session.dart';

class _ArtcPublishing {
  _ArtcPublishing(this._session);
  final _ArtcMediaSession _session;

  Future<List<MediaScreenShareSource>> listScreenShareSources() {
    _session._requireActive();
    _session._requireCapability(capabilities.canScreenShare, 'screen sharing');
    final engine = _session._engine;
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.windows &&
            defaultTargetPlatform != TargetPlatform.macOS) ||
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
  MediaDevice? _selectedCameraDevice;
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
  bool _desktopEffectsInputAvailable = false;
  bool get _desktopCameraPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);
  bool get _effectsPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          (_desktopCameraPlatform && _desktopEffectsInputAvailable));
  Future<void> _probeProcessedVideoInput() async {
    if (!_desktopCameraPlatform) return;
    try {
      _desktopEffectsInputAvailable =
          await MethodChannel(
            _processedSink.channelName,
          ).invokeMethod<bool>('probeProcessedVideoInput') ??
          false;
    } on MissingPluginException {
      _desktopEffectsInputAvailable = false;
    } on PlatformException {
      _desktopEffectsInputAvailable = false;
    }
  }

  final _processedSink = NativeProcessedVideoSink(
    providerId: 'artc',
    channelName: 'com.oneplusdream.flutter_realtime_media_artc/methods',
    attachMethod: 'attachProcessedVideoSource',
    detachMethod: 'detachProcessedVideoSource',
  );

  ProcessedVideoPlatform? get _expectedProcessedPlatform => kIsWeb
      ? null
      : switch (defaultTargetPlatform) {
          TargetPlatform.android => ProcessedVideoPlatform.android,
          TargetPlatform.macOS => ProcessedVideoPlatform.macos,
          TargetPlatform.windows => ProcessedVideoPlatform.windows,
          _ => null,
        };

  bool supportsProcessedVideoSource(ProcessedVideoSource source) =>
      capabilities.canPublishVideo &&
      _effectsPlatform &&
      _processedSink.supports(source) &&
      source.platform == _expectedProcessedPlatform;

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
    if (_selectedCameraDevice case final selected?) {
      try {
        final resolvedId = await _resolveProcessedCameraId(selected);
        await _processedSink.selectCamera(resolvedId);
      } on MissingPluginException {
        // Ignore if processed camera list channel is absent in offline tests.
      } on PlatformException {
        // Keep attached source; source creation may have already chosen camera.
      }
    }
    _syncLocalProcessedTrack();
  }

  Future<void> detachProcessedVideoSource() async {
    await _processedSink.detach();
    if (!_session._disposed) {
      if (_selectedCameraDevice case final selected?
          when _desktopCameraPlatform &&
              _session._engine is ArtcCameraDeviceControl) {
        try {
          await (_session._engine as ArtcCameraDeviceControl).selectCamera(
            selected,
          );
        } on RealtimeException {
          // Best-effort sync back onto native engine camera selection.
        }
      }
      _syncLocalProcessedTrack();
    }
  }

  void _syncLocalProcessedTrack() {
    final info = _session._joinInfo;
    if (!_session._snapshot.localVideoEnabled || info == null) return;
    final localTrack = ArtcMediaVideoTrack(
      userId: info.userId,
      local: true,
      generation: _session._mapper._trackGeneration,
      processedSource: _processedSink.source,
    );
    final participants = _session._snapshot.participants
        .map(
          (item) => item.isLocal
              ? item.copyWith(videoTrack: localTrack, isVideoEnabled: true)
              : item,
        )
        .toList();
    _session._setSnapshot(
      _session._snapshot.copyWith(participants: participants),
    );
  }

  static String _normalizeCameraLabel(String label) {
    var trimmed = label.trim();
    final open = trimmed.lastIndexOf('(');
    if (open > 0 && trimmed.endsWith(')')) {
      trimmed = trimmed.substring(0, open).trim();
    }
    return trimmed.toLowerCase();
  }

  Future<String> _resolveProcessedCameraId(MediaDevice requested) async {
    final available = await ProcessedVideoBridge().listCameras();
    if (available.isEmpty) return requested.id;
    for (final camera in available) {
      if (camera.id == requested.id) return camera.id;
    }
    final targetLabel = _normalizeCameraLabel(requested.label);
    final targetIdLabel = _normalizeCameraLabel(requested.id);
    for (final camera in available) {
      final candidate = _normalizeCameraLabel(camera.label);
      if (camera.label == requested.label ||
          (targetLabel.isNotEmpty && candidate == targetLabel) ||
          (targetIdLabel.isNotEmpty && candidate == targetIdLabel)) {
        return camera.id;
      }
    }
    return requested.id;
  }

  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async {
    _session._requireActive();
    if (!capabilities.canEnumerateCameras ||
        (kinds != null && !kinds.contains(MediaDeviceKind.camera))) {
      return const [];
    }
    if (_processedSink.source == null &&
        _desktopCameraPlatform &&
        _session._engine is ArtcCameraDeviceControl) {
      try {
        final nativeCameras =
            await (_session._engine as ArtcCameraDeviceControl).listCameras();
        if (nativeCameras.isNotEmpty) {
          return List.unmodifiable(nativeCameras);
        }
      } on MissingPluginException {
        // Fall back to ProcessedVideoBridge when running without native channel.
      } on RealtimeException {
        if (!_effectsPlatform) return const [];
      }
    }
    if (!_effectsPlatform && _processedSink.source == null) {
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
    if (_processedSink.source != null) {
      final resolvedId = await _resolveProcessedCameraId(device);
      await _processedSink.selectCamera(resolvedId);
      _selectedCameraDevice = device;
      return;
    }
    if (_desktopCameraPlatform && _session._engine is ArtcCameraDeviceControl) {
      await (_session._engine as ArtcCameraDeviceControl).selectCamera(device);
      _selectedCameraDevice = device;
      return;
    }
    throw RealtimeException(
      code: RealtimeErrorCode.invalidState,
      providerId: providerId,
      message: 'Prepare the SDK video source before selecting a camera.',
    );
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
              processedSource: _processedSink.source,
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
