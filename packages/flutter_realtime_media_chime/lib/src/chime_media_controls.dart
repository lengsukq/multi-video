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

  static const _iosChannel = MethodChannel(
    'com.oneplusdream.aws.chime.methodChannel',
  );
  ProcessedVideoSource? _iosScreenCaptureSource;
  bool _desktopScreenShareEnabled = false;

  Future<void> _stopIosSystemScreenCapture() async {
    if (_iosScreenCaptureSource == null) return;
    _iosScreenCaptureSource = null;
    try {
      await _iosChannel.invokeMethod<Object?>(
        'detachIosScreenCaptureKitSource',
      );
    } finally {
      await IosSystemScreenCapture.instance.stop();
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
          (defaultTargetPlatform == TargetPlatform.android
              ? ProcessedVideoPlatform.android
              : ProcessedVideoPlatform.macos);
  MediaDevice? _selectedCameraDevice;

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
    await _processedSink.attach(source);
    if (_selectedCameraDevice != null) {
      await _processedSink.selectCamera(_selectedCameraDevice!.id);
    }
    _session._mapper._onProviderSnapshot(_session._session.snapshot);
  }

  Future<void> detachProcessedVideoSource() async {
    await _processedSink.detach();
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
                (isWindows && requested.contains(MediaDeviceKind.camera)))
        ? await _session._session.listDesktopMediaDevices()
        : const <Map<String, dynamic>>[];
    final cameras = <MediaDevice>[];
    if (capabilities.canEnumerateCameras &&
        requested.contains(MediaDeviceKind.camera)) {
      if (isWindows) {
        for (final item in desktopDevices) {
          if (item['kind'] == 'camera') {
            final id = item['id']?.toString() ?? '';
            if (id.isEmpty) continue;
            cameras.add(
              MediaDevice(
                id: id,
                label: item['label']?.toString() ?? id,
                kind: MediaDeviceKind.camera,
              ),
            );
          }
        }
      } else {
        for (final camera in await ProcessedVideoBridge().listCameras()) {
          cameras.add(
            MediaDevice(
              id: camera.id,
              label: camera.label,
              kind: MediaDeviceKind.camera,
            ),
          );
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
    if (device.kind == MediaDeviceKind.camera && capabilities.canSelectCamera) {
      _selectedCameraDevice = device;
      if (_processedSink.source != null) {
        await _processedSink.selectCamera(device.id);
        return;
      }
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.macOS ||
              defaultTargetPlatform == TargetPlatform.windows)) {
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
      await _processedSink.setEnabled(enabled);
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
    final capture = IosSystemScreenCapture.instance;
    if (!await capture.isAvailable) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'Chime cross-app screen capture requires iOS 27+.',
        providerId: providerId,
      );
    }
    ProcessedVideoSource? source;
    try {
      source = await capture.start();
      final result = await _iosChannel.invokeMapMethod<String, Object?>(
        'attachIosScreenCaptureKitSource',
        {'sourceId': source.id},
      );
      if (result?['success'] != true) {
        throw StateError('Chime rejected the external content-share source.');
      }
      _iosScreenCaptureSource = source;
      capture.onSystemStopped(_onIosScreenCaptureStopped);
      _session._replaceSnapshot(
        _session._snapshot.copyWith(localScreenShareEnabled: true),
      );
    } catch (_) {
      if (source != null) {
        await _iosChannel.invokeMethod<Object?>(
          'detachIosScreenCaptureKitSource',
        );
      }
      await capture.stop();
      rethrow;
    }
  }

  Future<void> switchCamera(MediaCameraPosition position) async {
    _session._ensureActive();
    try {
      if (_processedSink.source != null) {
        await _processedSink.selectCamera(
          position == MediaCameraPosition.front ? 'front' : 'back',
        );
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
