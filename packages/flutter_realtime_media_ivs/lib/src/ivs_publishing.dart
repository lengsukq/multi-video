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
  bool _desktopScreenShareEnabled = false;
  MediaAuxiliaryTokenCallback? _auxiliaryTokenCallback;
  bool _auxiliaryScreenShareActive = false;

  void setAuxiliaryTokenCallback(MediaAuxiliaryTokenCallback? callback) {
    _auxiliaryTokenCallback = callback;
  }

  void _adoptFrom(_IvsPublishing previous) {
    _auxiliaryTokenCallback = previous._auxiliaryTokenCallback;
    _macEffectsInputAvailable = previous._macEffectsInputAvailable;
    _windowsEffectsInputAvailable = previous._windowsEffectsInputAvailable;
    _selectedCameraDevice = previous._selectedCameraDevice;
    _cameraPosition = previous._cameraPosition;
    if (role == MediaRole.viewer) {
      _auxiliaryScreenShareActive = false;
      _desktopScreenShareEnabled = false;
      _windowsProcessedSource = null;
      _iosScreenSource = null;
    } else {
      _auxiliaryScreenShareActive = previous._auxiliaryScreenShareActive;
      _desktopScreenShareEnabled = previous._desktopScreenShareEnabled;
      _windowsProcessedSource = previous._windowsProcessedSource;
      _iosScreenSource = previous._iosScreenSource;
    }
  }

  Future<String?> _acquireAuxiliaryScreenTokenIfSupported() async {
    final callback = _auxiliaryTokenCallback;
    if (callback == null || _session._joinInfo?.auxiliaryScreenToken != true) {
      return null;
    }
    try {
      final response = await callback(action: 'acquire');
      final token = response['token']?.toString().trim();
      return (token != null && token.isNotEmpty) ? token : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _revokeAuxiliaryScreenTokenIfNeeded() async {
    if (!_auxiliaryScreenShareActive) return;
    _auxiliaryScreenShareActive = false;
    final callback = _auxiliaryTokenCallback;
    if (callback == null) return;
    try {
      await callback(action: 'revoke');
    } catch (_) {}
  }

  IvsMediaVideoTrack? _buildLocalScreenTrack() {
    final info = _session._joinInfo;
    if (info == null) return null;
    return IvsMediaVideoTrack(
      userId: info.participantId,
      local: true,
      generation: _session._mapper._trackGeneration,
      isScreenShare: true,
      explicitContentOwnerId: info.participantId,
    );
  }

  Future<List<MediaScreenShareSource>> listScreenShareSources() async {
    _session._requireActive();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) {
      return const <MediaScreenShareSource>[];
    }
    try {
      final raw = await _iosChannel.invokeListMethod<dynamic>(
        'listScreenShareSources',
      );
      return [
        for (final item in raw ?? const <dynamic>[])
          if (item is Map)
            MediaScreenShareSource(
              id: item['id']?.toString() ?? '',
              name: item['name']?.toString() ?? '',
              kind: item['kind'] == 'window'
                  ? MediaScreenShareSourceKind.window
                  : MediaScreenShareSourceKind.display,
            ),
      ].where((source) => source.id.isNotEmpty).toList(growable: false);
    } on PlatformException catch (error) {
      throw mapIvsPlatformError(error);
    }
  }

  Future<void> selectScreenShareSource(MediaScreenShareSource source) async {
    _session._requireActive();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return;
    try {
      await _iosChannel.invokeMethod<void>('selectScreenShareSource', {
        'id': source.id,
        'name': source.name,
        'kind': source.kind.name,
      });
    } on PlatformException catch (error) {
      throw mapIvsPlatformError(error);
    }
  }

  NativeSystemScreenCaptureClient get _mobileScreenCapture =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? AndroidSystemScreenCapture.instance
      : IosSystemScreenCapture.instance;

  Future<void> _stopIosScreenCapture() async {
    if (_iosScreenSource == null) return;
    _iosScreenSource = null;
    final detachMethod =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? 'detachAndroidScreenCaptureSource'
        : 'detachIosScreenCaptureKitSource';
    try {
      await _iosChannel.invokeMethod<void>(detachMethod);
    } finally {
      await _mobileScreenCapture.stop();
      await _revokeAuxiliaryScreenTokenIfNeeded();
      _session._setSnapshot(
        _session._snapshot.copyWith(
          localScreenShareEnabled: false,
          clearContentShareTrack:
              _session._snapshot.contentShareTrack?.isLocal == true,
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
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      final engine = _session._engine;
      if (engine is WindowsIvsWebView2Engine) {
        if (_desktopScreenShareEnabled == enabled) return;
        String? auxToken;
        if (enabled) {
          auxToken = await _acquireAuxiliaryScreenTokenIfSupported();
        }
        try {
          await engine.setScreenShareEnabled(enabled, auxiliaryToken: auxToken);
        } catch (_) {
          if (auxToken != null) {
            _auxiliaryScreenShareActive = true;
            await _revokeAuxiliaryScreenTokenIfNeeded();
          }
          rethrow;
        }
        _desktopScreenShareEnabled = enabled;
        if (enabled) {
          _auxiliaryScreenShareActive = auxToken != null;
          _session._setSnapshot(
            _session._snapshot.copyWith(
              localScreenShareEnabled: true,
              contentShareTrack: _buildLocalScreenTrack(),
            ),
          );
        } else {
          await _revokeAuxiliaryScreenTokenIfNeeded();
          _session._setSnapshot(
            _session._snapshot.copyWith(
              localScreenShareEnabled: false,
              clearContentShareTrack:
                  _session._snapshot.contentShareTrack?.isLocal == true,
            ),
          );
        }
        return;
      }
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      if (_desktopScreenShareEnabled == enabled) return;
      String? auxToken;
      if (enabled) {
        auxToken = await _acquireAuxiliaryScreenTokenIfSupported();
      }
      try {
        await _iosChannel.invokeMethod<void>('setScreenShareEnabled', {
          'enabled': enabled,
          if (auxToken != null) 'auxiliaryToken': auxToken,
        });
      } on PlatformException catch (error) {
        if (auxToken != null) {
          _auxiliaryScreenShareActive = true;
          await _revokeAuxiliaryScreenTokenIfNeeded();
        }
        throw mapIvsPlatformError(error);
      }
      _desktopScreenShareEnabled = enabled;
      if (enabled) {
        _auxiliaryScreenShareActive = auxToken != null;
        _session._setSnapshot(
          _session._snapshot.copyWith(
            localScreenShareEnabled: true,
            contentShareTrack: _buildLocalScreenTrack(),
          ),
        );
      } else {
        await _revokeAuxiliaryScreenTokenIfNeeded();
        _session._setSnapshot(
          _session._snapshot.copyWith(
            localScreenShareEnabled: false,
            clearContentShareTrack:
                _session._snapshot.contentShareTrack?.isLocal == true,
          ),
        );
      }
      return;
    }
    if ((_iosScreenSource != null) == enabled) return;
    if (!enabled) {
      await _stopIosScreenCapture();
      return;
    }
    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final capture = _mobileScreenCapture;
    final attachMethod = isAndroid
        ? 'attachAndroidScreenCaptureSource'
        : 'attachIosScreenCaptureKitSource';
    final detachMethod = isAndroid
        ? 'detachAndroidScreenCaptureSource'
        : 'detachIosScreenCaptureKitSource';
    if (!await capture.isAvailable) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: isAndroid
            ? 'IVS Android screen sharing is unavailable on this device.'
            : 'IVS iOS screen sharing is unavailable on this device.',
        providerId: providerId,
      );
    }
    ProcessedVideoSource? source;
    String? auxToken;
    try {
      final started = await capture.start();
      source = started;
      auxToken = await _acquireAuxiliaryScreenTokenIfSupported();
      await _iosChannel.invokeMethod<void>(attachMethod, {
        'sourceId': started.id,
        if (auxToken != null) 'auxiliaryToken': auxToken,
      });
      _iosScreenSource = started;
      _auxiliaryScreenShareActive = auxToken != null;
      capture.onSystemStopped(_onIosScreenStopped);
      _session._setSnapshot(
        _session._snapshot.copyWith(
          localScreenShareEnabled: true,
          contentShareTrack: _buildLocalScreenTrack(),
        ),
      );
    } catch (_) {
      if (auxToken != null) {
        _auxiliaryScreenShareActive = true;
        await _revokeAuxiliaryScreenTokenIfNeeded();
      }
      if (source != null) {
        try {
          await _iosChannel.invokeMethod<void>(detachMethod);
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
  bool _windowsEffectsInputAvailable = false;
  ProcessedVideoSource? _windowsProcessedSource;

  bool get _effectsPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          (defaultTargetPlatform == TargetPlatform.macOS &&
              _macEffectsInputAvailable) ||
          (defaultTargetPlatform == TargetPlatform.windows &&
              _windowsEffectsInputAvailable));

  ProcessedVideoSource? get _activeProcessedSource =>
      _windowsProcessedSource ?? _processedSink.source;

  Future<void> _probeProcessedVideoInput() async {
    if (kIsWeb) return;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      try {
        _windowsEffectsInputAvailable = await AwsWindowsWebView2Runtime.ivs
            .probeProcessedVideoInput();
      } on MissingPluginException {
        _windowsEffectsInputAvailable = false;
      } on PlatformException {
        _windowsEffectsInputAvailable = false;
      }
      return;
    }
    if (defaultTargetPlatform != TargetPlatform.macOS) return;
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
          switch (defaultTargetPlatform) {
            TargetPlatform.android => ProcessedVideoPlatform.android,
            TargetPlatform.iOS => ProcessedVideoPlatform.ios,
            TargetPlatform.windows => ProcessedVideoPlatform.windows,
            _ => ProcessedVideoPlatform.macos,
          };
  MediaDevice? _selectedCameraDevice;

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
    final engine = _session._engine;
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows &&
        engine is WindowsIvsWebView2Engine) {
      await engine.attachProcessedVideoSource(source);
      _windowsProcessedSource = source;
    } else {
      await _processedSink.attach(source);
    }
    if (_selectedCameraDevice != null) {
      if (_windowsProcessedSource != null) {
        await ProcessedVideoBridge().selectCamera(
          _windowsProcessedSource!,
          _selectedCameraDevice!.id,
        );
      } else {
        await _processedSink.selectCamera(_selectedCameraDevice!.id);
      }
    }
    _syncLocalProcessedTrack();
  }

  Future<void> detachProcessedVideoSource() async {
    final engine = _session._engine;
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows &&
        engine is WindowsIvsWebView2Engine) {
      if (_windowsProcessedSource == null) return;
      _windowsProcessedSource = null;
      await engine.detachProcessedVideoSource();
    } else {
      await _processedSink.detach();
    }
    if (!_session._disposed) _syncLocalProcessedTrack();
  }

  void _syncLocalProcessedTrack() {
    final info = _session._joinInfo;
    if (!_session._snapshot.localVideoEnabled || info == null) return;
    final track = IvsMediaVideoTrack(
      userId: info.participantId,
      local: true,
      generation: _session._mapper._trackGeneration,
      processedSource: _activeProcessedSource,
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
  }

  Future<List<MediaAudioDevice>> listAudioDevices() async {
    _session._requireActive();
    final engine = _session._engine;
    if (engine == null) return const [];
    return engine.listAudioDevices();
  }

  Future<void> selectAudioDevice(MediaAudioDevice device) async {
    _session._requireActive();
    _session._requireCapability(
      capabilities.canSelectAudioOutput,
      'audio output selection',
    );
    final engine = _session._engine;
    if (engine == null) return;
    await engine.selectAudioDevice(device);
  }

  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async {
    _session._requireActive();
    final engine = _session._engine;
    if (engine is WindowsIvsWebView2Engine) {
      return engine.listMediaDevices(kinds: kinds);
    }
    final requested = kinds ?? MediaDeviceKind.values.toSet();
    final devices = <MediaDevice>[];
    if (capabilities.canEnumerateCameras &&
        requested.contains(MediaDeviceKind.camera)) {
      for (final camera in await ProcessedVideoBridge().listCameras()) {
        devices.add(
          MediaDevice(
            id: camera.id,
            label: camera.label,
            kind: MediaDeviceKind.camera,
          ),
        );
      }
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      final raw = await _iosChannel.invokeListMethod<dynamic>(
        'listMediaDevices',
      );
      for (final item in raw ?? const <dynamic>[]) {
        if (item is! Map) continue;
        final kind = switch (item['kind']?.toString()) {
          'microphone' => MediaDeviceKind.microphone,
          'audioOutput' => MediaDeviceKind.audioOutput,
          'camera' => MediaDeviceKind.camera,
          _ => null,
        };
        final id = item['id']?.toString() ?? '';
        final label = item['label']?.toString() ?? '';
        if (kind == null || id.isEmpty || !requested.contains(kind)) continue;
        if (kind == MediaDeviceKind.camera &&
            devices.any(
              (existing) => existing.kind == MediaDeviceKind.camera,
            )) {
          continue;
        }
        devices.add(MediaDevice(id: id, label: label, kind: kind));
      }
    } else if (requested.contains(MediaDeviceKind.audioOutput) &&
        capabilities.canEnumerateAudioDevices) {
      for (final audio in await listAudioDevices()) {
        devices.add(
          MediaDevice(
            id: audio.id ?? audio.label,
            label: audio.label,
            kind: MediaDeviceKind.audioOutput,
          ),
        );
      }
    }
    return List.unmodifiable(devices);
  }

  Future<void> selectMediaDevice(MediaDevice device) async {
    _session._requireActive();
    final engine = _session._engine;
    if (device.kind == MediaDeviceKind.audioOutput) {
      await selectAudioDevice(
        MediaAudioDevice.fromLabel(device.label, id: device.id),
      );
      return;
    }
    if (engine is WindowsIvsWebView2Engine) {
      if ((device.kind == MediaDeviceKind.camera &&
              capabilities.canSelectCamera) ||
          (device.kind == MediaDeviceKind.microphone &&
              capabilities.canSelectMicrophone)) {
        await engine.selectMediaDevice(device);
        return;
      }
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        providerId: providerId,
        message: 'This media device cannot be selected.',
      );
    }
    if (device.kind == MediaDeviceKind.microphone &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.macOS &&
        capabilities.canSelectMicrophone) {
      await _iosChannel.invokeMethod<void>('selectDevice', {
        'device': {
          'id': device.id,
          'label': device.label,
          'kind': 'microphone',
        },
      });
      return;
    }
    if (device.kind != MediaDeviceKind.camera ||
        !capabilities.canSelectCamera) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        providerId: providerId,
        message: 'This media device cannot be selected.',
      );
    }
    _selectedCameraDevice = device;
    if (_windowsProcessedSource != null) {
      await ProcessedVideoBridge().selectCamera(
        _windowsProcessedSource!,
        device.id,
      );
      return;
    }
    if (_processedSink.source != null) {
      await _processedSink.selectCamera(device.id);
      return;
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      await _iosChannel.invokeMethod<void>('selectDevice', {
        'device': {'id': device.id, 'label': device.label, 'kind': 'camera'},
      });
    }
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
    if (_windowsProcessedSource != null) {
      await ProcessedVideoBridge().setEnabled(
        _windowsProcessedSource!,
        enabled,
      );
    } else {
      await _processedSink.setEnabled(enabled);
    }
    await _session._engine!.setVideoEnabled(enabled);
    final info = _session._joinInfo!;
    final track = enabled
        ? IvsMediaVideoTrack(
            userId: info.participantId,
            local: true,
            generation: _session._mapper._trackGeneration,
            processedSource: _activeProcessedSource,
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
    final facing = position == MediaCameraPosition.front ? 'front' : 'back';
    if (_windowsProcessedSource != null) {
      await ProcessedVideoBridge().selectCamera(
        _windowsProcessedSource!,
        facing,
      );
    } else if (_processedSink.source != null) {
      await _processedSink.selectCamera(facing);
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
        processedSource: _activeProcessedSource,
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
