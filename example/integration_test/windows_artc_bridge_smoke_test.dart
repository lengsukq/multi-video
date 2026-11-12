import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_realtime_media_artc/flutter_realtime_media_artc.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows ARTC x64 SDK, channel and video texture load', (
    WidgetTester tester,
  ) async {
    expect(defaultTargetPlatform, TargetPlatform.windows);
    expect(await probeNativeArtcAvailability(), isTrue);

    const methods = MethodChannel(
      'com.oneplusdream.flutter_realtime_media_artc/methods',
    );
    final textureId = await methods.invokeMethod<int>('getTextureId', {
      'userId': 'artc-bridge-smoke',
      'isLocal': true,
      'isScreenShare': false,
    });
    expect(textureId, isNotNull);
    expect(textureId, greaterThanOrEqualTo(0));
    // No camera frame exists in this offline smoke test.
    final dimensions = await methods.invokeMapMethod<String, Object?>(
      'getTextureDimensions', {
        'userId': 'artc-bridge-smoke',
        'isLocal': true,
        'isScreenShare': false,
      },
    );
    expect(dimensions, isNull);
    await methods.invokeMethod<void>('dispose');
  });
}
