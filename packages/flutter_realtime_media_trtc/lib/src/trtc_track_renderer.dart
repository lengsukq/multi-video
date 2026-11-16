import 'package:flutter/widgets.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_video_view.dart';

import 'trtc_media_track.dart';

/// Renders a TRTC local camera preview or a subscribed remote camera stream.
class TrtcTrackRenderer extends MediaTrackRenderer {
  const TrtcTrackRenderer();

  // TRTC's platform SDK configures fit render params for native video views.
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
    if (track is! TrtcMediaVideoTrack) {
      throw ArgumentError.value(
        track,
        'track',
        'TrtcTrackRenderer requires a TrtcMediaVideoTrack.',
      );
    }
    return _TrtcVideoSurface(key: ValueKey(track.id), track: track, fit: fit);
  }
}

class _TrtcVideoSurface extends StatefulWidget {
  const _TrtcVideoSurface({
    super.key,
    required this.track,
    this.fit = BoxFit.contain,
  });

  final TrtcMediaVideoTrack track;
  final BoxFit fit;

  @override
  State<_TrtcVideoSurface> createState() => _TrtcVideoSurfaceState();
}

class _TrtcVideoSurfaceState extends State<_TrtcVideoSurface> {
  int? _viewId;

  @override
  void didUpdateWidget(covariant _TrtcVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id != widget.track.id) {
      _bindView();
    } else if (oldWidget.fit != widget.fit) {
      _applyFit();
    }
  }

  void _applyFit() {
    if (_viewId == null) return;
    widget.track.setFillMode?.call(widget.fit == BoxFit.contain);
  }

  void _bindView() {
    final viewId = _viewId;
    if (viewId == null) return;
    widget.track.startRendering(viewId);
    _applyFit();
  }

  @override
  void dispose() {
    final viewId = _viewId;
    if (viewId != null) widget.track.stopRendering();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TRTCCloudVideoView(
    onViewCreated: (viewId) {
      _viewId = viewId;
      _bindView();
    },
  );
}
