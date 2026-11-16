import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../model/media_track.dart';

/// Temporarily hides descendant iOS platform video views while a Flutter modal
/// dialog covers the stage, without unmounting or unbinding native tiles.
class MediaPlatformViewOcclusion extends InheritedWidget {
  const MediaPlatformViewOcclusion({
    super.key,
    required this.occluded,
    required super.child,
  });

  final bool occluded;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MediaPlatformViewOcclusion>()
          ?.occluded ??
      false;

  @override
  bool updateShouldNotify(MediaPlatformViewOcclusion oldWidget) =>
      occluded != oldWidget.occluded;
}

/// Renders a provider video track.
///
/// Adapters implement this and pass it to [MediaTrackView], so shared UI never
/// imports a provider SDK.
abstract class MediaTrackRenderer {
  const MediaTrackRenderer();

  /// Whether this adapter guarantees aspect-preserving contain/cover when it
  /// receives the *entire* destination rectangle. Opt in only if the native
  /// SDK/player actually scales frames using their decoded dimensions.
  /// Platform views and textures that simply resize to their Flutter bounds
  /// must return false so [MediaTrackView] can preserve track geometry.
  bool handlesVideoFit(MediaVideoTrack track) => false;

  /// Builds the widget that displays [track].
  Widget buildView(BuildContext context, MediaVideoTrack track);

  /// Builds [track] while allowing shared UI to request a scaling mode.
  ///
  /// The default implementation preserves compatibility with existing custom
  /// renderers. Provider adapters with their own native scaling should override
  /// this so [BoxFit.contain] also reaches the provider view.
  Widget buildViewWithFit(
    BuildContext context,
    MediaVideoTrack track, {
    BoxFit fit = BoxFit.contain,
  }) => buildView(context, track);
}

/// Displays a [MediaVideoTrack] using a provider [MediaTrackRenderer].
///
/// Renders [placeholder] (or an empty box) when [track] is null, which is the
/// common case for participants that are not publishing video yet.
class MediaTrackView extends StatelessWidget {
  const MediaTrackView({
    super.key,
    required this.renderer,
    this.track,
    this.placeholder,
    this.fit = BoxFit.contain,
    this.rendererManagesFit = false,
  });

  /// Provider renderer, for example `LiveKitTrackRenderer()`.
  final MediaTrackRenderer renderer;

  /// Track to display, or null when nothing is published.
  final MediaVideoTrack? track;

  /// Widget shown while [track] is null.
  final Widget? placeholder;

  /// How the video fills the available space. Defaults to preserving the whole
  /// frame, with empty space when the video and view have different proportions.
  final BoxFit fit;

  /// Let the provider renderer determine the frame's actual aspect ratio
  /// inside the full viewport. Use this only for renderers implementing native
  /// aspect-preserving fit/cover; otherwise a platform view/texture can
  /// *stretch* a landscape camera into a portrait window.
  ///
  /// Keep false for screen-sharing/other callers that depend on the supplied
  /// track dimensions for explicit aspect-ratio layout.
  final bool rendererManagesFit;

  @override
  Widget build(BuildContext context) {
    final current = track;
    if (current == null) {
      return placeholder ?? const SizedBox.expand();
    }
    final builtView = renderer.buildViewWithFit(context, current, fit: fit);
    final video = rendererManagesFit
        ? SizedBox.expand(child: builtView)
        : FittedBox(
            fit: fit,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: current.width > 0 ? current.width.toDouble() : 640,
              height: current.height > 0 ? current.height.toDouble() : 360,
              child: builtView,
            ),
          );
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      final occluded = MediaPlatformViewOcclusion.of(context);
      return Stack(
        fit: StackFit.expand,
        children: [
          if (occluded)
            placeholder ?? const ColoredBox(color: Color(0xFF101828)),
          Offstage(offstage: occluded, child: video),
        ],
      );
    }
    return video;
  }
}
