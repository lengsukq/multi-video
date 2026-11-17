import 'package:agora_rtc_engine/agora_rtc_engine.dart' as agora;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_processed_video/flutter_realtime_processed_video.dart';

import 'agora_media_track.dart';

/// Renders an Agora camera or screen track through AgoraVideoView with
/// per-engine controller caching and macOS/Android FlutterTexture acceleration.
class AgoraTrackRenderer extends MediaTrackRenderer {
  const AgoraTrackRenderer();

  static final Expando<Map<String, agora.VideoViewController>> _controllers =
      Expando<Map<String, agora.VideoViewController>>('_agoraVideoControllers');

  @override
  bool handlesVideoFit(MediaVideoTrack track) =>
      track is AgoraMediaVideoTrack &&
      (track.processedSource == null ||
          track.processedSource!.platform == ProcessedVideoPlatform.web);

  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      buildViewWithFit(context, track);

  @override
  Widget buildViewWithFit(
    BuildContext context,
    MediaVideoTrack track, {
    BoxFit fit = BoxFit.contain,
  }) {
    if (track is! AgoraMediaVideoTrack) {
      throw ArgumentError.value(
        track,
        'track',
        'AgoraTrackRenderer requires an AgoraMediaVideoTrack.',
      );
    }
    if (track.isLocal && track.processedSource != null) {
      return const ProcessedVideoTrackRenderer().buildViewWithFit(
        context,
        ProcessedVideoTrack(source: track.processedSource!),
        fit: fit,
      );
    }
    final renderMode = fit == BoxFit.contain
        ? agora.RenderModeType.renderModeFit
        : agora.RenderModeType.renderModeHidden;
    // Use GPU texture rendering on both Android (avoiding SurfaceProducer
    // frame acquisition stalls) and macOS (avoiding AppKitView layer sync).
    final useFlutterTexture =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.macOS);
    final sourceType = track.isScreenShare
        ? agora.VideoSourceType.videoSourceScreen
        : agora.VideoSourceType.videoSourceCamera;
    final cacheKey =
        '${track.id}:${renderMode.name}:${sourceType.name}:$useFlutterTexture';
    final engineControllers = _controllers[track.engine] ??=
        <String, agora.VideoViewController>{};
    final controller = engineControllers.putIfAbsent(cacheKey, () {
      if (track.isLocal) {
        return agora.VideoViewController(
          rtcEngine: track.engine,
          useFlutterTexture: useFlutterTexture,
          canvas: agora.VideoCanvas(
            uid: 0,
            renderMode: renderMode,
            mirrorMode: agora.VideoMirrorModeType.videoMirrorModeDisabled,
            sourceType: sourceType,
          ),
        );
      }
      return agora.VideoViewController.remote(
        rtcEngine: track.engine,
        useFlutterTexture: useFlutterTexture,
        canvas: agora.VideoCanvas(
          uid: track.uid,
          renderMode: renderMode,
          mirrorMode: agora.VideoMirrorModeType.videoMirrorModeDisabled,
          // Desktop screen capture is published by Agora as the screen
          // source, not the remote participant's camera source. Leaving the
          // canvas default at camera renders a black/empty remote share.
          sourceType: sourceType,
        ),
        connection: agora.RtcConnection(channelId: track.channelId),
      );
    });

    return agora.AgoraVideoView(
      key: ValueKey(cacheKey),
      controller: controller,
    );
  }
}
