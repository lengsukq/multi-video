part of 'chime_media_session.dart';

class _ChimeMediaControls {
  _ChimeMediaControls(this._session);
  final ChimeMediaSession _session;
  String get providerId => _session.providerId;
  MediaCapabilities get capabilities => _session.capabilities;
  MediaRole get role => _session.role;
  MediaSessionState get state => _session.state;
  MediaSnapshot get snapshot => _session.snapshot;
  Duration get cleanupTimeout => _session.cleanupTimeout;
  AwsWindowsWebView2Runtime get _windowsRuntime => _session._windowsRuntime;

  static const _iosChannel = MethodChannel(
    'com.oneplusdream.aws.chime.methodChannel',
  );
  ProcessedVideoSource? _iosScreenCaptureSource;
  bool _desktopScreenShareEnabled = false;

  NativeSystemScreenCaptureClient get _mobileScreenCapture =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android
          ? AndroidSystemScreenCapture.instance
          : IosSystemScreenCapture.instance;

  Future<void> _stopIosSystemScreenCapture() async {
    if (_iosScreenCaptureSource == null) return;
    _iosScreenCaptureSource = null;
    final detachMethod =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android
            ? 'detachAndroidScreenCaptureSource'
            : 'detachIosScreenCaptureKitSource';
    try {
      await _iosChannel.invokeMethod<Object?>(detachMethod);
    } finally {
      await _mobileScreenCapture.stop();
      _session._replaceSnapshot(
        _session._snapshot.copyWith(localScreenShareEnabled: false),
      );
    }
  }

  Future<void> _onIosScreenCaptureStopped() async {
    if (_iosScreenCaptureSource == null) return;
    await _stopIosSystemScreenCapture();
  }

  bool _macEffectsInputAvailable = false;
  bool _windowsEffectsInputAvailable = false;
  ProcessedVideoSource? _windowsProcessedSource;
  ProcessedVideoSource? get _activeProcessedSource =>
      _windowsProcessedSource ?? _processedSink.source;
  bool get _effectsPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          (defaultTargetPlatform == TargetPlatform.macOS &&
              _macEffectsInputAvailable) ||
          (defaultTargetPlatform == TargetPlatform.windows &&
              _windowsEffectsInputAvailable));
  Future<void> _probeProcessedVideoInput() async {
    if (kIsWeb) return;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      try {
        _windowsEffectsInputAvailable =
            await _windowsRuntime.probeProcessedVideoInput();
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
    providerId: 'chime',
    channelName: 'com.oneplusdream.aws.chime.methodChannel',
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

  Future<List<ProcessedVideoCameraDevice>> _safeListProcessedCameras() async {
    try {
      return await ProcessedVideoBridge().listCameras();
    } catch (_) {
      return const <ProcessedVideoCameraDevice>[];
    }
  }

  static String _normalizeDeviceLabel(String value) => value
      .replaceAll(RegExp(r'\s*\([^)]*\)\s*$'), '')
      .trim()
      .toLowerCase();

  static bool _isPlaceholderCameraLabel(String label) {
    final normalized = label.trim().toLowerCase();
    return normalized.isEmpty ||
        normalized == 'default camera' ||
        RegExp(r'^camera\s+\d+$').hasMatch(normalized);
  }

  Future<String> _resolveProcessedCameraId(
    MediaDevice device, {
    required bool isDesktop,
  }) async {
    if (!isDesktop) return device.id;
    final cameras = await _safeListProcessedCameras();
    if (cameras.isEmpty) return device.id;
    for (final camera in cameras) {
      if (camera.id == device.id) return camera.id;
    }
    final targetRaw = device.label.trim().toLowerCase();
    final targetNorm = _normalizeDeviceLabel(device.label);
    if (targetRaw.isNotEmpty) {
      for (final camera in cameras) {
        final candRaw = camera.label.trim().toLowerCase();
        final candNorm = _normalizeDeviceLabel(camera.label);
        if (candRaw == targetRaw ||
            (targetNorm.isNotEmpty && candNorm == targetNorm)) {
          return camera.id;
        }
      }
    }
    return cameras.first.id;
  }

  Future<String> _resolveProcessedPositionCameraId(
    MediaCameraPosition position, {
    required bool isDesktop,
  }) async {
    final token = position == MediaCameraPosition.front ? 'front' : 'back';
    if (!isDesktop) return token;
    final cameras = await _safeListProcessedCameras();
    if (cameras.isEmpty) return token;
    final wantFront = position == MediaCameraPosition.front;
    for (final camera in cameras) {
      if (camera.isFrontFacing == wantFront &&
          cameras.any((c) => c.isFrontFacing != wantFront)) {
        _selectedCameraDevice = MediaDevice(
          id: camera.id,
          label: camera.label,
          kind: MediaDeviceKind.camera,
        );
        return camera.id;
      }
    }
    for (final camera in cameras) {
      if (camera.label.toLowerCase().contains(token)) {
        _selectedCameraDevice = MediaDevice(
          id: camera.id,
          label: camera.label,
          kind: MediaDeviceKind.camera,
        );
        return camera.id;
      }
    }
    final alternate = cameras.firstWhere(
      (camera) => camera.id != _selectedCameraDevice?.id,
      orElse: () => cameras.first,
    );
    _selectedCameraDevice = MediaDevice(
      id: alternate.id,
      label: alternate.label,
      kind: MediaDeviceKind.camera,
    );
    return alternate.id;
  }

  Future<void> attachProcessedVideoSource(ProcessedVideoSource source) async {
    _session._ensureActive();
    if (!supportsProcessedVideoSource(source)) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        providerId: providerId,
        message:
            'Processed video input is unavailable for this role or platform.',
      );
    }
    final isWindows =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    final isDesktop =
        isWindows || (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS);
    if (isWindows) {
      await _windowsRuntime.attachProcessedVideoSource(source.id);
      _windowsProcessedSource = source;
      if (_selectedCameraDevice != null) {
        final targetId = await _resolveProcessedCameraId(
          _selectedCameraDevice!,
          isDesktop: isDesktop,
        );
        await ProcessedVideoBridge().selectCamera(source, targetId);
      }
    } else {
      await _processedSink.attach(source);
      if (_selectedCameraDevice != null) {
        final targetId = await _resolveProcessedCameraId(
          _selectedCameraDevice!,
          isDesktop: isDesktop,
        );
        await _processedSink.selectCamera(targetId);
      }
    }
    _session._mapper._onProviderSnapshot(_session._session.snapshot);
  }

  Future<void> detachProcessedVideoSource() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      if (_windowsProcessedSource == null) return;
      _windowsProcessedSource = null;
      await _windowsRuntime.detachProcessedVideoSource();
    } else {
      await _processedSink.detach();
    }
    if (!_session._disposed) {
      _session._mapper._onProviderSnapshot(_session._session.snapshot);
    }
  }

  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async {
    final requested = kinds ?? MediaDeviceKind.values.toSet();
    _session._ensureActive();
    final isWindows =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    final isDesktopBridge =
        isWindows || (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS);
    final desktopDevices =
        isDesktopBridge &&
            (requested.contains(MediaDeviceKind.microphone) ||
                requested.contains(MediaDeviceKind.camera))
        ? await _session._session.listDesktopMediaDevices()
        : const <Map<String, dynamic>>[];
    final cameras = <MediaDevice>[];
    if (capabilities.canEnumerateCameras &&
        requested.contains(MediaDeviceKind.camera)) {
      final desktopCameras = <MediaDevice>[
        for (final item in desktopDevices)
          if (item['kind'] == 'camera' &&
              (item['id']?.toString().isNotEmpty ?? false))
            MediaDevice(
              id: item['id']!.toString(),
              label: item['label']?.toString() ?? item['id']!.toString(),
              kind: MediaDeviceKind.camera,
            ),
      ];
      final preferProcessedCameras =
          !isDesktopBridge || _activeProcessedSource != null;
      if (preferProcessedCameras && _effectsPlatform) {
        for (final camera in await _safeListProcessedCameras()) {
          cameras.add(
            MediaDevice(
              id: camera.id,
              label: camera.label,
              kind: MediaDeviceKind.camera,
            ),
          );
        }
      }
      if (cameras.isEmpty && isDesktopBridge) {
        final hasNamedDesktopCameras = desktopCameras.any(
          (camera) => !_isPlaceholderCameraLabel(camera.label),
        );
        if (!hasNamedDesktopCameras && _effectsPlatform) {
          for (final camera in await _safeListProcessedCameras()) {
            cameras.add(
              MediaDevice(
                id: camera.id,
                label: camera.label,
                kind: MediaDeviceKind.camera,
              ),
            );
          }
        }
        if (cameras.isEmpty) {
          cameras.addAll(desktopCameras);
        }
      }
    }
    final microphones = <MediaDevice>[];
    if (capabilities.canEnumerateMicrophones &&
        requested.contains(MediaDeviceKind.microphone)) {
      for (final item in desktopDevices) {
        if (item['kind'] == 'microphone') {
          final id = item['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          microphones.add(
            MediaDevice(
              id: id,
              label: item['label']?.toString() ?? id,
              kind: MediaDeviceKind.microphone,
            ),
          );
        }
      }
    }
    final devices = requested.contains(MediaDeviceKind.audioOutput)
        ? await listAudioDevices()
        : const <MediaAudioDevice>[];
    return [
      ...cameras,
      ...microphones,
      ...devices.map(
        (device) => MediaDevice(
          id: device.id ?? device.label,
          label: device.label,
          kind: MediaDeviceKind.audioOutput,
        ),
      ),
    ];
  }

  Future<void> selectMediaDevice(MediaDevice device) async {
    _session._ensureActive();
    final isDesktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows);
    if (device.kind == MediaDeviceKind.camera && capabilities.canSelectCamera) {
      _selectedCameraDevice = device;
      if (_windowsProcessedSource != null) {
        final targetId = await _resolveProcessedCameraId(
          device,
          isDesktop: isDesktop,
        );
        await ProcessedVideoBridge().selectCamera(
          _windowsProcessedSource!,
          targetId,
        );
        return;
      }
      if (_processedSink.source != null) {
        final targetId = await _resolveProcessedCameraId(
          device,
          isDesktop: isDesktop,
        );
        await _processedSink.selectCamera(targetId);
        return;
      }
      if (isDesktop) {
        try {
          await _session._session.selectDesktopMediaDevice(
            id: device.id,
            label: device.label,
            kind: 'camera',
          );
        } on chime.RealtimeException catch (error, stack) {
          throw _mapError(error, stage: 'selectDevice', stack: stack);
        }
      }
      return;
    }
    if (device.kind == MediaDeviceKind.microphone &&
        capabilities.canSelectMicrophone) {
      try {
        await _session._session.selectDesktopMediaDevice(
          id: device.id,
          label: device.label,
          kind: 'microphone',
        );
      } on chime.RealtimeException catch (error, stack) {
        throw _mapError(error, stage: 'selectDevice', stack: stack);
      }
      return;
    }
    if (device.kind != MediaDeviceKind.audioOutput) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'Chime does not support selecting ${device.kind.name}.',
        providerId: providerId,
      );
    }
    final mapped = MediaAudioDevice.fromLabel(device.label);
    return selectAudioDevice(
      MediaAudioDevice(
        id: device.id.isEmpty ? null : device.id,
        label: mapped.label,
        type: mapped.type,
      ),
    );
  }

  Future<void> setMuted(bool muted) async {
    _session._ensureActive();
    try {
      await _session._session.setMuted(muted);
      _session._mapper._onProviderSnapshot(_session._session.snapshot);
    } on chime.RealtimeException catch (error, stack) {
      throw _mapError(error, stage: 'setMuted', stack: stack);
    }
  }

  Future<void> toggleMute() async {
    _session._ensureActive();
    try {
      await _session._session.toggleMute();
      _session._mapper._onProviderSnapshot(_session._session.snapshot);
    } on chime.RealtimeException catch (error, stack) {
      throw _mapError(error, stage: 'toggleMute', stack: stack);
    }
  }

  Future<void> setVideoEnabled(bool enabled) async {
    _session._ensureActive();
    try {
      if (_windowsProcessedSource != null) {
        await ProcessedVideoBridge().setEnabled(
          _windowsProcessedSource!,
          enabled,
        );
      } else {
        await _processedSink.setEnabled(enabled);
      }
      await _session._session.setVideoEnabled(enabled);
      _session._mapper._onProviderSnapshot(_session._session.snapshot);
    } on chime.RealtimeException catch (error, stack) {
      throw _mapError(error, stage: 'setVideoEnabled', stack: stack);
    }
  }

  Future<List<MediaScreenShareSource>> listScreenShareSources() async {
    _session._ensureActive();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) {
      return const <MediaScreenShareSource>[];
    }
    try {
      final raw = await _session._session.listScreenShareSources();
      return raw
          .map(
            (item) => MediaScreenShareSource(
              id: item['id']?.toString() ?? '',
              name: item['name']?.toString() ?? '',
              kind: item['kind'] == 'window'
                  ? MediaScreenShareSourceKind.window
                  : MediaScreenShareSourceKind.display,
            ),
          )
          .where((source) => source.id.isNotEmpty)
          .toList(growable: false);
    } on chime.RealtimeException catch (error, stack) {
      throw _mapError(error, stage: 'listScreenShareSources', stack: stack);
    }
  }

  Future<void> selectScreenShareSource(MediaScreenShareSource source) async {
    _session._ensureActive();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return;
    try {
      await _session._session.selectScreenShareSource(
        id: source.id,
        name: source.name,
        kind: source.kind.name,
      );
    } on chime.RealtimeException catch (error, stack) {
      throw _mapError(error, stage: 'selectScreenShareSource', stack: stack);
    }
  }

  Future<void> setScreenShareEnabled(bool enabled) async {
    _session._ensureActive();
    if (!capabilities.canScreenShare) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'Screen sharing is not supported on this platform for Chime.',
        providerId: providerId,
      );
    }
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows)) {
      if (_desktopScreenShareEnabled == enabled) return;
      try {
        await _session._session.setScreenShareEnabled(enabled);
        _desktopScreenShareEnabled = enabled;
        _session._mapper._onProviderSnapshot(_session._session.snapshot);
      } on chime.RealtimeException catch (error, stack) {
        throw _mapError(error, stage: 'setScreenShareEnabled', stack: stack);
      }
      return;
    }
    if ((_iosScreenCaptureSource != null) == enabled) return;
    if (!enabled) {
      await _stopIosSystemScreenCapture();
      return;
    }
    final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
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
            ? 'Chime Android screen capture is unavailable on this device.'
            : 'Chime iOS screen capture is unavailable on this device.',
        providerId: providerId,
      );
    }
    ProcessedVideoSource? source;
    try {
      final started = await capture.start();
      source = started;
      final result = await _iosChannel.invokeMapMethod<String, Object?>(
        attachMethod,
        {'sourceId': started.id},
      );
      if (result?['success'] != true) {
        throw StateError('Chime rejected the external content-share source.');
      }
      _iosScreenCaptureSource = started;
      capture.onSystemStopped(_onIosScreenCaptureStopped);
      _session._replaceSnapshot(
        _session._snapshot.copyWith(localScreenShareEnabled: true),
      );
    } catch (_) {
      if (source != null) {
        await _iosChannel.invokeMethod<Object?>(detachMethod);
      }
      await capture.stop();
      rethrow;
    }
  }

  Future<void> switchCamera(MediaCameraPosition position) async {
    _session._ensureActive();
    final isDesktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows);
    try {
      if (_windowsProcessedSource != null) {
        final targetId = await _resolveProcessedPositionCameraId(
          position,
          isDesktop: isDesktop,
        );
        await ProcessedVideoBridge().selectCamera(
          _windowsProcessedSource!,
          targetId,
        );
        return;
      }
      if (_processedSink.source != null) {
        final targetId = await _resolveProcessedPositionCameraId(
          position,
          isDesktop: isDesktop,
        );
        await _processedSink.selectCamera(targetId);
        return;
      }
      await _session._session.switchCamera(
        position == MediaCameraPosition.front
            ? chime.CameraPosition.front
            : chime.CameraPosition.back,
      );
    } on chime.RealtimeException catch (error, stack) {
      throw _mapError(error, stage: 'switchCamera', stack: stack);
    }
  }

  Future<List<MediaAudioDevice>> listAudioDevices() async {
    _session._ensureActive();
    try {
      final devices = await _session._session.listAudioDevices();
      return devices.map(_mapAudioDevice).toList(growable: false);
    } on chime.RealtimeException catch (error, stack) {
      throw _mapError(error, stage: 'listAudioDevices', stack: stack);
    }
  }

  Future<void> selectAudioDevice(MediaAudioDevice device) async {
    _session._ensureActive();
    try {
      await _session._session.selectAudioDevice(
        chime.ChimeAudioDevice.fromLabel(device.label),
      );
    } on chime.RealtimeException catch (error, stack) {
      throw _mapError(error, stage: 'selectAudioDevice', stack: stack);
    }
  }

  Future<void> sendMessage(String message, {String topic = 'chat'}) async {
    _session._ensureActive();
    try {
      await _session._session.sendMessage(message, topic: topic);
      _session._mapper._onProviderSnapshot(_session._session.snapshot);
    } on chime.RealtimeException catch (error, stack) {
      throw _mapError(error, stage: 'sendMessage', stack: stack);
    }
  }
}
