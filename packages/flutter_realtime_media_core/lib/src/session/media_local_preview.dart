import 'dart:async';

import '../model/media_capabilities.dart';
import '../model/media_background_effect.dart';
import '../model/media_device.dart';
import '../model/media_error.dart';
import '../model/media_role.dart';
import '../model/media_track.dart';
import 'media_device_controller.dart';
import '../view/media_track_view.dart';

/// User-selected local media state collected before joining a room.
///
/// Device values are provider-neutral handles. Their IDs are opaque and are
/// only meaningful to the provider that created this selection.
class MediaLocalPreviewSettings {
  const MediaLocalPreviewSettings({
    this.microphoneEnabled = false,
    this.cameraEnabled = false,
    this.microphone,
    this.camera,
    this.audioOutput,
    this.backgroundEffect = const MediaBackgroundEffect.none(),
  });

  final bool microphoneEnabled;
  final bool cameraEnabled;
  final MediaDevice? microphone;
  final MediaDevice? camera;
  final MediaDevice? audioOutput;
  final MediaBackgroundEffect backgroundEffect;

  MediaLocalPreviewSettings copyWith({
    bool? microphoneEnabled,
    bool? cameraEnabled,
    MediaDevice? microphone,
    MediaDevice? camera,
    MediaDevice? audioOutput,
    MediaBackgroundEffect? backgroundEffect,
  }) => MediaLocalPreviewSettings(
    microphoneEnabled: microphoneEnabled ?? this.microphoneEnabled,
    cameraEnabled: cameraEnabled ?? this.cameraEnabled,
    microphone: microphone ?? this.microphone,
    camera: camera ?? this.camera,
    audioOutput: audioOutput ?? this.audioOutput,
    backgroundEffect: backgroundEffect ?? this.backgroundEffect,
  );
}

/// Optional provider surface for opening a local preview before room join.
///
/// Implementations must not create or join a backend room. Calling [dispose]
/// releases every local capture resource, including when setup only partially
/// succeeded.
abstract interface class MediaLocalPreviewSession
    implements MediaDeviceController {
  String get providerId;

  MediaRole get role;

  MediaCapabilities get capabilities;

  MediaVideoTrack? get cameraTrack;

  MediaTrackRenderer get renderer;

  MediaLocalPreviewSettings get settings;

  Future<void> setMicrophoneEnabled(bool enabled);

  Future<void> setCameraEnabled(bool enabled);

  Future<void> dispose();
}

/// Optional real microphone signal levels for the pre-join device check.
///
/// Values are normalized to [0, 1]. Implementations must derive samples from
/// actual capture, emit no synthetic levels, and stop sampling after preview
/// disposal. The UI treats an unavailable/idle stream as silence, not speech.
/// The stream must not trigger capture on its own: capture is explicitly
/// enabled through [MediaLocalPreviewSession.setMicrophoneEnabled].
abstract interface class MediaLocalPreviewAudioLevels {
  Stream<double> get microphoneLevels;
}

/// Optional settings transfer hook for pre-join previews backed by a
/// different local capture provider from the destination RTC engine.
/// Device IDs are opaque to their originating provider, so implementers
/// must not forward incompatible IDs to the joined room.
abstract interface class MediaLocalPreviewRoomSettings {
  MediaLocalPreviewSettings get roomSettings;
}

/// Opt-in factory implemented by adapters that support independent local
/// camera preview before backend room credentials are issued.
abstract interface class MediaLocalPreviewFactory {
  /// Return with microphone and camera capture disabled. Capture starts only
  /// after the user explicitly enables a device on the preview session.
  Future<MediaLocalPreviewSession> createLocalPreview({
    required MediaRole role,
  });
}

/// Optional asynchronous failures emitted after a preview has started.
abstract interface class MediaLocalPreviewFailureEvents {
  Stream<RealtimeException> get failures;
}
