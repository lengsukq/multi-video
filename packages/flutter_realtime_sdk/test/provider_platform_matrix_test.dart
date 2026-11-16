import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/default_driver_catalog.dart';

void main() {
  final drivers = createDefaultRealtimeDrivers();

  test('production entry does not register implicit providers', () {
    final sdk = RealtimeSdk.standard();
    expect(sdk.supportedProviderIds, isEmpty);
  });

  test('every platform resolves exactly its advertised provider catalog', () {
    expect(drivers, isNotEmpty);
    for (final platform in RealtimeRuntimePlatform.values) {
      final registry = RealtimeDriverRegistry(
        drivers,
        platformResolver: () => platform,
      );
      final expected = {
        for (final driver in drivers)
          if (driver.supports(platform)) driver.publicId,
      };
      final sdk = RealtimeSdk.standard(
        platformResolver: () => platform,
        drivers: drivers,
      );
      expect(sdk.supportedProviderIds.toSet(), expected, reason: platform.name);
      for (final id in registry.knownProviderIds) {
        expect(
          sdk.supportsProvider(id),
          expected.contains(id),
          reason: '${platform.name}:$id',
        );
      }
      final selected = registry.resolvePlugins();
      expect(
        selected.map((plugin) => plugin.providerId).toSet().length,
        selected.length,
        reason: 'Duplicate engine on ${platform.name}',
      );
    }
  });

  test('unsupported product chat adapters are typed on every platform', () {
    final chatIds = {
      for (final driver in drivers)
        if (driver.plugin.chatFactory != null) driver.providerId,
    };
    for (final platform in RealtimeRuntimePlatform.values) {
      final registry = RealtimeDriverRegistry(
        drivers,
        platformResolver: () => platform,
      );
      final plugins = RealtimePluginRegistry(registry.resolvePlugins());
      for (final id in chatIds) {
        final supported = drivers.any(
          (driver) =>
              driver.providerId == id &&
              driver.plugin.chatFactory != null &&
              driver.supports(platform),
        );
        if (supported) continue;
        expect(
          () => plugins.chat.require(id).parseJoinInfo(const {}),
          throwsA(
            isA<RealtimeException>().having(
              (error) => error.code,
              'error code',
              RealtimeErrorCode.unsupportedPlatform,
            ),
          ),
          reason: '${platform.name}:$id',
        );
      }
    }
  });

  test('unsupported media adapters are typed for every runtime platform', () {
    final mediaIds = {
      for (final driver in drivers)
        if (driver.plugin.mediaFactory != null) driver.providerId,
    };
    for (final platform in RealtimeRuntimePlatform.values) {
      final registry = RealtimeDriverRegistry(
        drivers,
        platformResolver: () => platform,
      );
      final plugins = RealtimePluginRegistry(registry.resolvePlugins());
      for (final id in mediaIds) {
        final supported = drivers.any(
          (driver) =>
              driver.providerId == id &&
              driver.plugin.mediaFactory != null &&
              driver.supports(platform),
        );
        if (supported) continue;
        expect(
          () => plugins.media.registry.require(id).parseJoinInfo(const {}),
          throwsA(
            isA<RealtimeException>().having(
              (error) => error.code,
              'error code',
              RealtimeErrorCode.unsupportedPlatform,
            ),
          ),
          reason: '${platform.name}:$id',
        );
      }
    }
  });

  test('AWS routes meeting and live to distinct SDK media engines', () {
    final registry = RealtimeDriverRegistry(
      drivers,
      platformResolver: () => RealtimeRuntimePlatform.android,
    );
    expect(
      registry.resolveMediaEngine(
        providerId: 'aws',
        roomMode: MediaRoomMode.meeting,
      ),
      'chime',
    );
    expect(
      registry.resolveMediaEngine(
        providerId: 'aws',
        roomMode: MediaRoomMode.broadcast,
      ),
      'ivs',
    );
  });

  test('Windows resolves all three independent product Chat providers', () {
    final registry = RealtimeDriverRegistry(
      drivers,
      platformResolver: () => RealtimeRuntimePlatform.windows,
    );
    final chatFactories = {
      for (final plugin in registry.resolvePlugins())
        if (plugin.chatFactory != null) plugin.providerId,
    };
    expect(chatFactories,
        containsAll({'agora-chat', 'tencent-chat', 'ivs-chat'}));
  });
}
