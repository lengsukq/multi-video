import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_realtime_live_preset/flutter_realtime_live_preset.dart'
    show LiveCohostStatus;
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart'
    show MediaRole;
import 'package:flutter_realtime_room_ui/flutter_realtime_room_ui.dart'
    show RealtimeRoomUiAction;

import 'realtime_room_action_button.dart';
import 'room_ui_controller.dart';

/// Reachable broadcast controls that retain the shared action lifecycle.
class RealtimeLiveMediaControls extends StatelessWidget {
  const RealtimeLiveMediaControls({super.key, this.onOpenHostTools});

  final VoidCallback? onOpenHostTools;

  @override
  Widget build(BuildContext context) {
    final controller = RealtimeRoomUiScope.of(context);
    final strings = RealtimeStrings.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final isHost = controller.room.media.role == MediaRole.host;
        final canPublishMedia = controller.room.media.role != MediaRole.viewer;
        final canUseMicrophone = canPublishMedia && controller.canUseMicrophone;
        final canUseCamera = canPublishMedia && controller.canUseCamera;
        if (!canUseMicrophone &&
            !canUseCamera &&
            (!isHost || onOpenHostTools == null)) {
          return const SizedBox.shrink();
        }
        return RealtimeGlassSurface(
          radius: RealtimeUiTokens.pillRadius,
          fillColor: RealtimeUiTokens.canvasDarkElevated,
          opacity: .76,
          borderColor: Colors.white.withValues(alpha: .22),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (canUseMicrophone)
                _mediaAction(context, RealtimeRoomUiAction.microphone),
              if (canUseCamera)
                _mediaAction(context, RealtimeRoomUiAction.camera),
              if (isHost && onOpenHostTools != null) ...[
                if (canUseMicrophone || canUseCamera)
                  const SizedBox(
                    height: 22,
                    child: VerticalDivider(width: 16, color: Colors.white24),
                  ),
                IconButton(
                  tooltip: strings.isZh ? '主播工具' : 'Host tools',
                  style: IconButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: onOpenHostTools,
                  icon: const Icon(Icons.tune_rounded, size: 21),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _mediaAction(BuildContext context, RealtimeRoomUiAction action) {
    final isZh = RealtimeStrings.of(context).isZh;
    final microphone = action == RealtimeRoomUiAction.microphone;
    return RealtimeRoomActionButton(
      action: action,
      builder: (context, onPressed, active, pending) {
        final label = microphone
            ? (isZh
                  ? (active ? '关闭麦克风' : '打开麦克风')
                  : (active ? 'Turn off microphone' : 'Turn on microphone'))
            : (isZh
                  ? (active ? '关闭摄像头' : '打开摄像头')
                  : (active ? 'Turn off camera' : 'Turn on camera'));
        return Semantics(
          toggled: active,
          child: IconButton(
            tooltip: label,
            style: IconButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor: Colors.white,
              disabledForegroundColor: Colors.white38,
              backgroundColor: active
                  ? Colors.white.withValues(alpha: .16)
                  : null,
            ),
            onPressed: onPressed,
            icon: pending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(
                    microphone
                        ? (active ? Icons.mic_rounded : Icons.mic_off_rounded)
                        : (active
                              ? Icons.videocam_rounded
                              : Icons.videocam_off_rounded),
                    size: 22,
                  ),
          ),
        );
      },
    );
  }
}

/// Shared viewer action pill to request co-hosting, cancel request, or step down.
class RealtimeLiveCohostButton extends StatelessWidget {
  const RealtimeLiveCohostButton({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final controller = RealtimeRoomUiScope.of(context);
    final isZh = RealtimeStrings.of(context).isZh;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.canRequestCohost) {
          return const SizedBox.shrink();
        }
        final status = controller.selfCohostStatus;
        final pending = controller.isPending(RealtimeRoomUiAction.liveCohost);
        final (icon, label, active) = switch (status) {
          LiveCohostStatus.approved || LiveCohostStatus.active => (
            Icons.mic_off_rounded,
            isZh ? '下麦' : 'Leave mic',
            true,
          ),
          LiveCohostStatus.requested => (
            Icons.hourglass_top_rounded,
            isZh ? '取消申请' : 'Cancel',
            true,
          ),
          LiveCohostStatus.none || LiveCohostStatus.declined => (
            Icons.record_voice_over_outlined,
            isZh ? '申请连麦' : 'Request mic',
            false,
          ),
        };
        return Tooltip(
          message: label,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: active
                  ? RealtimeUiTokens.live
                  : Colors.white.withValues(alpha: 0.16),
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 10 : 12,
                vertical: 8,
              ),
              minimumSize: const Size(44, 40),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(RealtimeUiTokens.pillRadius),
              ),
            ),
            onPressed: pending
                ? null
                : () {
                    if (status == LiveCohostStatus.none ||
                        status == LiveCohostStatus.declined) {
                      unawaited(controller.requestCohost());
                    } else {
                      unawaited(controller.cancelCohost());
                    }
                  },
            icon: pending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(icon, size: 18),
            label: Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        );
      },
    );
  }
}
