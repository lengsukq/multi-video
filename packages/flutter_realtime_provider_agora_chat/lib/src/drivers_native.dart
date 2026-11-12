import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_chat_agora/flutter_realtime_chat_agora.dart';

List<RealtimeProviderDriver> createDrivers(int maxMessages) => [
  RealtimeProviderDriver(
    platforms: const {
      RealtimeRuntimePlatform.android,
      RealtimeRuntimePlatform.ios,
      RealtimeRuntimePlatform.macos,
      RealtimeRuntimePlatform.windows,
    },
    plugin: RealtimeProviderPlugin(
      id: 'agora-chat',
      metadata: const RealtimeProviderMetadata(displayName: 'Agora Chat'),
      chatFactory: AgoraChatSessionFactory(maxMessages: maxMessages),
    ),
  ),
];
