import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_media_chime/flutter_realtime_media_chime.dart';
import 'package:flutter_realtime_media_ivs/flutter_realtime_media_ivs.dart';

const _mobileAndMac = {
  RealtimeRuntimePlatform.android,
  RealtimeRuntimePlatform.ios,
  RealtimeRuntimePlatform.macos,
};
// Both Windows runtimes are experimental and fail closed without explicit
// opt-in. AWS does not support IVS Broadcast inside an embedded WebView.
const _mobileAndDesktop = {
  ..._mobileAndMac,
  RealtimeRuntimePlatform.windows,
};
List<RealtimeProviderDriver> createDrivers(int maxMessages) => [
  RealtimeProviderDriver(
    platforms: _mobileAndDesktop,
    publicProviderId: 'aws',
    mediaRoomModes: const {MediaRoomMode.meeting},
    plugin: RealtimeProviderPlugin(
      id: 'chime',
      metadata: const RealtimeProviderMetadata(displayName: 'AWS'),
      effectsProbe: (role) => _probeEffects('chime', role),
      mediaFactory: ChimeSessionFactory(),
      renderer: const ChimeTrackRenderer(),
    ),
  ),
  RealtimeProviderDriver(
    platforms: _mobileAndDesktop,
    publicProviderId: 'aws',
    mediaRoomModes: const {MediaRoomMode.broadcast},
    plugin: RealtimeProviderPlugin(
      id: 'ivs',
      metadata: RealtimeProviderMetadata(displayName: 'AWS'),
      effectsProbe: (role) => _probeEffects('ivs', role),
      mediaFactory: IvsSessionFactory(),
      renderer: IvsTrackRenderer(),
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
      'chime': 'com.oneplusdream.aws.chime.methodChannel',
      'ivs': 'com.oneplusdream.flutter_realtime_media_ivs/methods',
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
