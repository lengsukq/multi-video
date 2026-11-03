import 'package:flutter/foundation.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_media_livekit/flutter_realtime_media_livekit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  test(
    'Windows uses the custom native frame hub for processed publication',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final meeting = LiveKitInteractiveSession();
      addTearDown(meeting.dispose);
      const source = ProcessedVideoSource(
        id: 'win-effects',
        platform: ProcessedVideoPlatform.windows,
        kind: ProcessedVideoSourceKind.nativeFrameHub,
        width: 1280,
        height: 720,
        frameRate: 24,
      );
      expect(meeting.capabilities.canBlurBackground, isTrue);
      expect(meeting.capabilities.canReplaceBackgroundImage, isTrue);
      expect(meeting.supportsProcessedVideoSource(source), isTrue);
      expect(
        meeting.supportsProcessedVideoSource(
          const ProcessedVideoSource(
            id: 'mac-effects',
            platform: ProcessedVideoPlatform.macos,
            kind: ProcessedVideoSourceKind.nativeFrameHub,
            width: 1280,
            height: 720,
            frameRate: 24,
          ),
        ),
        isFalse,
      );
    },
  );
  test('iOS supports a native Vision frame hub video track', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final meeting = LiveKitInteractiveSession();
    addTearDown(meeting.dispose);
    const source = ProcessedVideoSource(
      id: 'ios-vision',
      platform: ProcessedVideoPlatform.ios,
      kind: ProcessedVideoSourceKind.nativeFrameHub,
      width: 720,
      height: 1280,
      frameRate: 24,
    );
    expect(meeting.capabilities.canBlurBackground, isTrue);
    expect(meeting.capabilities.canReplaceBackgroundImage, isTrue);
    expect(meeting.supportsProcessedVideoSource(source), isTrue);
  });
}
