import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_sdk_runtime/src/composed_local_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('processed camera and actual microphone have separate owners', () async {
    final camera = _CameraPreview();
    final microphone = _MicrophonePreview();
    final preview = ComposedLocalPreview(video: camera, audio: microphone);

    expect(preview.settings.microphoneEnabled, isFalse);
    expect(preview.settings.cameraEnabled, isFalse);
    expect(preview.capabilities.canPublishAudio, isTrue);
    expect(preview.capabilities.canSelectMicrophone, isTrue);

    final levels = <double>[];
    final subscription = preview.microphoneLevels.listen(levels.add);
    await preview.setMicrophoneEnabled(true);
    expect(microphone.microphoneEnables, [true]);
    expect(camera.cameraEnables, isEmpty);
    microphone.report(0.26);
    expect(levels, [0.26]);
    expect(preview.settings.microphoneEnabled, isTrue);

    await preview.selectMediaDevice(
      const MediaDevice(
        id: 'mic-2',
        label: 'External microphone',
        kind: MediaDeviceKind.microphone,
      ),
    );
    expect(preview.settings.microphone?.id, 'mic-2');

    await preview.setCameraEnabled(true);
    expect(camera.cameraEnables, [true]);
    expect(microphone.microphoneEnables, [true]);
    await preview.setBackgroundEffect(const MediaBackgroundEffect.blur());
    expect(preview.backgroundEffect, const MediaBackgroundEffect.blur());

    final devices = await preview.listMediaDevices();
    expect(devices.map((d) => d.kind), [
      MediaDeviceKind.camera,
      MediaDeviceKind.microphone,
      MediaDeviceKind.audioOutput,
    ]);

    await preview.setMicrophoneEnabled(false);
    expect(preview.settings.microphoneEnabled, isFalse);
    expect(microphone.microphoneEnables, [true, false]);
    await subscription.cancel();
    await preview.dispose();
    await preview.dispose();
    expect(camera.disposals, 1);
    expect(microphone.disposals, 1);
  });

  test(
    'no native microphone preview never pretends it captured audio',
    () async {
      final camera = _CameraPreview();
      final preview = ComposedLocalPreview(video: camera, audio: null);
      expect(preview.capabilities.canPublishAudio, isFalse);
      expect(preview.settings.microphoneEnabled, isFalse);
      expect(
        () => preview.setMicrophoneEnabled(true),
        throwsA(isA<RealtimeException>()),
      );
      await preview.dispose();
      expect(camera.disposals, 1);
    },
  );

  test('cross-provider audio preview never forwards foreign device IDs', () async {
    final video = _CameraPreview(providerId: 'trtc');
    final audio = _MicrophonePreview();
    final preview = ComposedLocalPreview(video: video, audio: audio);
    await preview.selectMediaDevice(
      const MediaDevice(
        id: 'webrtc-mic',
        label: 'Generic microphone',
        kind: MediaDeviceKind.microphone,
      ),
    );
    await preview.selectMediaDevice(
      const MediaDevice(
        id: 'webrtc-speaker',
        label: 'Generic speaker',
        kind: MediaDeviceKind.audioOutput,
      ),
    );
    await preview.setMicrophoneEnabled(true);
    expect(preview.settings.microphone?.id, 'webrtc-mic');
    expect(preview.settings.audioOutput?.id, 'webrtc-speaker');
    expect(preview.roomSettings.microphoneEnabled, isTrue);
    expect(preview.roomSettings.microphone, isNull);
    expect(preview.roomSettings.audioOutput, isNull);
    await preview.dispose();
  });
}

class _CameraPreview extends Fake
    implements MediaLocalPreviewSession, MediaBackgroundEffectsController {
  _CameraPreview({this.providerId = 'livekit'});
  MediaLocalPreviewSettings _settings = const MediaLocalPreviewSettings();
  final cameraEnables = <bool>[];
  int disposals = 0;

  @override
  final String providerId;
  @override
  MediaRole get role => MediaRole.participant;
  @override
  MediaCapabilities get capabilities => const MediaCapabilities(
    canPublishVideo: true,
    canBlurBackground: true,
    canSelectCamera: true,
    canEnumerateCameras: true,
  );
  @override
  MediaLocalPreviewSettings get settings => _settings;
  @override
  MediaVideoTrack? get cameraTrack => null;
  @override
  MediaTrackRenderer get renderer => const _Renderer();
  @override
  MediaBackgroundCapabilities get backgroundCapabilities =>
      const MediaBackgroundCapabilities(canBlur: true);
  @override
  MediaBackgroundEffect get backgroundEffect => _settings.backgroundEffect;
  @override
  Future<void> setCameraEnabled(bool enabled) async {
    cameraEnables.add(enabled);
    _settings = _settings.copyWith(cameraEnabled: enabled);
  }

  @override
  Future<void> setBackgroundEffect(MediaBackgroundEffect effect) async =>
      _settings = _settings.copyWith(backgroundEffect: effect);

  @override
  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async => const [
    MediaDevice(id: 'camera-1', label: 'Camera', kind: MediaDeviceKind.camera),
  ];
  @override
  Future<void> selectMediaDevice(MediaDevice device) async =>
      _settings = _settings.copyWith(camera: device);
  @override
  Future<void> dispose() async => disposals++;
}

class _MicrophonePreview extends Fake
    implements MediaLocalPreviewSession, MediaLocalPreviewAudioLevels {
  MediaLocalPreviewSettings _settings = const MediaLocalPreviewSettings();
  final _samples = StreamController<double>.broadcast(sync: true);
  final microphoneEnables = <bool>[];
  int disposals = 0;

  void report(double level) => _samples.add(level);
  @override
  Stream<double> get microphoneLevels => _samples.stream;
  @override
  String get providerId => 'livekit';
  @override
  MediaRole get role => MediaRole.participant;
  @override
  MediaCapabilities get capabilities => const MediaCapabilities(
    canPublishAudio: true,
    canSelectMicrophone: true,
    canSelectAudioOutput: true,
    canEnumerateAudioDevices: true,
    canEnumerateMicrophones: true,
  );
  @override
  MediaLocalPreviewSettings get settings => _settings;
  @override
  MediaVideoTrack? get cameraTrack => null;
  @override
  MediaTrackRenderer get renderer => const _Renderer();
  @override
  Future<void> setMicrophoneEnabled(bool enabled) async {
    microphoneEnables.add(enabled);
    _settings = _settings.copyWith(microphoneEnabled: enabled);
  }

  @override
  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async => const [
    MediaDevice(
      id: 'mic-2',
      label: 'External microphone',
      kind: MediaDeviceKind.microphone,
    ),
    MediaDevice(
      id: 'speaker-1',
      label: 'Speaker',
      kind: MediaDeviceKind.audioOutput,
    ),
  ];

  @override
  Future<void> selectMediaDevice(MediaDevice device) async {
    _settings = switch (device.kind) {
      MediaDeviceKind.microphone => _settings.copyWith(microphone: device),
      MediaDeviceKind.audioOutput => _settings.copyWith(audioOutput: device),
      MediaDeviceKind.camera => _settings,
    };
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await _samples.close();
  }
}

class _Renderer extends MediaTrackRenderer {
  const _Renderer();
  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      const SizedBox.shrink();
}
