import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';

/// Floating room controls.
///
/// Groups are rendered as separate white capsules (media, collaboration,
/// panels, exit) exactly like the reference dock. Narrow windows keep the two
/// primary media actions and the exit visible, and let the rest scroll.
class RealtimeMeetingDock extends StatelessWidget {
  const RealtimeMeetingDock({
    super.key,
    required this.mediaGroup,
    this.collaborationGroup = const [],
    this.panelsGroup = const [],
    this.exitAction,
    this.leadingStatus,
    this.moreAction,
    this.showLabels = true,
  });
  final List<Widget> mediaGroup;
  final List<Widget> collaborationGroup;
  final List<Widget> panelsGroup;
  final Widget? exitAction;
  final Widget? leadingStatus;
  final Widget? moreAction;
  final bool showLabels;

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow =
              constraints.maxWidth < RealtimeBreakpoints.compactMaxWidth;
          // Phones pin mic/camera and the exit action. Panel toggles come
          // first in the scroll region so chat/members stay one tap away;
          // sharing extras and More follow.
          final narrowSecondary = [
            ...panelsGroup,
            ...mediaGroup.skip(2),
            ...collaborationGroup,
            if (moreAction != null) moreAction!,
          ];
          Widget group(List<Widget> children) => Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: style.surface,
              borderRadius: BorderRadius.circular(RealtimeUiTokens.dockRadius),
              border: Border.all(color: style.border),
              boxShadow: style.cardShadow,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(width: 2),
                  children[i],
                ],
              ],
            ),
          );

          if (narrow) {
            return Row(
              children: [
                if (mediaGroup.isNotEmpty)
                  group(mediaGroup.take(2).toList(growable: false)),
                if (narrowSecondary.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Expanded(
                    child: RealtimeDockScrollableStrip(
                      key: const ValueKey('meeting-dock-secondary-scroll'),
                      children: narrowSecondary,
                    ),
                  ),
                ] else
                  const Spacer(),
                if (exitAction != null) ...[
                  const SizedBox(width: 6),
                  group([exitAction!]),
                ],
              ],
            );
          }

          return RealtimeDockScrollableStrip(
            key: const ValueKey('meeting-dock-main-scroll'),
            children: [
              if (leadingStatus != null) ...[
                leadingStatus!,
                const SizedBox(width: 8),
              ],
              if (mediaGroup.isNotEmpty) group(mediaGroup),
              if (collaborationGroup.isNotEmpty) ...[
                const SizedBox(width: 8),
                group(collaborationGroup),
              ],
              if (panelsGroup.isNotEmpty) ...[
                const SizedBox(width: 8),
                group(panelsGroup),
              ],
              if (moreAction != null) ...[
                const SizedBox(width: 8),
                group([moreAction!]),
              ],
              if (exitAction != null) ...[
                const SizedBox(width: 8),
                group([exitAction!]),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Horizontal room actions must also work with a mouse in a narrow macOS /
/// Windows window. The default desktop scroll behavior doesn't allow mouse
/// dragging, and a vertical mouse wheel doesn't scroll a horizontal list.
/// Arrows provide an obvious discoverable way to reach the hidden controls.
class RealtimeDockScrollableStrip extends StatefulWidget {
  const RealtimeDockScrollableStrip({
    super.key,
    required this.children,
    this.reverse = false,
    this.dark = false,
  });

  final List<Widget> children;
  final bool reverse;
  final bool dark;

  @override
  State<RealtimeDockScrollableStrip> createState() =>
      _RealtimeDockScrollableStripState();
}

class _RealtimeDockScrollableStripState
    extends State<RealtimeDockScrollableStrip> {
  final _controller = ScrollController();

  bool get _hasMetrics =>
      _controller.hasClients && _controller.position.hasContentDimensions;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _scrollWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_hasMetrics) return;
    // Horizontal trackpad scrolling is already handled by Scrollable itself.
    // Translate vertical mouse-wheel input, including on macOS desktop.
    if (event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs()) return;
    final delta = event.scrollDelta.dy;
    if (delta == 0) return;
    final position = _controller.position;
    _controller.jumpTo(
      (_controller.offset + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  void _move(int direction) {
    if (!_hasMetrics) return;
    final position = _controller.position;
    final distance = position.viewportDimension * .7;
    final next =
        (_controller.offset +
                direction * (widget.reverse ? -distance : distance))
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    _controller.animateTo(
      next,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _controller.removeListener(_refresh);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    final position = _hasMetrics ? _controller.position : null;
    final canLeft =
        position != null &&
        (widget.reverse
            ? position.pixels < position.maxScrollExtent - 1
            : position.pixels > 1);
    final canRight =
        position != null &&
        (widget.reverse
            ? position.pixels > 1
            : position.pixels < position.maxScrollExtent - 1);

    Widget arrow({required bool left}) => Center(
      child: IconButton(
        tooltip: left ? 'Scroll dock left' : 'Scroll dock right',
        icon: Icon(
          left ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
        ),
        iconSize: 20,
        constraints: const BoxConstraints.tightFor(width: 30, height: 36),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: widget.dark
              ? RealtimeUiTokens.canvasDarkElevated
              : style.surface,
          foregroundColor: widget.dark ? Colors.white : style.text,
          side: BorderSide(
            color: widget.dark
                ? Colors.white.withValues(alpha: .24)
                : style.border,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
          ),
        ),
        onPressed: () => _move(left ? -1 : 1),
      ),
    );

    final overflowing =
        position != null &&
        position.maxScrollExtent - position.minScrollExtent > 1;

    // Keep both ends of the rail the same width, even when the first/last
    // arrow is not actionable. Overlaying arrows on the scroll view caused
    // them to cover the first/last tool and look off-centre at small widths.
    Widget arrowSlot(bool left) => SizedBox(
      width: overflowing ? 34 : 0,
      height: 36,
      child: overflowing && (left ? canLeft : canRight)
          ? arrow(left: left)
          : null,
    );

    final scrollView = ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: {
          PointerDeviceKind.mouse,
          PointerDeviceKind.touch,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
        },
      ),
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        reverse: widget.reverse,
        child: Row(mainAxisSize: MainAxisSize.min, children: widget.children),
      ),
    );

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        // The very first metrics arrive after build; then viewport changes
        // (e.g. resizing the floating meeting window) may add/remove arrows.
        WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
        return false;
      },
      child: Listener(
        onPointerSignal: _scrollWheel,
        // Keep the same Scrollable element mounted when content starts or
        // stops overflowing. Switching between scrollView and Row(scrollView)
        // detaches the old ScrollPosition during ensureVisible/animateTo,
        // leaving the visible strip at offset zero despite a completed scroll.
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            arrowSlot(true),
            SizedBox(width: overflowing ? 4 : 0),
            Expanded(child: scrollView),
            SizedBox(width: overflowing ? 4 : 0),
            arrowSlot(false),
          ],
        ),
      ),
    );
  }
}
