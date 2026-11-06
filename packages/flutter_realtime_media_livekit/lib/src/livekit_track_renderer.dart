import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'livekit_media_track.dart';

/// Renders a core video track backed by a LiveKit [lk.VideoTrack].
class LiveKitTrackRenderer extends MediaTrackRenderer {
  const LiveKitTrackRenderer();

  @override
  bool handlesVideoFit(MediaVideoTrack track) => true;

  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      buildViewWithFit(context, track);

  @override
  Widget buildViewWithFit(
    BuildContext context,
    MediaVideoTrack track, {
    BoxFit fit = BoxFit.contain,
  }) {
    if (track is! LiveKitMediaVideoTrack) {
      throw ArgumentError.value(
        track,
        'track',
        'LiveKitTrackRenderer requires a LiveKitMediaVideoTrack.',
      );
    }
    return lk.VideoTrackRenderer(
      track.liveKitTrack,
      // On iOS, the native camera can publish correctly while its local
      // Flutter texture remains black after a capture/renderer transition.
      // Use LiveKit's supported native platform view for local camera preview
      // only. Remote tracks and screen share retain their existing renderer.
      // A stable native-track identity ensures replacement tracks get a fresh
      // view even when their publication SID remains unchanged.
      key: ObjectKey(track.liveKitTrack),
      renderMode: !kIsWeb &&
              defaultTargetPlatform == TargetPlatform.iOS &&
              track.isLocal &&
              !track.isScreenShare
          ? lk.VideoRenderMode.platformView
          : lk.VideoRenderMode.auto,
      // Match the published orientation instead of mirroring self-view.
      mirrorMode: lk.VideoViewMirrorMode.off,
      fit: fit == BoxFit.contain
          ? lk.VideoViewFit.contain
          : lk.VideoViewFit.cover,
    );
  }
}
