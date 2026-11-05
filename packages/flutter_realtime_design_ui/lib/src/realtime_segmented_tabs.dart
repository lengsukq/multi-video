part of '../flutter_realtime_design_ui.dart';

class RealtimeSegmentedTabs<T> extends StatelessWidget {
  const RealtimeSegmentedTabs({
    super.key,
    required this.tabs,
    required this.selectedValue,
    required this.onChanged,
    this.height = 46,
    this._radius,
  });

  final List<RealtimeSegmentTab<T>> tabs;
  final T selectedValue;
  final ValueChanged<T> onChanged;
  final double height;
  final double? _radius;
  double get radius => _radius ?? RealtimeUiTokens.controlRadius;

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    final trackHeight =
        height + (MediaQuery.textScalerOf(context).scale(13) - 13).clamp(0, 40);
    final effectiveRadius = RealtimeUiTokens.segmentedOuterRadius(
      height: trackHeight,
      preferredRadius:
          _radius ?? RealtimeUiThemeExtension.of(context).controlRadius,
    );
    final thumbRadius = RealtimeUiTokens.segmentedThumbRadius(
      outerRadius: effectiveRadius,
      inset: 4,
    );
    return LayoutBuilder(
      builder: (context, outerConstraints) {
        // A two-tab sidebar easily fits at 300–360 px. The old 420 px
        // breakpoint incorrectly turned Chat / People into a vertical menu
        // beside the close button. Fall back to the accessible list only
        // when each tab would have too little horizontal touch space.
        final minimumTrackWidth = tabs.length * 88.0 + 8;
        if (outerConstraints.maxWidth < minimumTrackWidth ||
            MediaQuery.textScalerOf(context).scale(17) >= 28) {
          return RealtimeInsetGroup(
            children: tabs
                .map((tab) {
                  final active = tab.value == selectedValue;
                  return Semantics(
                    selected: active,
                    child: ListTile(
                      minVerticalPadding: 12,
                      leading: tab.icon == null ? null : Icon(tab.icon),
                      title: Text(tab.label),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (tab.badge != null && tab.badge! > 0)
                            RealtimeBadge(text: '${tab.badge}'),
                          if (active) ...[
                            const SizedBox(width: 8),
                            Icon(Icons.check_rounded, color: style.text),
                          ],
                        ],
                      ),
                      onTap: () => onChanged(tab.value),
                    ),
                  );
                })
                .toList(growable: false),
          );
        }
        return Container(
          constraints: BoxConstraints(minHeight: height),
          height: trackHeight,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: style.surfaceSubtle,
            borderRadius: BorderRadius.circular(effectiveRadius),
            border: Border.all(color: style.border),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final count = tabs.length;
              final tabWidth = (constraints.maxWidth) / count;
              final selectedIndex = tabs.indexWhere(
                (t) => t.value == selectedValue,
              );

              return Stack(
                children: [
                  if (selectedIndex >= 0)
                    AnimatedPositioned(
                      duration: RealtimeUiThemeExtension.of(
                        context,
                      ).duration(context, RealtimeUiTokens.animNormal),
                      curve: Curves.easeOutCubic,
                      left: selectedIndex * tabWidth,
                      top: 0,
                      bottom: 0,
                      width: tabWidth,
                      child: Container(
                        decoration: BoxDecoration(
                          color: style.accent,
                          borderRadius: BorderRadius.circular(thumbRadius),
                          border: Border.all(
                            color: style.primaryBorder,
                            width: 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: style.accent.withValues(alpha: 0.30),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: tabs.map((tab) {
                      final active = tab.value == selectedValue;
                      return Expanded(
                        child: RealtimeGlassPressable(
                          borderRadius: thumbRadius,
                          onTap: () {
                            unawaited(HapticFeedback.selectionClick());
                            onChanged(tab.value);
                          },
                          child: Container(
                            alignment: Alignment.center,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (tab.icon != null) ...[
                                  Icon(
                                    tab.icon,
                                    size: 16,
                                    color: active
                                        ? style.onAccent
                                        : style.textMuted,
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                Flexible(
                                  child: Text(
                                    tab.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: active
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      color: active
                                          ? style.onAccent
                                          : style.textMuted,
                                    ),
                                  ),
                                ),
                                if (tab.badge != null && tab.badge! > 0) ...[
                                  const SizedBox(width: 6),
                                  RealtimeBadge(
                                    text: '${tab.badge}',
                                    color: active
                                        ? style.onAccent
                                        : style.textSecondary,
                                    backgroundColor: active
                                        ? Colors.white.withValues(alpha: .55)
                                        : style.border,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
