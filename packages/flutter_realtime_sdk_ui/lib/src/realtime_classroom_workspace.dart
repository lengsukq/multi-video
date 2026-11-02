import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';

import 'room_classroom_activities.dart';
import 'room_classroom_interactions.dart';
import 'room_ui_controller.dart';
import 'classroom_sidebar_visuals.dart';

/// A classroom-focused view of existing, authoritative SDK state.
/// There is no duplicated meeting state, synthetic poll or mock transcript.
enum RealtimeClassroomSection { overview, hands, questions, activities }

class RealtimeClassroomWorkspace extends StatefulWidget {
  const RealtimeClassroomWorkspace({
    super.key,
    this.initialSection = RealtimeClassroomSection.overview,
  });

  final RealtimeClassroomSection initialSection;

  @override
  State<RealtimeClassroomWorkspace> createState() =>
      _RealtimeClassroomWorkspaceState();
}

class _RealtimeClassroomWorkspaceState
    extends State<RealtimeClassroomWorkspace> {
  late RealtimeClassroomSection _selected = widget.initialSection;

  @override
  void didUpdateWidget(covariant RealtimeClassroomWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSection != oldWidget.initialSection) {
      _selected = widget.initialSection;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = RealtimeRoomUiScope.of(context);
    final strings = RealtimeStrings.of(context);
    final style = RealtimeStyle.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final classroom = controller.classroomState;
        if (classroom == null) {
          return Center(
            child: Text(
              strings.isZh ? '课堂服务尚未连接' : 'Classroom service unavailable',
              style: TextStyle(color: style.textMuted),
            ),
          );
        }
        final isTeacher = classroom.isTeacher;
        final available = <RealtimeClassroomSection>[
          RealtimeClassroomSection.overview,
          if (isTeacher) RealtimeClassroomSection.hands,
          RealtimeClassroomSection.questions,
          if (classroom.tools != null) RealtimeClassroomSection.activities,
        ];
        final selected = available.contains(_selected)
            ? _selected
            : RealtimeClassroomSection.overview;
        String label(RealtimeClassroomSection id) => switch (id) {
          RealtimeClassroomSection.overview => strings.isZh ? '概览' : 'Overview',
          RealtimeClassroomSection.hands => strings.classroomHands,
          RealtimeClassroomSection.questions => strings.isZh ? '问答' : 'Q&A',
          RealtimeClassroomSection.activities => strings.classroomActivities,
        };
        int badge(RealtimeClassroomSection id) => switch (id) {
          RealtimeClassroomSection.hands => classroom.raisedHands.length,
          RealtimeClassroomSection.questions =>
            classroom.stats.pendingQuestions,
          _ => 0,
        };
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
              child: Row(
                children: [
                  if (selected == RealtimeClassroomSection.overview)
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: style.accentSoft,
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Icon(
                        Icons.school_outlined,
                        color: style.text,
                        size: 20,
                      ),
                    )
                  else
                    TextButton.icon(
                      key: const ValueKey('classroom-back-to-overview'),
                      onPressed: () => setState(
                        () => _selected = RealtimeClassroomSection.overview,
                      ),
                      icon: const Icon(Icons.arrow_back_rounded, size: 18),
                      label: Text(strings.isZh ? '返回' : 'Back'),
                      style: TextButton.styleFrom(
                        foregroundColor: style.textSecondary,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 40),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          selected == RealtimeClassroomSection.overview
                              ? (strings.isZh ? '课堂工作台' : 'Classroom workspace')
                              : label(selected),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: style.text,
                          ),
                        ),
                        Text(
                          selected == RealtimeClassroomSection.overview
                              ? (isTeacher
                                    ? (strings.isZh ? '教师管理' : 'Teacher tools')
                                    : (strings.isZh ? '我的课堂' : 'My classroom'))
                              : (strings.isZh
                                    ? '课堂工作台'
                                    : 'Classroom workspace'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: style.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (classroom.stats.onlineCount > 0)
                    ClassroomSidebarStatus(
                      label: '${classroom.stats.onlineCount}',
                      color: RealtimeUiTokens.speakStrong,
                      icon: Icons.circle,
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final tab in available)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: OutlinedButton(
                          key: ValueKey('classroom-section-${tab.name}'),
                          onPressed: () => setState(() => _selected = tab),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            minimumSize: const Size(0, 36),
                            visualDensity: VisualDensity.compact,
                            backgroundColor: selected == tab
                                ? style.primarySubtle
                                : style.surface,
                            foregroundColor: selected == tab
                                ? style.text
                                : style.textSecondary,
                            side: BorderSide(
                              color: selected == tab
                                  ? style.primaryBorder
                                  : style.border,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(11),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                label(tab),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: selected == tab
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                              if (badge(tab) > 0) ...[
                                const SizedBox(width: 5),
                                Text(
                                  '${badge(tab)}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: style.border),
            Expanded(
              child: switch (selected) {
                RealtimeClassroomSection.overview => _ClassroomOverview(
                  onNavigate: (section) => setState(() => _selected = section),
                ),
                RealtimeClassroomSection.hands =>
                  const RealtimeClassroomHandQueue(),
                RealtimeClassroomSection.questions => Column(
                  children: [
                    const Expanded(child: RealtimeClassroomQuestions()),
                    if (controller.canAskQuestion)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(10, 4, 10, 10),
                        child: RealtimeClassroomQuestionComposer(),
                      ),
                  ],
                ),
                RealtimeClassroomSection.activities =>
                  const RealtimeClassroomActivityList(),
              },
            ),
          ],
        );
      },
    );
  }
}

class _ClassroomOverview extends StatelessWidget {
  const _ClassroomOverview({required this.onNavigate});
  final ValueChanged<RealtimeClassroomSection> onNavigate;

  @override
  Widget build(BuildContext context) {
    final controller = RealtimeRoomUiScope.of(context);
    final strings = RealtimeStrings.of(context);
    final style = RealtimeStyle.of(context);
    final classroom = controller.classroomState;
    if (classroom == null) return const SizedBox.shrink();

    final stats = classroom.stats;
    final isTeacher = classroom.isTeacher;
    final activities = classroom.tools?.activities ?? const [];
    final active = activities.where((a) => !a.closed).length;
    final cards =
        <
          ({
            String name,
            String count,
            IconData icon,
            RealtimeClassroomSection? target,
          })
        >[
          (
            name: strings.isZh ? '在线学生' : 'Online',
            count: '${stats.onlineCount}',
            icon: Icons.people_outline,
            target: null,
          ),
          if (isTeacher)
            (
              name: strings.isZh ? '举手申请' : 'Hands',
              count: '${classroom.raisedHands.length}',
              icon: Icons.pan_tool_alt_outlined,
              target: RealtimeClassroomSection.hands,
            ),
          (
            name: strings.isZh ? '待回答' : 'Questions',
            count: '${stats.pendingQuestions}',
            icon: Icons.question_answer_outlined,
            target: RealtimeClassroomSection.questions,
          ),
          if (classroom.tools != null)
            (
              name: strings.isZh ? '进行中活动' : 'Activities',
              count: '$active',
              icon: Icons.poll_outlined,
              target: RealtimeClassroomSection.activities,
            ),
        ];
    return ListView(
      key: const ValueKey('classroom-overview'),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 20),
      children: [
        Text(
          strings.isZh ? '课堂实时概况' : 'Live classroom overview',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: style.text,
          ),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 260 ? 2 : 1;
            final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final card in cards)
                  SizedBox(
                    width: width,
                    height: 100,
                    child: ClassroomSidebarMetric(
                      label: card.name,
                      value: card.count,
                      icon: card.icon,
                      onTap: card.target == null
                          ? null
                          : () => onNavigate(card.target!),
                    ),
                  ),
              ],
            );
          },
        ),
        if (activities.where((a) => !a.closed).isNotEmpty) ...[
          const SizedBox(height: 20),
          ClassroomSidebarSectionTitle(
            title: strings.isZh ? '进行中的课堂活动' : 'Current activity',
            icon: Icons.poll_outlined,
            trailing: TextButton(
              onPressed: () => onNavigate(RealtimeClassroomSection.activities),
              child: Text(strings.isZh ? '查看' : 'View'),
            ),
          ),
          const SizedBox(height: 8),
          Builder(
            builder: (context) {
              final activity = activities.firstWhere((a) => !a.closed);
              final counts = activity.counts;
              final total =
                  counts?.fold<int>(0, (sum, count) => sum + count) ?? 0;
              return ClassroomSidebarCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClassroomSidebarStatus(
                      label: activity.kind.name == 'quiz'
                          ? (strings.isZh ? '随堂测验' : 'Quiz')
                          : (strings.isZh ? '互动投票' : 'Poll'),
                      color: RealtimeUiTokens.speakStrong,
                      icon: Icons.circle,
                    ),
                    const SizedBox(height: 9),
                    Text(
                      activity.title,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: style.text,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      strings.activityResponses(activity.responseCount),
                      style: TextStyle(fontSize: 11.5, color: style.textMuted),
                    ),
                    if (counts != null && total > 0) ...[
                      const SizedBox(height: 10),
                      for (
                        var i = 0;
                        i < activity.options.length && i < counts.length;
                        i++
                      ) ...[
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                activity.options[i],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: style.textSecondary,
                                ),
                              ),
                            ),
                            Text(
                              '${(counts[i] * 100 / total).round()}%',
                              style: TextStyle(
                                fontSize: 11,
                                color: style.textMuted,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: counts[i] / total,
                            minHeight: 5,
                            backgroundColor: style.border,
                            valueColor: AlwaysStoppedAnimation(
                              style.textSecondary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ],
                ),
              );
            },
          ),
        ],
        const SizedBox(height: 16),
        if (isTeacher) ...[
          _JumpRow(
            title: strings.isZh ? '处理举手申请' : 'Manage hand requests',
            detail: strings.isZh
                ? '批准发言或收回权限'
                : 'Grant or revoke speaking permission',
            icon: Icons.pan_tool_alt_outlined,
            onTap: () => onNavigate(RealtimeClassroomSection.hands),
          ),
          const SizedBox(height: 8),
        ] else ...[
          if (controller.canRaiseHand) const RealtimeRaiseHandButton(),
          const SizedBox(height: 8),
        ],
        _JumpRow(
          title: strings.isZh ? '课堂问答' : 'Classroom questions',
          detail: strings.isZh ? '查看与回复问题' : 'Review and answer questions',
          icon: Icons.forum_outlined,
          onTap: () => onNavigate(RealtimeClassroomSection.questions),
        ),
        if (classroom.tools != null) ...[
          const SizedBox(height: 8),
          _JumpRow(
            title: strings.isZh ? '投票与测验' : 'Polls and quizzes',
            detail: strings.isZh ? '查看真实答题结果' : 'Review live responses',
            icon: Icons.poll_outlined,
            onTap: () => onNavigate(RealtimeClassroomSection.activities),
          ),
        ],
      ],
    );
  }
}

class _JumpRow extends StatelessWidget {
  const _JumpRow({
    required this.title,
    required this.detail,
    required this.icon,
    required this.onTap,
  });
  final String title, detail;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    return ClassroomSidebarCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: style.accentSoft.withValues(alpha: .6),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 18, color: style.text),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: style.text,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.3,
                    color: style.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 5),
          Icon(Icons.chevron_right_rounded, size: 20, color: style.textMuted),
        ],
      ),
    );
  }
}
