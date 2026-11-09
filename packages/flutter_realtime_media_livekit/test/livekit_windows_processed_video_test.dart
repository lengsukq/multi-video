import 'package:flutter/foundation.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_media_livekit/flutter_realtime_media_livekit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_realtime_media_livekit/src/livekit_processed_video_native.dart'
    show checkedProcessedLiveKitStreamDescriptor;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Windows processed-video stream descriptor requires WebRTC ownerTag', () {
    final valid = <String, dynamic>{
      'streamId': 'test-native-stream',
      'ownerTag': 'local',
      'audioTracks': <Object>[],
      'videoTracks': [
        <String, dynamic>{
          'id': 'test-native-track',
          'label': 'processed_video',
          'kind': 'video',
          'enabled': true,
          'settings': <String, dynamic>{},
        },
      ],
    };
    expect(
      checkedProcessedLiveKitStreamDescriptor(valid)['ownerTag'],
      'local',
    );
    final withoutOwner = Map<String, dynamic>.from(valid)
      ..remove('ownerTag');
    expect(
      () => checkedProcessedLiveKitStreamDescriptor(withoutOwner),
      throwsA(isA<StateError>()),
    );
  });
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
