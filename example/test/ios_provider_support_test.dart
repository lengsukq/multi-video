import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';

import 'package:multi_video/demo_provider_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('all Demo media vendors resolve their iOS meeting and live drivers', () {
    final drivers = [
      for (final bundle in createDemoProviders()) ...bundle.drivers,
    ];
    final registry = RealtimeDriverRegistry(
      drivers,
      platformResolver: () => RealtimeRuntimePlatform.ios,
    );
    for (final provider in ['livekit', 'agora', 'trtc', 'artc', 'aws']) {
      expect(registry.supportsProvider(provider), isTrue, reason: provider);
      for (final mode in [MediaRoomMode.meeting, MediaRoomMode.broadcast]) {
        final engine = registry.resolveMediaEngine(
          providerId: provider,
          roomMode: mode,
        );
        expect(
          registry.supportsProvider(engine),
          isTrue,
          reason: '$provider $mode',
        );
        expect(
          registry.resolvePlugins().any(
            (p) => p.providerId == engine && p.mediaFactory != null,
          ),
          isTrue,
        );
      }
    }
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

  test(
    'native iOS processed-video backgrounds are exposed only to publishers',
    () async {
      final drivers = [
        for (final bundle in createDemoProviders()) ...bundle.drivers,
      ];
      for (final provider in ['livekit', 'agora', 'trtc']) {
        final probe = drivers
            .singleWhere((p) => p.providerId == provider)
            .plugin
            .effectsProbe!;
        final publisher = await probe(MediaRole.participant);
        expect(publisher.canBlur, isTrue, reason: provider);
        expect(publisher.canReplaceImage, isTrue, reason: provider);
        final viewer = await probe(MediaRole.viewer);
        expect(viewer.isSupported, isFalse, reason: provider);
      }
    },
  );
}
