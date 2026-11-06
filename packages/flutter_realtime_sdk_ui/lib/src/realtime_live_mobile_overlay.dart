import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_live_preset/flutter_realtime_live_preset.dart';

import 'realtime_audience_avatar_row.dart';
import 'realtime_live_chat_feed.dart';
import 'realtime_live_gift_button.dart';
import 'realtime_live_hearts_overlay.dart';
import 'realtime_live_like_button.dart';
import 'realtime_live_gift_banner.dart';
import 'realtime_role_presentation.dart';
import 'realtime_live_media_controls.dart';
import 'realtime_meeting_dock.dart';
import 'realtime_dock_compact_menu.dart';
import 'room_ui_controller.dart';
import 'room_chat_components.dart';

/// Full-screen mobile immersive HUD overlay for Live broadcast (matching Image 1 mobile).
///
/// Features:
/// - Top HUD: Host info capsule, Audience avatars, and Close button.
/// - Floating chat barrage on bottom-left.
/// - Floating hearts animation on bottom-right.
/// - Bottom interactive controls: Chat input pill, Gift button, Heart like button, and extra tools.
class RealtimeLiveMobileOverlay extends StatelessWidget {
  const RealtimeLiveMobileOverlay({
    super.key,
    this.showChat = true,
    this.showLiveInteractions = true,
    this.onExit,
    this.exitAction,
    this.onViewAudience,
    this.onOpenHostTools,
    this.onOpenBackgroundEffects,
    this.onOpenGiftSheet,
    this.extraBottomActions,
    this.extraTopActions = const [],
    this.videoFit,
    this.onToggleVideoFit,
    this.onToggleCleanScreen,
    this.maxChatMessages = 5,
  });

  final VoidCallback? onExit;
  final Widget? exitAction;
  final VoidCallback? onViewAudience;
  final VoidCallback? onOpenHostTools;

  /// Optional shortcut in the mobile More menu. Shown for publishers only.
  final VoidCallback? onOpenBackgroundEffects;
  final VoidCallback? onOpenGiftSheet;
  final List<Widget>? extraBottomActions;
  final List<Widget> extraTopActions;
  final int maxChatMessages;
  final bool showChat;
  final bool showLiveInteractions;
  final BoxFit? videoFit;
  final VoidCallback? onToggleVideoFit;
  final VoidCallback? onToggleCleanScreen;

  @override
  Widget build(BuildContext context) {
    final controller = RealtimeRoomUiScope.of(context);
    final isHost = RealtimePresentationRole.forLive(
      controller.room.media.role,
    ).canShowLiveHostTools;
    return LayoutBuilder(
      builder: (context, viewport) {
        final narrowHud = viewport.maxWidth < 300;
        final lowHeightHud = viewport.maxHeight < 420;
        final largeText = RealtimeBreakpoints.textScaleIsLarge(context);
        final compactHud = viewport.maxWidth < 390 || lowHeightHud || largeText;
        final availableChatHeight =
            viewport.maxHeight -
            MediaQuery.paddingOf(context).vertical -
            (compactHud ? 196 : 244);
        final chatHeight = availableChatHeight.clamp(
          0.0,
          compactHud ? 104.0 : 180.0,
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            // 1. Top Scrim Gradient
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 140,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.black.withValues(alpha: 0.65),
                        Colors.transparent,
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
              ),
            ),

            // 2. Bottom Scrim Gradient
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 220,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.75),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
              ),
            ),

            // A single compact header; display actions live in the More menu.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: narrowHud ? 8 : 14,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      if (viewport.maxWidth >= 220)
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: _MobileHostCapsule(
                              room: controller.room,
                              avatarOnly: narrowHud,
                            ),
                          ),
                        ),
                      if (viewport.maxWidth < 220) const Spacer(),
                      const SizedBox(width: 8),
                      RealtimeGlassSurface(
                        radius: RealtimeUiTokens.pillRadius,
                        fillColor: RealtimeUiTokens.canvasDarkElevated,
                        opacity: .64,
                        borderColor: Colors.white.withValues(alpha: .22),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!narrowHud)
                              Tooltip(
                                message: RealtimeStrings.of(
                                  context,
                                ).participants,
                                child: RealtimeAudienceAvatarRow(
                                  onViewAll: onViewAudience,
                                  onVideo: true,
                                  avatarSize: 24,
                                  maxAvatars: compactHud ? 0 : 1,
                                ),
                              ),
                            if (onOpenBackgroundEffects != null ||
                                onOpenHostTools != null ||
                                onToggleVideoFit != null ||
                                onToggleCleanScreen != null ||
                                (narrowHud && onViewAudience != null) ||
                                extraTopActions.isNotEmpty)
                              _buildDisplayOptionsMenu(
                                context,
                                narrowHud: narrowHud,
                              ),
                          ],
                        ),
                      ),
                      if (exitAction != null || onExit != null) ...[
                        const SizedBox(width: 8),
                        exitAction ??
                            IconButton.filled(
                              tooltip: RealtimeStrings.of(context).leave,
                              style: IconButton.styleFrom(
                                backgroundColor: RealtimeUiTokens.live,
                                foregroundColor: Colors.white,
                                minimumSize: const Size(44, 44),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    RealtimeUiTokens.controlRadius,
                                  ),
                                ),
                              ),
                              onPressed: onExit,
                              icon: const Icon(
                                Icons.call_end_rounded,
                                size: 19,
                              ),
                            ),
                      ],
                    ],
                  ),
                ),
              ),
            ),

            // 4. Floating Hearts Animation Overlay
            if (!lowHeightHud &&
                showLiveInteractions &&
                controller.room.liveInteractions != null)
              const Positioned(
                right: 16,
                bottom: 80,
                width: 120,
                height: 260,
                child: IgnorePointer(child: RealtimeLiveHeartsOverlay()),
              ),

            if (showLiveInteractions &&
                controller.room.liveInteractions != null)
              Positioned(
                left: 12,
                right: 12,
                bottom: lowHeightHud ? 76 : (compactHud ? 178 : 214),
                child: const IgnorePointer(
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: RealtimeLiveGiftBanner(),
                  ),
                ),
              ),

            // 5. Floating Chat Feed & Bottom Action Bar
            Positioned(
              left: 12,
              right: 12,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Floating Chat Feed
                    if (showChat && chatHeight > 0 && !lowHeightHud)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth:
                              viewport.maxWidth * (compactHud ? 0.86 : 0.72),
                          maxHeight: chatHeight,
                        ),
                        child: RealtimeLiveChatFeed(
                          maxMessages: maxChatMessages,
                        ),
                      ),
                    SizedBox(height: compactHud ? 4 : 10),

                    if (isHost) ...[
                      RealtimeLiveMediaControls(
                        onOpenHostTools: compactHud ? null : onOpenHostTools,
                      ),
                      if (!compactHud) const SizedBox(height: 8),
                    ],

                    // Bottom Action Bar
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final actions = RealtimeDockScrollableStrip(
                            key: const ValueKey('live-mobile-actions-scroll'),
                            reverse: true,
                            dark: true,
                            children: [
                              if (showLiveInteractions &&
                                  onOpenGiftSheet != null) ...[
                                _CircleIconButton(
                                  icon: Icons.card_giftcard_rounded,
                                  color: RealtimeUiTokens.live,
                                  onPressed: onOpenGiftSheet!,
                                ),
                                const SizedBox(width: 8),
                              ] else if (showLiveInteractions &&
                                  controller.room.liveInteractions != null) ...[
                                const RealtimeLiveGiftButton(),
                                const SizedBox(width: 8),
                              ],
                              if (showLiveInteractions &&
                                  controller.room.liveInteractions != null)
                                RealtimeLiveLikeButton(iconOnly: compactHud),
                              ...?extraBottomActions,
                            ],
                          );
                          if (!showChat || controller.room.chat == null) {
                            return actions;
                          }
                          final chat = _MobileChatInputPill(
                            onTap: () =>
                                _openChatInputDialog(context, controller),
                          );
                          if (constraints.maxWidth < 280) {
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                chat,
                                const SizedBox(height: 8),
                                actions,
                              ],
                            );
                          }
                          return Row(
                            children: [
                              // Chat Input Trigger Pill
                              Expanded(child: chat),
                              const SizedBox(width: 8),
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: (constraints.maxWidth * 0.5).clamp(
                                    112.0,
                                    260.0,
                                  ),
                                ),
                                child: actions,
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDisplayOptionsMenu(
    BuildContext context, {
    required bool narrowHud,
  }) {
    final strings = RealtimeStrings.of(context);
    Widget button(VoidCallback toggle) => IconButton(
      tooltip: strings.isZh ? '显示选项' : 'Display options',
      style: IconButton.styleFrom(
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 48),
      ),
      onPressed: toggle,
      icon: const Icon(Icons.more_horiz_rounded, size: 22),
    );

    // Hosts embedding rich third-party widgets still need the full panel.
    // Default live actions are simple toggles and should not cover the video.
    if (extraTopActions.isNotEmpty) {
      return button(() => _openDisplayOptions(context));
    }
    return RealtimeDockCompactMenu(
      actions: [
        if (narrowHud && onViewAudience != null)
          RealtimeCompactMenuAction(
            icon: const Icon(Icons.people_outline_rounded),
            label: strings.participants,
            onSelected: onViewAudience!,
          ),
        if (onOpenHostTools != null)
          RealtimeCompactMenuAction(
            icon: const Icon(Icons.tune_rounded),
            label: strings.isZh ? '主播工具' : 'Host tools',
            onSelected: onOpenHostTools!,
          ),
        if (onOpenBackgroundEffects != null)
          RealtimeCompactMenuAction(
            icon: const Icon(Icons.blur_on_outlined),
            label: strings.virtualBackground,
            onSelected: onOpenBackgroundEffects!,
          ),
        if (onToggleVideoFit != null)
          RealtimeCompactMenuAction(
            icon: Icon(
              videoFit == BoxFit.contain
                  ? Icons.crop_free_rounded
                  : Icons.fit_screen_rounded,
            ),
            label: videoFit == BoxFit.contain
                ? strings.fillLiveScreen
                : strings.showFullVideo,
            onSelected: onToggleVideoFit!,
          ),
        if (onToggleCleanScreen != null)
          RealtimeCompactMenuAction(
            icon: const Icon(Icons.fullscreen_rounded),
            label: strings.isZh ? '清屏' : 'Hide controls',
            onSelected: onToggleCleanScreen!,
          ),
      ],
      triggerBuilder: button,
    );
  }

  void _openDisplayOptions(BuildContext context) {
    final strings = RealtimeStrings.of(context);
    final controller = RealtimeRoomUiScope.of(context);
    unawaited(
      showRealtimeGlassBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          top: false,
          child: RealtimeRoomUiScope(
            room: controller.room,
            controller: controller,
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      title: Text(
                        strings.isZh ? '显示选项' : 'Display options',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (onViewAudience != null)
                      ListTile(
                        leading: const Icon(Icons.people_outline_rounded),
                        title: Text(strings.participants),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          onViewAudience!();
                        },
                      ),
                    if (onOpenHostTools != null)
                      ListTile(
                        leading: const Icon(Icons.tune_rounded),
                        title: Text(strings.isZh ? '主播工具' : 'Host tools'),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          onOpenHostTools!();
                        },
                      ),
                    if (onOpenBackgroundEffects != null)
                      ListTile(
                        leading: const Icon(Icons.blur_on_outlined),
                        title: Text(strings.virtualBackground),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          onOpenBackgroundEffects!();
                        },
                      ),
                    if (onToggleVideoFit != null)
                      ListTile(
                        leading: Icon(
                          videoFit == BoxFit.contain
                              ? Icons.crop_free_rounded
                              : Icons.fit_screen_rounded,
                        ),
                        title: Text(
                          videoFit == BoxFit.contain
                              ? strings.fillLiveScreen
                              : strings.showFullVideo,
                        ),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          onToggleVideoFit!();
                        },
                      ),
                    if (onToggleCleanScreen != null)
                      ListTile(
                        leading: const Icon(Icons.fullscreen_rounded),
                        title: Text(strings.isZh ? '清屏' : 'Hide controls'),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          onToggleCleanScreen!();
                        },
                      ),
                    if (extraTopActions.isNotEmpty)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: extraTopActions,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openChatInputDialog(
    BuildContext context,
    RealtimeRoomUiController controller,
  ) {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (dialogContext) => _ChatInputSheet(controller: controller),
      ),
    );
  }
}

class _MobileHostCapsule extends StatelessWidget {
  const _MobileHostCapsule({required this.room, this.avatarOnly = false});

  final RealtimeRoom room;
  final bool avatarOnly;

  @override
  Widget build(BuildContext context) {
    final host =
        room.media.snapshot.participants
            .where((p) => p.isVideoEnabled)
            .firstOrNull ??
        (room.media.role == MediaRole.host
            ? room.media.snapshot.localParticipant
            : room.media.snapshot.remoteParticipants.firstOrNull);
    return Container(
      padding: avatarOnly
          ? const EdgeInsets.all(4)
          : const EdgeInsets.fromLTRB(4, 4, 10, 4),
      decoration: BoxDecoration(
        color: const Color(0xFF0C121C).withValues(alpha: 0.48),
        borderRadius: BorderRadius.circular(RealtimeUiTokens.radiusPill),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.15),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RealtimeAvatar(
            name: host?.displayName ?? room.media.roomCode,
            avatarUrl: host?.avatarUrl,
            size: 28,
          ),
          if (!avatarOnly) const SizedBox(width: 8),
          if (!avatarOnly)
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    room.media.roomCode,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  RealtimeStatusPill(
                    label: RealtimeStrings.of(context).liveStatus,
                    tone: RealtimeStatusTone.live,
                    showDot: true,
                    blink: true,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MobileChatInputPill extends StatelessWidget {
  const _MobileChatInputPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return RealtimeGlassPressable(
      onTap: onTap,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(RealtimeUiTokens.radiusPill),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.18),
            width: 0.8,
          ),
        ),
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 16,
              color: Colors.white.withValues(alpha: 0.70),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                RealtimeStrings.of(context).isZh ? '发送消息…' : 'Say something…',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({
    required this.icon,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.18),
          width: 0.8,
        ),
      ),
      child: IconButton(
        icon: Icon(icon, size: 20, color: color ?? Colors.white),
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      ),
    );
  }
}

class _ChatInputSheet extends StatelessWidget {
  const _ChatInputSheet({required this.controller});
  final RealtimeRoomUiController controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      top: false,
      child: RealtimeGlassSurface(
        radius: RealtimeUiTokens.sheetRadius,
        padding: const EdgeInsets.all(20),
        child: RealtimeRoomUiScope(
          room: controller.room,
          controller: controller,
          child: const RealtimeChatComposer(),
        ),
      ),
    ),
  );
}
