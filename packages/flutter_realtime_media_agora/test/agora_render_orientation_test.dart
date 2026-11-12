import 'package:agora_rtc_engine/agora_rtc_engine.dart' as agora;
import 'package:flutter/widgets.dart';
import 'package:flutter_realtime_media_agora/flutter_realtime_media_agora.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('local and remote camera canvases explicitly disable mirroring', (
    tester,
  ) async {
    for (final local in [true, false]) {
      late agora.AgoraVideoView rendered;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            rendered =
                const AgoraTrackRenderer().buildViewWithFit(
                      context,
                      AgoraMediaVideoTrack(
                        engine: _Engine(),
                        channelId: 'live',
                        uid: 123,
                        local: local,
                      ),
                      fit: BoxFit.cover,
                    )
                    as agora.AgoraVideoView;
            return const SizedBox.shrink();
          },
        ),
      );
      expect(
        rendered.controller.canvas.mirrorMode,
        agora.VideoMirrorModeType.videoMirrorModeDisabled,
      );
      expect(
        rendered.controller.canvas.renderMode,
        agora.RenderModeType.renderModeHidden,
      );
    }
  });

  testWidgets('macOS receiver binds remote screen to Agora screen source', (
    tester,
  ) async {
    late agora.AgoraVideoView rendered;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          rendered = const AgoraTrackRenderer().buildViewWithFit(
            context,
            AgoraMediaVideoTrack(
              engine: _Engine(),
              channelId: 'cross-platform',
              uid: 998,
              local: false,
              screenShare: true,
            ),
          ) as agora.AgoraVideoView;
          return const SizedBox.shrink();
        },
      ),
    );
    expect(
      rendered.controller.canvas.sourceType,
      agora.VideoSourceType.videoSourceScreen,
    );
  });
}

class _Engine extends Fake implements agora.RtcEngine {}
