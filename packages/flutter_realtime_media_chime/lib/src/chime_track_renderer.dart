import 'package:flutter/widgets.dart';
import 'package:flutter_aws_chime/flutter_aws_chime.dart' as chime;
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_processed_video/flutter_realtime_processed_video.dart';

import 'chime_media_track.dart';

/// Renders a Chime tile through the native texture/PlatformView implementation,
/// short-circuiting local processed camera tracks directly to GPU textures.
class ChimeTrackRenderer extends MediaTrackRenderer {
  const ChimeTrackRenderer();

  @override
  bool handlesVideoFit(MediaVideoTrack track) {
    if (track is ChimeMediaVideoTrack &&
        track.isLocal &&
        !track.isScreenShare &&
        track.processedSource != null) {
      return track.processedSource!.platform == ProcessedVideoPlatform.web;
    }
    return true;
  }

  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      buildViewWithFit(context, track);

  @override
  Widget buildViewWithFit(
    BuildContext context,
    MediaVideoTrack track, {
    BoxFit fit = BoxFit.contain,
  }) {
    if (track is! ChimeMediaVideoTrack) {
      throw ArgumentError.value(
        track,
        'track',
        'ChimeTrackRenderer requires a ChimeMediaVideoTrack.',
      );
    }
    if (track.isLocal &&
        !track.isScreenShare &&
        track.processedSource != null) {
      return const ProcessedVideoTrackRenderer().buildViewWithFit(
        context,
        ProcessedVideoTrack(source: track.processedSource!),
        fit: fit,
      );
    }
    return chime.MeetingVideoTileView(tile: track.tile, fit: fit);
  }
}
