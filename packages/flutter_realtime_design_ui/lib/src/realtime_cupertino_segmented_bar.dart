part of '../flutter_realtime_design_ui.dart';

class RealtimeCupertinoSegmentedBar<T extends Object> extends StatelessWidget {
  const RealtimeCupertinoSegmentedBar({
    super.key,
    required this.children,
    required this.groupValue,
    required this.onValueChanged,
    this.backgroundColor,
    this.thumbColor,
    this.padding = const EdgeInsets.all(4),
  });

  final Map<T, Widget> children;
  final T? groupValue;
  final ValueChanged<T> onValueChanged;
  final Color? backgroundColor;
  final Color? thumbColor;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    final scale = MediaQuery.textScalerOf(context);
    final resolvedPadding = padding.resolve(Directionality.of(context));
    const minHeight = 48.0;
    final height = minHeight + (scale.scale(13) - 13).clamp(0, 40);
    final radius = RealtimeUiTokens.segmentedOuterRadius(
      height: height,
      preferredRadius: RealtimeUiThemeExtension.of(context).controlRadius,
    );
    final thumbRadius = RealtimeUiTokens.segmentedThumbRadius(
      outerRadius: radius,
      inset: resolvedPadding.top,
    );
    final entries = children.entries.toList(growable: false);

    Widget fallback() => RealtimeInsetGroup(
      children: entries
          .map(
            (entry) => Semantics(
              selected: entry.key == groupValue,
              child: ListTile(
                title: entry.value,
                trailing: entry.key == groupValue
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => onValueChanged(entry.key),
              ),
            ),
          )
          .toList(growable: false),
    );
    if (scale.scale(17) >= 28) {
      return fallback();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (entries.isEmpty) return const SizedBox.shrink();
        // Two short options fit comfortably below 260px, while three or
        // more labelled options need more width. A fixed breakpoint made
        // simple controls unnecessarily turn into tall list menus.
        final minimumItemWidth = entries.length <= 2 ? 88.0 : 112.0;
        final minimumTrackWidth =
            entries.length * minimumItemWidth + resolvedPadding.horizontal;
        if (constraints.maxWidth < minimumTrackWidth) return fallback();
        final selectedIndex = entries.indexWhere(
          (entry) => entry.key == groupValue,
        );
        // Preserve Cupertino's horizontal slide-to-select gesture in addition
        // to direct taps and keyboard/semantics activation on each segment.
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: (details) {
            final contentWidth =
                constraints.maxWidth - resolvedPadding.horizontal;
            if (contentWidth <= 0) return;
            final x = details.localPosition.dx - resolvedPadding.left;
            final index = (x / (contentWidth / entries.length)).floor().clamp(
              0,
              entries.length - 1,
            );
            final value = entries[index].key;
            if (value != groupValue) onValueChanged(value);
          },
          child: Container(
            height: height,
            padding: resolvedPadding,
            decoration: BoxDecoration(
              color: backgroundColor ?? style.surfaceSubtle,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: LayoutBuilder(
              builder: (context, trackConstraints) {
                final itemWidth = trackConstraints.maxWidth / entries.length;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    if (selectedIndex >= 0)
                      AnimatedPositioned(
                        duration: RealtimeUiThemeExtension.of(
                          context,
                        ).duration(context, RealtimeUiTokens.animNormal),
                        curve: Curves.easeOutCubic,
                        left: selectedIndex * itemWidth,
                        top: 0,
                        bottom: 0,
                        width: itemWidth,
                        child: DecoratedBox(
                          key: const ValueKey('realtime-segmented-thumb'),
                          decoration: BoxDecoration(
                            color: thumbColor ?? style.surface,
                            borderRadius: BorderRadius.circular(thumbRadius),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: .08),
                                blurRadius: 4,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: entries
                          .map((entry) {
                            final active = entry.key == groupValue;
                            return Expanded(
                              child: Semantics(
                                selected: active,
                                button: true,
                                child: RealtimeGlassPressable(
                                  borderRadius: thumbRadius,
                                  pressedScale: 1,
                                  onTap: () => onValueChanged(entry.key),
                                  child: Center(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                      child: DefaultTextStyle.merge(
                                        style: TextStyle(
                                          color: active
                                              ? style.text
                                              : style.textMuted,
                                          fontWeight: active
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                          fontSize: 13,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        child: entry.value,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          })
                          .toList(growable: false),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}
