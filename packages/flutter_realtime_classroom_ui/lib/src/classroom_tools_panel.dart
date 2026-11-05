import 'classroom_tool_kind.dart';
import 'classroom_publish_tool_dialog.dart';
import 'classroom_activity_card.dart';
import 'classroom_attendance_panel.dart';
import 'classroom_material_card.dart';
import 'classroom_homework_card.dart';
import 'classroom_notice_card.dart';
import 'classroom_timer_card.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_realtime_classroom_core/flutter_realtime_classroom_core.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';
import 'classroom_strings.dart';

/// Optional SDK UI for the tools extension. All actions delegate to the SDK.
class ClassroomToolsPanel extends StatefulWidget {
  const ClassroomToolsPanel({
    super.key,
    required this.classroom,
    this.showHeader = false,
    this.onClose,
    this.onActionError,
  });

  final ClassroomSession classroom;
  final bool showHeader;
  final VoidCallback? onClose;
  final ValueChanged<RealtimeException>? onActionError;

  @override
  State<ClassroomToolsPanel> createState() => _ClassroomToolsPanelState();
}

class _ClassroomToolsPanelState extends State<ClassroomToolsPanel> {
  bool _dialogOpen = false;
  RealtimeException? _error;
  StreamSubscription<Object>? _errors;

  @override
  void initState() {
    super.initState();
    _errors = widget.classroom.errors.listen((error) {
      _reportError(
        normalizeRealtimeException(error, domain: "classroom.ui.tools"),
      );
    });
  }

  @override
  void dispose() {
    observeDetached(_errors?.cancel());
    super.dispose();
  }

  void _reportError(RealtimeException error) {
    widget.onActionError?.call(error);
    if (mounted && !_dialogOpen) setState(() => _error = error);
  }

  Future<void> _publish(ClassroomToolKind kind) async {
    if (_dialogOpen) return;
    setState(() => _dialogOpen = true);
    final strings = ClassroomStrings.of(context);
    try {
      await showDialog<void>(
        context: context,
        useRootNavigator: true,
        builder: (ctx) => ClassroomPublishToolDialog(
          kind: kind,
          classroom: widget.classroom,
          strings: strings,
          onActionError: _reportError,
        ),
      );
    } finally {
      if (mounted) setState(() => _dialogOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<ClassroomState>(
    stream: widget.classroom.states,
    initialData: widget.classroom.state,
    builder: (context, snapshot) {
      final state = snapshot.data;
      final tools = state?.tools;
      if (state == null || tools == null) return const SizedBox.shrink();
      final s = ClassroomStrings.of(context);
      final style = RealtimeStyle.of(context);
      final timer = tools.timer;
      final isEmpty =
          tools.notices.isEmpty &&
          tools.homework.isEmpty &&
          tools.materials.isEmpty &&
          tools.activities.isEmpty &&
          timer == null;

      return Column(
        children: [
          if (widget.showHeader) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 12, 8),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: style.primarySubtle,
                      borderRadius: BorderRadius.circular(
                        RealtimeUiTokens.compactRadius,
                      ),
                      border: Border.all(color: style.primaryBorder),
                    ),
                    child: Icon(
                      Icons.widgets_outlined,
                      color: style.text,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    // Both labels must remain available at 200% text size.
                    // A single Row forced the role pill out of 320px sheets.
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          s.t('tools'),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: style.text,
                            letterSpacing: -0.2,
                          ),
                        ),
                        RealtimePill(
                          label: s.t(
                            state.isTeacher ? 'teacherRole' : 'studentRole',
                          ),
                          foreground: state.isTeacher
                              ? style.primary
                              : style.textMuted,
                          background: state.isTeacher
                              ? style.primarySubtle
                              : style.surfaceSubtle,
                          borderColor: state.isTeacher
                              ? style.primaryBorder
                              : style.border,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    color: style.textMuted,
                    splashRadius: 18,
                    onPressed:
                        widget.onClose ??
                        () => Navigator.maybeOf(context)?.pop(),
                  ),
                ],
              ),
            ),
            Divider(color: style.border, height: 1),
          ],
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                if (_error != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: style.dangerSubtle,
                      borderRadius: BorderRadius.circular(
                        RealtimeUiTokens.compactRadius,
                      ),
                      border: Border.all(
                        color: style.danger.withValues(alpha: 0.25),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline_rounded,
                          size: 18,
                          color: style.danger,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '$_error',
                            style: TextStyle(
                              color: style.danger,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (state.isTeacher) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        Icon(
                          Icons.auto_awesome_outlined,
                          size: 14,
                          color: style.textMuted,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            s.t('quickTools'),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: style.textMuted,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final item in <(ClassroomToolKind, IconData, Color)>[
                        (
                          ClassroomToolKind.announcement,
                          Icons.campaign_outlined,
                          RealtimeUiTokens.text,
                        ),
                        (
                          ClassroomToolKind.focus,
                          Icons.center_focus_strong,
                          RealtimeUiTokens.text,
                        ),
                        (
                          ClassroomToolKind.homework,
                          Icons.assignment_outlined,
                          RealtimeUiTokens.text,
                        ),
                        (
                          ClassroomToolKind.materials,
                          Icons.attach_file,
                          RealtimeUiTokens.text,
                        ),
                        (
                          ClassroomToolKind.timer,
                          Icons.timer_outlined,
                          RealtimeUiTokens.text,
                        ),
                        (
                          ClassroomToolKind.quiz,
                          Icons.quiz_outlined,
                          RealtimeUiTokens.text,
                        ),
                        (
                          ClassroomToolKind.poll,
                          Icons.poll_outlined,
                          RealtimeUiTokens.text,
                        ),
                      ])
                        _buildToolChip(item.$1, item.$2, item.$3, s, style),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
                if (timer != null)
                  ClassroomTimerCard(
                    key: ValueKey(timer.endsAt),
                    state: state,
                    timer: timer,
                    classroom: widget.classroom,
                    onActionError: _reportError,
                  ),
                for (final notice in tools.notices.reversed)
                  ClassroomNoticeCard(key: ValueKey(notice.id), notice: notice),
                for (final activity in tools.activities.reversed)
                  ClassroomActivityCard(
                    key: ValueKey(activity.id),
                    state: state,
                    activity: activity,
                    classroom: widget.classroom,
                    onActionError: _reportError,
                  ),
                for (final homework in tools.homework.reversed)
                  ClassroomHomeworkCard(
                    key: ValueKey(homework.id),
                    homework: homework,
                  ),
                if (tools.materials.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 8),
                    child: Text(
                      s.t('linkOnly'),
                      style: TextStyle(fontSize: 12, color: style.textMuted),
                    ),
                  ),
                ],
                for (final material in tools.materials.reversed)
                  ClassroomMaterialCard(
                    key: ValueKey(material.id),
                    material: material,
                    onActionError: _reportError,
                  ),
                if (isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: RealtimeEmptyState(
                      icon: Icons.widgets_outlined,
                      title: s.t('emptyTools'),
                      subtitle: s.t('emptyToolsDesc'),
                      iconColor: style.text,
                    ),
                  ),
                if (state.attendance.isNotEmpty)
                  ClassroomAttendancePanel(state: state),
              ],
            ),
          ),
        ],
      );
    },
  );

  Widget _buildToolChip(
    ClassroomToolKind kind,
    IconData icon,
    Color color,
    ClassroomStrings s,
    RealtimeStyle style,
  ) {
    return RealtimeGlassPressable(
      borderRadius: RealtimeUiTokens.pillRadius,
      onTap: _dialogOpen ? null : () => _publish(kind),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: style.surface,
          borderRadius: BorderRadius.circular(RealtimeUiTokens.pillRadius),
          border: Border.all(color: style.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 13, color: color),
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                s.t(kind.name),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: style.text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
