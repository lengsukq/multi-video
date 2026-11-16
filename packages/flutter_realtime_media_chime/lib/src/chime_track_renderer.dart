import 'package:flutter/widgets.dart';
import 'package:flutter_aws_chime/flutter_aws_chime.dart' as chime;
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'chime_media_track.dart';

/// Renders a Chime tile through the existing native PlatformView implementation.
class ChimeTrackRenderer extends MediaTrackRenderer {
  const ChimeTrackRenderer();

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
    if (track is! ChimeMediaVideoTrack) {
      throw ArgumentError.value(
        track,
        'track',
        'ChimeTrackRenderer requires a ChimeMediaVideoTrack.',
      );
    }
    return chime.MeetingVideoTileView(tile: track.tile, fit: fit);
  }
}
