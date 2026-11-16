import 'package:flutter/foundation.dart';
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multi_video/demo_realtime_configuration.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows Demo uses an actual local audio preview for RTC adapters', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final demo = createDemoRealtime('http://10.0.111.99:3000');
    final fallback = demo.sdk.services.localPreviewFallbackFactory;
    expect(fallback, isNotNull);

    // No room token or server is needed to create this local hardware check.
    final preview = await fallback!(
      providerId: 'trtc',
      role: MediaRole.participant,
    );
    try {
      expect(preview.settings.microphoneEnabled, isFalse);
      expect(preview.capabilities.canPublishAudio, isTrue);
      expect(preview.capabilities.canEnumerateMicrophones, isTrue);
      expect(preview.providerId, 'livekit',
          reason: 'Only the local device check uses LiveKit; room RTC stays TRTC');
    } finally {
      await preview.dispose();
    }
  });

  test('preview fallback is only enabled by the real Windows runtime', () {
    final demo = createDemoRealtime('http://192.168.31.2:3000');
    final isWindows =
        resolveRealtimeRuntimePlatform() == RealtimeRuntimePlatform.windows;
    expect(
      demo.sdk.services.localPreviewFallbackFactory,
      isWindows ? isNotNull : isNull,
    );
  });
}
