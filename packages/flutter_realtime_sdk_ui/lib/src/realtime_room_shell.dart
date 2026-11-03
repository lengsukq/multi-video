import 'package:flutter/material.dart';
import 'package:flutter_realtime_design_ui/flutter_realtime_design_ui.dart';

/// Shared responsive room frame for both Meeting and Live.
///
/// Business content is provided by each mode. The persistent header, tablet
/// navigation, desktop rail/sidebar and dedicated stage/dock are identical.
class RealtimeRoomShell extends StatelessWidget {
  const RealtimeRoomShell({
    super.key,
    required this.header,
    required this.stage,
    required this.dock,
    required this.compact,
    this.topContent,
    this.tabletRail,
    this.desktopRail,
    this.sidebar,
    this.controlsMaxWidth = 1100,
  });

  final Widget header;
  final Widget stage;
  final Widget dock;
  final bool compact;
  final Widget? topContent;
  final Widget? tabletRail;
  final Widget? desktopRail;
  final Widget? sidebar;
  final double controlsMaxWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // The header and its optional tool rail are content-driven. When text
      // scaling, keyboard insets or a diagnostic widget makes them unusually
      // tall, constrain only that region so the stage and dock retain usable
      // space rather than overflowing the entire iPhone viewport.
      final maxHeaderHeight = constraints.maxHeight.isFinite
          ? constraints.maxHeight * 0.4
          : 320.0;
      return Column(
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeaderHeight),
            child: SingleChildScrollView(
              primary: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  header,
                  if (tabletRail != null) tabletRail!,
                  if (topContent != null) topContent!,
                ],
              ),
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (desktopRail != null) desktopRail!,
                Expanded(
                  child: compact
                      ? Column(
                          children: [
                            Expanded(child: stage),
                            dock,
                          ],
                        )
                      : RealtimeIdleControls(
                          child: stage,
                          controls: dock,
                          controlsMaxWidth: controlsMaxWidth,
                          reserveControlsSpace: true,
                          autoHide: false,
                        ),
                ),
                if (sidebar != null) SizedBox(width: 340, child: sidebar!),
              ],
            ),
          ),
        ],
      );
    },
  );
}
