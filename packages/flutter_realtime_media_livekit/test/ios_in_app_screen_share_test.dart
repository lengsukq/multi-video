import 'package:flutter_realtime_media_livekit/src/ios_in_app_screen_share.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('successful capture is published and retained', () async {
    final calls = <String>[];
    final track = await captureAndPublishIosInAppScreen<int>(
      capture: () async {
        calls.add('capture');
        return 123;
      },
      publish: (track) async => calls.add('publish:$track'),
      release: (track) async => calls.add('release:$track'),
    );
    expect(track, 123);
    expect(calls, ['capture', 'publish:123']);
  });

  test('capture failure never attempts publication', () async {
    final calls = <String>[];
    await expectLater(
      captureAndPublishIosInAppScreen<int>(
        capture: () async => throw StateError('ReplayKit permission denied'),
        publish: (_) async => calls.add('publish'),
        release: (_) async => calls.add('release'),
      ),
      throwsA(isA<StateError>()),
    );
    expect(calls, isEmpty);
  });

  test('publish failure releases the captured track once', () async {
    final calls = <String>[];
    await expectLater(
      captureAndPublishIosInAppScreen<int>(
        capture: () async => 123,
        publish: (track) async {
          calls.add('publish:$track');
          throw StateError('LiveKit publish failed');
        },
        release: (track) async => calls.add('release:$track'),
      ),
      throwsA(isA<StateError>()),
    );
    expect(calls, ['publish:123', 'release:123']);
  });

  test('cleanup error does not mask the original publish error', () async {
    await expectLater(
      captureAndPublishIosInAppScreen<int>(
        capture: () async => 123,
        publish: (_) async => throw StateError('original publish failure'),
        release: (_) async => throw StateError('cleanup failure'),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'original publish failure',
        ),
      ),
    );
  });
}
