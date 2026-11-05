import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';

/// Shared visual vocabulary for the classroom sidebar. These widgets do not
/// store lesson state; all content must come from SDK snapshots.
class ClassroomSidebarCard extends StatelessWidget {
  const ClassroomSidebarCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(13),
    this.emphasized = false,
    this.onTap,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool emphasized;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    final radius = BorderRadius.circular(14);
    final decoration = BoxDecoration(
      color: emphasized
          ? style.accentSoft.withValues(alpha: .45)
          : style.surfaceSubtle,
      borderRadius: radius,
      border: Border.all(
        color: emphasized ? style.primaryBorder : style.border,
      ),
    );
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: decoration,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class ClassroomSidebarSectionTitle extends StatelessWidget {
  const ClassroomSidebarSectionTitle({
    super.key,
    required this.title,
    this.icon,
    this.trailing,
  });

  final String title;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: style.textSecondary),
          const SizedBox(width: 7),
        ],
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              letterSpacing: .08,
              color: style.text,
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class ClassroomSidebarStatus extends StatelessWidget {
  const ClassroomSidebarStatus({
    super.key,
    required this.label,
    this.color,
    this.icon,
  });
  final String label;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    final foreground = color ?? style.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: foreground),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ClassroomSidebarMetric extends StatelessWidget {
  const ClassroomSidebarMetric({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.onTap,
  });
  final String label;
  final String value;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    return ClassroomSidebarCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(11, 10, 11, 11),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: style.textSecondary),
              const Spacer(),
              if (onTap != null)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 15,
                  color: style.textMuted,
                ),
            ],
          ),
          // Do not rely on a fixed-height card: scaled numbers and labels
          // must be allowed to determine the minimum intrinsic height.
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: style.text,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: style.textMuted),
          ),
        ],
      ),
    );
  }
}
