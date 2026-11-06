import 'package:flutter/foundation.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_media_livekit/flutter_realtime_media_livekit.dart';

const _mobileAndMac = {
  RealtimeRuntimePlatform.android,
  RealtimeRuntimePlatform.ios,
  RealtimeRuntimePlatform.macos,
};
const _mobileAndDesktop = {..._mobileAndMac, RealtimeRuntimePlatform.windows};
List<RealtimeProviderDriver> createDrivers(int maxMessages) => [
  RealtimeProviderDriver(
    platforms: _mobileAndDesktop,
    plugin: RealtimeProviderPlugin(
      id: 'livekit',
      metadata: const RealtimeProviderMetadata(displayName: 'LiveKit'),
      effectsProbe: (role) => _probeEffects('livekit', role),
      mediaFactory: const LiveKitSessionFactory(),
      renderer: LiveKitTrackRenderer(),
    ),
  ),
];

Future<MediaBackgroundCapabilities> _probeEffects(
  String engine,
  MediaRole role,
) async {
  if (role == MediaRole.viewer ||
      (!kIsWeb &&
          defaultTargetPlatform != TargetPlatform.android &&
          defaultTargetPlatform != TargetPlatform.iOS &&
          defaultTargetPlatform != TargetPlatform.macOS &&
          defaultTargetPlatform != TargetPlatform.windows)) {
    return const MediaBackgroundCapabilities.none();
  }
  return const MediaBackgroundCapabilities(
    canBlur: true,
    canReplaceImage: true,
  );
}
