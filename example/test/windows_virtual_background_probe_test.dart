import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';

import 'package:multi_video/demo_provider_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Windows RTC drivers expose virtual backgrounds to publishers', () async {
    final drivers = [
      for (final bundle in createDemoProviders()) ...bundle.drivers,
    ];
    for (final provider in ['livekit', 'agora', 'trtc']) {
      final driver = drivers.singleWhere((p) => p.providerId == provider);
      expect(
        driver.supports(RealtimeRuntimePlatform.windows),
        isTrue,
        reason: provider,
      );
      final probe = driver.plugin.effectsProbe;
      expect(probe, isNotNull, reason: provider);
      for (final role in [MediaRole.host, MediaRole.participant]) {
        final capabilities = await probe!(role);
        expect(capabilities.canBlur, isTrue, reason: '$provider $role');
        expect(capabilities.canReplaceImage, isTrue, reason: '$provider $role');
      }
      final viewer = await probe!(MediaRole.viewer);
      expect(viewer.isSupported, isFalse, reason: '$provider viewer');
    }
  });
}
