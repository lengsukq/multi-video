import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_live_preset/flutter_realtime_live_preset.dart';
import 'package:flutter_realtime_room_ui/flutter_realtime_room_ui.dart'
    show RealtimeConnectionIndicator;

import 'realtime_dock_microphone_button.dart';
import 'realtime_dock_camera_button.dart';
import 'realtime_live_gift_banner.dart';
import 'realtime_live_gift_button.dart';
import 'realtime_live_hearts_overlay.dart';
import 'realtime_live_like_button.dart';
import 'realtime_live_video_stage.dart';
import 'realtime_meeting_dock.dart';
import 'realtime_meeting_rail.dart';
import 'realtime_meeting_sidebar.dart';
import 'realtime_meeting_timer_badge.dart';
import 'realtime_meeting_top_bar.dart';
import 'realtime_recording_badge.dart';
import 'realtime_room_shell.dart';
import 'room_chat_components.dart';
import 'room_ui_controller.dart';

/// Responsive live workspace built on exactly the same room frame as Meeting.
/// Provider and role capabilities still control every live-only action.
class RealtimeLiveDesktopStage extends StatelessWidget {
  const RealtimeLiveDesktopStage({
    super.key,
    this.showChat = true,
    this.showLiveInteractions = true,
    this.videoFit,
    this.onExit,
    this.exitAction,
    this.onToggleCleanScreen,
    this.onToggleVideoFit,
    this.customChatPanel,
    this.customGiftPanel,
    this.topTrailingActions,
    this.onViewAudience,
    this.onOpenChat,
    this.onOpenHostTools,
    this.onOpenDisplayOptions,
    this.liveDuration,
    this.startedAt,
    this.initialTab = 0,
    this.onSelectedTab,
  });

  final bool showChat;
  final bool showLiveInteractions;
  final BoxFit? videoFit;
  final VoidCallback? onExit;
  final Widget? exitAction;
  final VoidCallback? onToggleCleanScreen;
  final VoidCallback? onToggleVideoFit;
  final Widget? customChatPanel;
  final Widget? customGiftPanel;
  final List<Widget>? topTrailingActions;
  final VoidCallback? onViewAudience;
  final VoidCallback? onOpenChat;
  final VoidCallback? onOpenHostTools;

  /// Backward-compatible hook for callers still providing a single display
  /// settings action. Prefer the individual rail actions instead.
  @Deprecated('Use onToggleVideoFit, onToggleCleanScreen and onOpenHostTools')
  final VoidCallback? onOpenDisplayOptions;
  final Duration? liveDuration;
  final DateTime? startedAt;
  final int initialTab;
  final ValueChanged<int>? onSelectedTab;

  @override
  Widget build(BuildContext context) {
    final controller = RealtimeRoomUiScope.of(context);
    final room = controller.room;
    final style = RealtimeStyle.of(context);
    final strings = RealtimeStrings.of(context);
    final isHost = room.media.role == MediaRole.host;
    final participants = controller.snapshot.participants;
    final host = isHost
        ? controller.snapshot.localParticipant
        : controller.snapshot.remoteParticipants.firstOrNull;
    final members = participants
        .map(
          (p) => RealtimeMeetingMemberItem(
            id: p.id,
            name: p.displayName.isEmpty ? p.id : p.displayName,
            avatarUrl: p.avatarUrl,
            roleTitle: p.isLocal ? (strings.isZh ? '我' : 'You') : null,
            isMuted: p.isMuted,
            isVideoOff: !p.isVideoEnabled,
            isSpeaking: p.isSpeaking,
          ),
        )
        .toList(growable: false);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final wide = RealtimeBreakpoints.isWide(context, width);
        final compact = width < RealtimeBreakpoints.compactMaxWidth;
        final liveEnabled =
            showLiveInteractions && room.liveInteractions != null;
        final hasChat = showChat && room.chat != null;

        final actions = <RealtimeMeetingRailItem>[
          if (hasChat)
            RealtimeMeetingRailItem(
              icon: Icons.chat_bubble_outline_rounded,
              tooltip: strings.chat,
              active: initialTab == 0,
              onPressed: wide ? () => onSelectedTab?.call(0) : onOpenChat,
            ),
          RealtimeMeetingRailItem(
            icon: Icons.people_outline_rounded,
            tooltip: strings.participants,
            active: initialTab == 1,
            badgeCount: participants.length,
            onPressed: wide ? () => onSelectedTab?.call(1) : onViewAudience,
          ),
          if (onToggleVideoFit != null ||
              onToggleCleanScreen != null ||
              (isHost && onOpenHostTools != null))
            const RealtimeMeetingRailItem.divider(),
          if (onToggleVideoFit != null)
            RealtimeMeetingRailItem(
              icon: videoFit == BoxFit.contain
                  ? Icons.crop_free_rounded
                  : Icons.fit_screen_rounded,
              tooltip: videoFit == BoxFit.contain
                  ? strings.fillLiveScreen
                  : strings.showFullVideo,
              onPressed: onToggleVideoFit,
            ),
          if (onToggleCleanScreen != null)
            RealtimeMeetingRailItem(
              icon: Icons.fullscreen_rounded,
              tooltip: strings.isZh ? '清屏' : 'Hide controls',
              onPressed: onToggleCleanScreen,
            ),
          if (isHost && onOpenHostTools != null)
            RealtimeMeetingRailItem(
              icon: Icons.tune_rounded,
              tooltip: strings.isZh ? '主播工具' : 'Host tools',
              onPressed: onOpenHostTools,
            ),
          if (onToggleVideoFit == null &&
              onToggleCleanScreen == null &&
              onOpenHostTools == null &&
              onOpenDisplayOptions != null)
            RealtimeMeetingRailItem(
              icon: Icons.tune_rounded,
              tooltip: strings.isZh ? '显示设置' : 'Display settings',
              onPressed: onOpenDisplayOptions,
            ),
        ];

        final header = RealtimeMeetingTopBar(
          title: room.media.roomCode,
          subtitle: host?.displayName.isNotEmpty == true
              ? host!.displayName
              : strings.liveRoom,
          compact: !wide,
          statusWidgets: [
            RealtimeStatusPill(
              label: strings.liveStatus,
              tone: RealtimeStatusTone.live,
              showDot: true,
              blink: true,
            ),
            if (startedAt != null)
              RealtimeMeetingTimerBadge(startedAt: startedAt!, live: true)
            else if (liveDuration != null)
              RealtimeStatusPill(
                label: _formatDuration(liveDuration!),
                tone: RealtimeStatusTone.live,
              ),
            RealtimeRecordingBadge(room: room, compact: true),
            if (wide) const RealtimeConnectionIndicator(),
          ],
          audienceNames: wide
              ? participants
                    .map((p) => p.displayName.isEmpty ? p.id : p.displayName)
                    .toList(growable: false)
              : const [],
          audienceCount: wide ? participants.length : null,
          trailingActions: [
            if (wide && onViewAudience != null)
              IconButton.outlined(
                tooltip: strings.participants,
                onPressed: onViewAudience,
                icon: const Icon(Icons.people_outline_rounded, size: 19),
              ),
            ...?topTrailingActions,
            if (exitAction != null)
              exitAction!
            else if (onExit != null)
              IconButton.filled(
                tooltip: strings.leave,
                onPressed: onExit,
                icon: const Icon(Icons.call_end_rounded),
              ),
          ],
        );

        final stage = Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 8 : 12,
            8,
            compact ? 8 : 12,
            8,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(RealtimeUiTokens.stageRadius),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: style.tile,
                border: Border.all(color: style.border),
                borderRadius: BorderRadius.circular(
                  RealtimeUiTokens.stageRadius,
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onDoubleTap: !liveEnabled
                        ? null
                        : () {
                            for (var i = 0; i < 2; i++) {
                              unawaited(
                                controller.sendLiveLike().catchError(
                                  controller.reportActionError,
                                ),
                              );
                            }
                          },
                    child: RealtimeLiveVideoStage(fit: videoFit),
                  ),
                  if (liveEnabled) ...[
                    const Positioned(
                      right: 16,
                      bottom: 12,
                      width: 120,
                      height: 210,
                      child: IgnorePointer(child: RealtimeLiveHeartsOverlay()),
                    ),
                    if (!compact)
                      const Positioned(
                        left: 16,
                        right: 140,
                        bottom: 16,
                        child: IgnorePointer(child: RealtimeLiveGiftBanner()),
                      ),
                  ],
                ],
              ),
            ),
          ),
        );

        final dock = Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 8 : 12,
            0,
            compact ? 8 : 12,
            compact ? 8 : 10,
          ),
          child: RealtimeMeetingDock(
            showLabels: false,
            mediaGroup: [
              if (isHost && controller.canUseMicrophone)
                const RealtimeDockMicrophoneButton(showLabel: false),
              if (isHost && controller.canUseCamera)
                const RealtimeDockCameraButton(showLabel: false),
            ],
            collaborationGroup: [
              if (liveEnabled && !wide) ...[
                if (customGiftPanel != null)
                  customGiftPanel!
                else
                  const RealtimeLiveGiftButton(),
                const RealtimeLiveLikeButton(iconOnly: true),
              ],
            ],
          ),
        );

        return RealtimeRoomShell(
          compact: compact,
          header: header,
          tabletRail: !wide
              ? RealtimeMeetingRail(horizontal: true, items: actions)
              : null,
          desktopRail: wide ? RealtimeMeetingRail(items: actions) : null,
          stage: stage,
          dock: dock,
          sidebar: wide
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    color: style.surface,
                    border: Border(left: BorderSide(color: style.border)),
                  ),
                  child: RealtimeMeetingSidebar(
                    members: members,
                    showChat: hasChat,
                    initialTab: hasChat ? initialTab : 1,
                    onTabChanged: onSelectedTab,
                    chatWidget:
                        customChatPanel ??
                        Column(
                          children: [
                            Expanded(
                              child: hasChat
                                  ? const RealtimeChatPanel(timelineStyle: true)
                                  : const SizedBox.shrink(),
                            ),
                            if (liveEnabled)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  6,
                                  12,
                                  10,
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    if (customGiftPanel != null)
                                      customGiftPanel!
                                    else
                                      const RealtimeLiveGiftButton(),
                                    const SizedBox(width: 8),
                                    const RealtimeLiveLikeButton(),
                                  ],
                                ),
                              ),
                          ],
                        ),
                    membersWidget: const RealtimeManagedParticipantList(),
                  ),
                )
              : null,
        );
      },
    );
  }

  String _formatDuration(Duration duration) {
    final h = duration.inHours;
    final m = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
