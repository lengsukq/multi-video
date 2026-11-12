import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_media_artc/flutter_realtime_media_artc.dart';

const _mobileAndDesktop = {
  RealtimeRuntimePlatform.android,
  RealtimeRuntimePlatform.ios,
  RealtimeRuntimePlatform.macos,
  RealtimeRuntimePlatform.windows,
};
List<RealtimeProviderDriver> createDrivers(int maxMessages) => [
  RealtimeProviderDriver(
    platforms: _mobileAndDesktop,
    plugin: RealtimeProviderPlugin(
      id: 'artc',
      metadata: RealtimeProviderMetadata(displayName: 'Alibaba ARTC'),
      effectsProbe: (role) => _probeEffects('artc', role),
      mediaFactory: ArtcSessionFactory(),
      renderer: ArtcTrackRenderer(),
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
          defaultTargetPlatform != TargetPlatform.macOS)) {
    return const MediaBackgroundCapabilities.none();
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
    final channel = {
      'artc': 'com.oneplusdream.flutter_realtime_media_artc/methods',
    }[engine];
    if (channel != null &&
        await MethodChannel(
              channel,
            ).invokeMethod<bool>('probeProcessedVideoInput') !=
            true) {
      return const MediaBackgroundCapabilities.none();
    }
  }
  return const MediaBackgroundCapabilities(
    canBlur: true,
    canReplaceImage: true,
  );
}
