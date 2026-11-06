import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_realtime_media_livekit/flutter_realtime_media_livekit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

void main() {
  testWidgets('iOS self-camera uses native view rather than texture', (
    tester,
  ) async {
    // Widget test binding validates global foundation overrides before
    // tearDown runs, so restore the override before the test completes.
    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      debugDefaultTargetPlatformOverride = platform;
      for (final local in [true, false]) {
        for (final screenShare in [true, false]) {
          final nativeTrack = _Track();
          late lk.VideoTrackRenderer rendered;
          await tester.pumpWidget(
            Builder(
              builder: (context) {
                rendered = const LiveKitTrackRenderer().buildViewWithFit(
                  context,
                  LiveKitMediaVideoTrack(
                    liveKitTrack: nativeTrack,
                    id: 'camera',
                    participantId: 'participant',
                    isLocal: local,
                    isScreenShare: screenShare,
                  ),
                ) as lk.VideoTrackRenderer;
                return const SizedBox.shrink();
              },
            ),
          );
          expect(
            rendered.renderMode,
            platform == TargetPlatform.iOS && local && !screenShare
                ? lk.VideoRenderMode.platformView
                : lk.VideoRenderMode.auto,
          );
          expect(rendered.key, ObjectKey(nativeTrack));
        }
      }
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('self view and audience view use the same video orientation', (
    tester,
  ) async {
    for (final local in [true, false]) {
      late lk.VideoTrackRenderer rendered;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            rendered =
                const LiveKitTrackRenderer().buildViewWithFit(
                      context,
                      LiveKitMediaVideoTrack(
                        liveKitTrack: _Track(),
                        id: 'camera',
                        participantId: 'host',
                        isLocal: local,
                        isScreenShare: false,
                      ),
                      fit: BoxFit.cover,
                    )
                    as lk.VideoTrackRenderer;
            return const SizedBox.shrink();
          },
        ),
      );
      expect(rendered.mirrorMode, lk.VideoViewMirrorMode.off);
      expect(rendered.fit, lk.VideoViewFit.cover);
    }
  });
}

class _Track extends Fake implements lk.VideoTrack {}
