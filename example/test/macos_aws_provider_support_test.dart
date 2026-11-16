import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';

import 'package:multi_video/demo_provider_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('macOS Demo exposes AWS Chime for meeting and IVS for live', () {
    final drivers = [
      for (final bundle in createDemoProviders()) ...bundle.drivers,
    ];
    final registry = RealtimeDriverRegistry(
      drivers,
      platformResolver: () => RealtimeRuntimePlatform.macos,
    );
    expect(registry.supportsProvider('aws'), isTrue);
    for (final (mode, engine) in [
      (MediaRoomMode.meeting, 'chime'),
      (MediaRoomMode.broadcast, 'ivs'),
    ]) {
      expect(
        registry.resolveMediaEngine(providerId: 'aws', roomMode: mode),
        engine,
      );
      expect(
        registry.resolvePlugins().any(
          (plugin) => plugin.providerId == engine && plugin.mediaFactory != null,
        ),
        isTrue,
      );
    }
  });
}
