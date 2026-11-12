import 'realtime_room_action_button_builder.dart';
import 'package:flutter_realtime_room_ui/flutter_realtime_room_ui.dart'
    show RealtimeRoomUiAction;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_realtime_live_preset/flutter_realtime_live_preset.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';
import 'room_ui_controller.dart';
import 'realtime_background_effects_button.dart';
import 'realtime_desktop_screen_share_picker.dart';

class RealtimeRoomActionButton extends StatelessWidget {
  const RealtimeRoomActionButton({
    super.key,
    required this.action,
    this.builder,
    this.label,
    this.iconOnly = false,
  });

  final RealtimeRoomUiAction action;
  final RealtimeRoomActionButtonBuilder? builder;
  final String? label;
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final controller = RealtimeRoomUiScope.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final snapshot = controller.snapshot;
        final isZh = RealtimeStrings.of(context).isZh;
        final active = switch (action) {
          RealtimeRoomUiAction.microphone => !snapshot.localMuted,
          RealtimeRoomUiAction.camera => snapshot.localVideoEnabled,
          RealtimeRoomUiAction.screenShare => snapshot.localScreenShareEnabled,
          RealtimeRoomUiAction.backgroundEffect =>
            controller.room.backgroundEffect.enabled,
          _ => false,
        };
        final supported = switch (action) {
          RealtimeRoomUiAction.microphone => controller.canUseMicrophone,
          RealtimeRoomUiAction.camera => controller.canUseCamera,
          RealtimeRoomUiAction.screenShare => controller.canShareScreen,
          RealtimeRoomUiAction.switchCamera => controller.canSwitchCamera,
          RealtimeRoomUiAction.audioOutput => false,
          RealtimeRoomUiAction.device => false,
          RealtimeRoomUiAction.leave => true,
          RealtimeRoomUiAction.sendMessage => controller.room.chat != null,
          RealtimeRoomUiAction.participantManagement => false,
          RealtimeRoomUiAction.classroom => false,
          RealtimeRoomUiAction.backgroundEffect =>
            snapshot.capabilities.canPublishVideo,
          RealtimeRoomUiAction.liveLike =>
            controller.room.liveInteractions != null,
        };
        final pending = controller.isPending(action);
        final buttonLabel =
            label ??
            switch (action) {
              RealtimeRoomUiAction.microphone => isZh ? '麦克风' : 'Microphone',
              RealtimeRoomUiAction.camera => isZh ? '摄像头' : 'Camera',
              RealtimeRoomUiAction.screenShare =>
                isZh ? '共享屏幕' : 'Share screen',
              RealtimeRoomUiAction.switchCamera =>
                isZh ? '切换摄像头' : 'Switch camera',
              RealtimeRoomUiAction.audioOutput =>
                isZh ? '音频输出' : 'Audio output',
              RealtimeRoomUiAction.device => isZh ? '设备' : 'Devices',
              RealtimeRoomUiAction.leave => isZh ? '离开会议' : 'Leave meeting',
              RealtimeRoomUiAction.sendMessage => isZh ? '发送' : 'Send',
              RealtimeRoomUiAction.participantManagement =>
                isZh ? '成员管理' : 'Manage members',
              RealtimeRoomUiAction.classroom => isZh ? '课堂' : 'Classroom',
              RealtimeRoomUiAction.backgroundEffect =>
                isZh ? '虚拟背景' : 'Background effects',
              RealtimeRoomUiAction.liveLike => isZh ? '点赞' : 'Like',
            };
        final icon = switch (action) {
          RealtimeRoomUiAction.microphone => active ? Icons.mic : Icons.mic_off,
          RealtimeRoomUiAction.camera =>
            active ? Icons.videocam : Icons.videocam_off,
          RealtimeRoomUiAction.screenShare =>
            active ? Icons.stop_screen_share : Icons.screen_share,
          RealtimeRoomUiAction.switchCamera => Icons.cameraswitch,
          RealtimeRoomUiAction.audioOutput => Icons.speaker_outlined,
          RealtimeRoomUiAction.device => Icons.devices_outlined,
          RealtimeRoomUiAction.leave => Icons.call_end,
          RealtimeRoomUiAction.sendMessage => Icons.send,
          RealtimeRoomUiAction.participantManagement =>
            Icons.manage_accounts_outlined,
          RealtimeRoomUiAction.classroom => Icons.school_outlined,
          RealtimeRoomUiAction.backgroundEffect => Icons.blur_on_outlined,
          RealtimeRoomUiAction.liveLike => Icons.favorite_rounded,
        };
        void invoke() {
          Future<void> task() => switch (action) {
            RealtimeRoomUiAction.microphone => controller.toggleMicrophone(),
            RealtimeRoomUiAction.camera => controller.toggleCamera(),
            RealtimeRoomUiAction.screenShare =>
              toggleScreenShareWithPicker(context, controller),
            RealtimeRoomUiAction.switchCamera => controller.switchCamera(),
            RealtimeRoomUiAction.audioOutput => Future.value(),
            RealtimeRoomUiAction.device => Future.value(),
            RealtimeRoomUiAction.leave => controller.leave(),
            RealtimeRoomUiAction.sendMessage => Future.value(),
            RealtimeRoomUiAction.participantManagement => Future.value(),
            RealtimeRoomUiAction.classroom => Future.value(),
            RealtimeRoomUiAction.backgroundEffect =>
              showRealtimeBackgroundEffectsSheet(context),
            RealtimeRoomUiAction.liveLike => controller.sendLiveLike(),
          };
          unawaited(
            task().catchError(
              (Object error) => controller.reportActionError(error),
            ),
          );
        }

        final callback = supported && !pending ? invoke : null;
        if (builder != null) {
          return builder!(context, callback, active, pending);
        }
        if (iconOnly) {
          final isDanger =
              (action == RealtimeRoomUiAction.microphone && !active) ||
              (action == RealtimeRoomUiAction.camera && !active) ||
              action == RealtimeRoomUiAction.leave;
          return Tooltip(
            message: buttonLabel,
            child: IconButton.filledTonal(
              style: isDanger
                  ? IconButton.styleFrom(
                      backgroundColor: Colors.red.withValues(alpha: 0.18),
                      foregroundColor: Colors.redAccent,
                    )
                  : (active
                        ? IconButton.styleFrom(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primaryContainer,
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.onPrimaryContainer,
                          )
                        : null),
              onPressed: callback,
              icon: pending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(icon),
            ),
          );
        }
        return Tooltip(
          message: buttonLabel,
          child: FilledButton.tonalIcon(
            onPressed: callback,
            icon: pending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(icon),
            label: Text(buttonLabel),
          ),
        );
      },
    );
  }
}

/// One standalone device picker for microphone/camera/output. Providers that
/// cannot enumerate devices show no control; selection remains read-only when
/// an adapter can enumerate but cannot change the selected device.
