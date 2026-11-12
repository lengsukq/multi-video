import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';
import 'package:flutter_realtime_video_effects/flutter_realtime_video_effects.dart';
import 'demo_provider_catalog.dart';

/// The selected RTC provider still handles media when the room is joined.
/// Before that point, use the registered LiveKit/WebRTC device adapter as a
/// local capture check for providers without a credential-free preview.
Future<MediaLocalPreviewSession> _windowsLocalPreviewFallback({
  required String providerId,
  required MediaRole role,
}) async {
  final provider = createDemoProviders()
      .expand((bundle) => bundle.drivers)
      .firstWhere(
        (driver) =>
            driver.providerId == 'livekit' &&
            driver.supports(RealtimeRuntimePlatform.windows),
      )
      .plugin
      .mediaFactory;
  if (provider is! MediaLocalPreviewFactory) {
    throw StateError('Windows local microphone preview is not registered.');
  }
  return (provider as MediaLocalPreviewFactory).createLocalPreview(role: role);
}

/// Demo explicitly elects every optional capability it showcases.
Realtime createDemoRealtime(String backendUrl, {String appToken = ''}) =>
    Realtime(
      providers: createDemoProviders(),
      backendUrl: backendUrl,
      services: RealtimeRoomServices(
        videoEffectsFactory: DefaultRealtimeVideoEffects.new,
        localPreviewFallbackFactory:
            resolveRealtimeRuntimePlatform() == RealtimeRuntimePlatform.windows
            ? _windowsLocalPreviewFallback
            : null,
      ),
      tokenProvider: appToken.trim().isEmpty ? null : () async => appToken,
      featurePlugins: const [
        ClassroomPreset(),
        SharedContentPreset(),
        SystemAnnotationPreset(),
        LivePreset(),
      ],
    );
