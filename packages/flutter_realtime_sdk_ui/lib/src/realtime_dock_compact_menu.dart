import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';

/// One compact, anchored level of actions (not a screen-width bottom sheet).
/// For extended forms and rich settings, keep their dedicated dialogs.
class RealtimeCompactMenuAction {
  const RealtimeCompactMenuAction({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.subtitle,
    this.selected = false,
    this.enabled = true,
    this.destructive = false,
    this.dividerBefore = false,
  });

  final String label;
  final String? subtitle;
  final Widget icon;
  final VoidCallback onSelected;
  final bool selected;
  final bool enabled;
  final bool destructive;
  final bool dividerBefore;
}

class RealtimeDockCompactMenu extends StatelessWidget {
  const RealtimeDockCompactMenu({
    super.key,
    required this.actions,
    required this.triggerBuilder,
  });

  final List<RealtimeCompactMenuAction> actions;
  final Widget Function(VoidCallback toggle) triggerBuilder;

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    final theme = Theme.of(context);
    final error = theme.colorScheme.error;
    return MenuAnchor(
      // Dismissing the popover must not also trigger whiteboard drawing or
      // stage gestures underneath it.
      consumeOutsideTap: true,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(style.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 5),
        ),
        elevation: const WidgetStatePropertyAll(10),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            side: BorderSide(color: style.border),
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      menuChildren: [
        for (final action in actions) ...[
          if (action.dividerBefore)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Divider(height: 10, color: style.border),
            ),
          MenuItemButton(
            onPressed: action.enabled ? action.onSelected : null,
            child: SizedBox(
              width: 208,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconTheme(
                    data: IconThemeData(
                      size: 19,
                      color: (action.destructive ? error : style.textSecondary)
                          .withValues(alpha: action.enabled ? 1 : 0.42),
                    ),
                    child: action.icon,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          action.label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: action.selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: (action.destructive ? error : style.text)
                                .withValues(alpha: action.enabled ? 1 : 0.42),
                          ),
                        ),
                        if (action.subtitle != null)
                          Text(
                            action.subtitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: style.textMuted.withValues(
                                alpha: action.enabled ? 1 : 0.48,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (action.selected) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.check_rounded,
                      size: 17,
                      color: style.speakStrong,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
      builder: (context, controller, _) => triggerBuilder(() {
        if (controller.isOpen) {
          controller.close();
        } else {
          controller.open();
        }
      }),
    );
  }
}
