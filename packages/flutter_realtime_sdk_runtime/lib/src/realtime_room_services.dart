import 'realtime_video_effects.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_chat_core/flutter_realtime_chat_core.dart';
import 'package:flutter_realtime_processed_video/flutter_realtime_processed_video.dart'
    show ScreenCaptureProtectionService;
import 'realtime_client.dart';

typedef RealtimeRecordingSessionFactory =
    MediaCloudRecordingSession? Function(MediaRoomSession room);
typedef RealtimeStandaloneChatProvisionerFactory =
    StandaloneChatProvisioner Function();
/// Optional credential-free local device check used when the selected RTC
/// provider does not expose its own pre-join preview. The returned session
/// must start with capture disabled and is released before joining the room.
typedef RealtimeLocalPreviewFallbackFactory =
    Future<MediaLocalPreviewSession> Function({
      required String providerId,
      required MediaRole role,
    });

/// Factories return room-scoped objects owned by the SDK. Shared underlying
/// transports injected by the host remain host-owned.
class RealtimeRoomServices {
  const RealtimeRoomServices({
    this.mediaClientFactory,
    this.chatClientFactory,
    this.standaloneChatProvisionerFactory,
    this.interactionControlPlaneFactory,
    this.recordingSessionFactory,
    this.videoEffectsFactory,
    this.localPreviewFallbackFactory,
    this.screenCaptureProtection,
  });
  final RealtimeMediaClientFactory? mediaClientFactory;
  final RealtimeChatClientFactory? chatClientFactory;
  final RealtimeStandaloneChatProvisionerFactory?
  standaloneChatProvisionerFactory;
  final InteractionControlPlaneFactory? interactionControlPlaneFactory;
  final RealtimeVideoEffectsFactory? videoEffectsFactory;
  final RealtimeRecordingSessionFactory? recordingSessionFactory;
  /// A host-provided local hardware preview, not a replacement for the
  /// selected room's RTC provider or proof that provider publishing works.
  final RealtimeLocalPreviewFallbackFactory? localPreviewFallbackFactory;

  /// Optional custom screen-capture protection service (defaults to native OS
  /// protection when `preventScreenCapture: true` is configured on the SDK).
  final ScreenCaptureProtectionService? screenCaptureProtection;
}
