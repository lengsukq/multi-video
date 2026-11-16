import 'dart:async';

import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

/// Combines the video-effects camera preview with a provider-owned microphone
/// preview. Neither session joins a room and neither starts capture until the
/// user explicitly enables its respective device.
///
/// A video-effects-only preview cannot inspect audio: toggling its boolean
/// flag is not microphone capture. Keep the native provider session alive for
/// microphone monitoring and selected audio input/output devices.
class ComposedLocalPreview
    implements
        MediaLocalPreviewSession,
        MediaLocalPreviewAudioLevels,
        MediaLocalPreviewRoomSettings,
        MediaBackgroundEffectsController,
        MediaLocalPreviewFailureEvents {
  ComposedLocalPreview({required this.video, required this.audio}) {
    for (final session in [video, audio]) {
      if (session is MediaLocalPreviewFailureEvents) {
        final events = (session as MediaLocalPreviewFailureEvents).failures;
        _errorSubscriptions.add(
          events.listen((RealtimeException error) {
            if (!_failures.isClosed) _failures.add(error);
          }),
        );
      }
    }
  }

  @override
  MediaLocalPreviewSettings get roomSettings {
    final selected = settings;
    if (audio == null || audio!.providerId == video.providerId) {
      return selected;
    }
    // A generic WebRTC hardware preview can verify and select the local
    // microphone, but its device IDs cannot be assumed valid in Agora/TRTC/
    // ARTC/etc. Preserve the chosen enable state, use the RTC default input.
    return MediaLocalPreviewSettings(
      microphoneEnabled: selected.microphoneEnabled,
      cameraEnabled: selected.cameraEnabled,
      camera: selected.camera,
      backgroundEffect: selected.backgroundEffect,
    );
  }

  final MediaLocalPreviewSession video;
  final MediaLocalPreviewSession? audio;

  final _failures = StreamController<RealtimeException>.broadcast();
  final _errorSubscriptions = <StreamSubscription<RealtimeException>>[];
  Future<void>? _closing;
  bool _disposed = false;

  @override
  Stream<RealtimeException> get failures => _failures.stream;

  @override
  Stream<double> get microphoneLevels {
    final delegate = audio;
    return delegate is MediaLocalPreviewAudioLevels
        ? (delegate as MediaLocalPreviewAudioLevels).microphoneLevels
        : const Stream<double>.empty();
  }

  @override
  String get providerId => video.providerId;

  @override
  MediaRole get role => video.role;

  @override
  MediaCapabilities get capabilities {
    final audioCapabilities = audio?.capabilities;
    return video.capabilities.copyWith(
      canPublishAudio: audioCapabilities?.canPublishAudio ?? false,
      canEnumerateMicrophones:
          audioCapabilities?.canEnumerateMicrophones ?? false,
      canEnumerateAudioDevices:
          audioCapabilities?.canEnumerateAudioDevices ?? false,
      canSelectMicrophone: audioCapabilities?.canSelectMicrophone ?? false,
      canSelectAudioOutput: audioCapabilities?.canSelectAudioOutput ?? false,
    );
  }

  @override
  MediaVideoTrack? get cameraTrack => video.cameraTrack;

  @override
  MediaTrackRenderer get renderer => video.renderer;

  @override
  MediaLocalPreviewSettings get settings {
    final videoSettings = video.settings;
    final audioSettings = audio?.settings;
    return MediaLocalPreviewSettings(
      microphoneEnabled: audioSettings?.microphoneEnabled ?? false,
      cameraEnabled: videoSettings.cameraEnabled,
      microphone: audioSettings?.microphone,
      camera: videoSettings.camera,
      audioOutput: audioSettings?.audioOutput,
      backgroundEffect: videoSettings.backgroundEffect,
    );
  }

  @override
  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async {
    _ensureActive();
    final requested = kinds ?? MediaDeviceKind.values.toSet();
    final devices = <MediaDevice>[];
    if (requested.contains(MediaDeviceKind.camera)) {
      devices.addAll(
        await video.listMediaDevices(kinds: {MediaDeviceKind.camera}),
      );
    }
    final selectedAudioKinds = requested.difference({MediaDeviceKind.camera});
    if (selectedAudioKinds.isNotEmpty && audio != null) {
      devices.addAll(await audio!.listMediaDevices(kinds: selectedAudioKinds));
    }
    return List.unmodifiable(devices);
  }

  @override
  Future<void> selectMediaDevice(MediaDevice device) {
    _ensureActive();
    return switch (device.kind) {
      MediaDeviceKind.camera => video.selectMediaDevice(device),
      MediaDeviceKind.microphone ||
      MediaDeviceKind.audioOutput => _audioOrThrow().selectMediaDevice(device),
    };
  }

  @override
  Future<void> setMicrophoneEnabled(bool enabled) {
    _ensureActive();
    if (!enabled && audio == null) return Future<void>.value();
    return _audioOrThrow().setMicrophoneEnabled(enabled);
  }

  @override
  Future<void> setCameraEnabled(bool enabled) {
    _ensureActive();
    return video.setCameraEnabled(enabled);
  }

  MediaBackgroundEffectsController get _effects {
    final camera = video;
    if (camera is MediaBackgroundEffectsController) {
      return camera as MediaBackgroundEffectsController;
    }
    throw const RealtimeException(
      code: RealtimeErrorCode.unsupportedFeature,
      message: 'prejoin.videoEffects.unsupported',
    );
  }

  @override
  MediaBackgroundCapabilities get backgroundCapabilities =>
      _effects.backgroundCapabilities;

  @override
  MediaBackgroundEffect get backgroundEffect => _effects.backgroundEffect;

  @override
  Future<void> setBackgroundEffect(MediaBackgroundEffect effect) {
    _ensureActive();
    return _effects.setBackgroundEffect(effect);
  }

  MediaLocalPreviewSession _audioOrThrow() =>
      audio ??
      (throw const RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'prejoin.microphone.unavailable',
      ));

  void _ensureActive() {
    if (_disposed) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'prejoin.preview.disposed',
      );
    }
  }

  @override
  Future<void> dispose() => _closing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    final cleanup = Cleanup(timeout: const Duration(seconds: 10));
    for (final subscription in _errorSubscriptions) {
      await cleanup.run('prejoin.events', subscription.cancel);
    }
    await cleanup.run('prejoin.camera', video.dispose);
    if (audio != null && !identical(audio, video)) {
      await cleanup.run('prejoin.audio', audio!.dispose);
    }
    await cleanup.run('prejoin.failures', _failures.close);
    cleanup.finish(domain: 'media.prejoin');
  }
}
