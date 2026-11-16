import 'package:flutter_realtime_room_ui/flutter_realtime_room_ui.dart'
    show RealtimeRoomUiAction;
import 'package:flutter_realtime_shared_content_preset/flutter_realtime_shared_content_preset.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';
import 'room_control_components.dart';
import 'room_ui_controller.dart';
import 'realtime_dock_item.dart';
import 'realtime_dock_compact_menu.dart';
import 'realtime_desktop_screen_share_picker.dart';

class RealtimeDockSharedContentButton extends StatelessWidget {
  const RealtimeDockSharedContentButton({super.key, this.showLabel = true});
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final room = RealtimeRoomUiScope.of(context).room;
    final shared = room.sharedContent;
    final strings = RealtimeStrings.of(context);

    if (shared == null) {
      // Standalone screen share mode without shared content controller
      return RealtimeRoomActionButton(
        action: RealtimeRoomUiAction.screenShare,
        builder: (context, onPressed, active, pending) {
          return RealtimeDockItem(
            icon: active
                ? Icons.stop_screen_share_rounded
                : Icons.screen_share_rounded,
            label: active ? strings.stopSharing : strings.screenShare,
            isActive: active,
            isLoading: pending,
            onPressed: onPressed,
            showLabel: showLabel,
            activeColor: RealtimeStyle.of(context).speakStrong,
          );
        },
      );
    }

    final controller = RealtimeRoomUiScope.of(context);
    Future<void> changeMode(SharedContentMode mode) async {
      try {
        if (mode == SharedContentMode.screen &&
            !await selectDesktopScreenShareSource(context, controller)) {
          return;
        }
        await shared.selectMode(mode);
      } catch (error) {
        // Unawaited Futures in a menu used to surface only in the browser
        // console. Route the failure to the shared room UI error handler.
        controller.reportActionError(error);
      }
    }

    return StreamBuilder<SharedContentStatus>(
      stream: shared.statuses,
      initialData: shared.status,
      builder: (context, snapshot) {
        final status = snapshot.data ?? shared.status;
        final mode = status.content?.mode ?? SharedContentMode.members;
        final isSharing = mode != SharedContentMode.members;

        final canManage = status.content?.canManage == true;
        final canShowMenu = canManage || status.content?.canShareScreen == true;
        return RealtimeDockCompactMenu(
          actions: [
            RealtimeCompactMenuAction(
              label: strings.whiteboard,
              icon: const Icon(Icons.draw_rounded),
              selected: mode == SharedContentMode.whiteboard,
              enabled: status.content?.whiteboard.canEdit == true,
              onSelected: () =>
                  unawaited(changeMode(SharedContentMode.whiteboard)),
            ),
            RealtimeCompactMenuAction(
              label: shared.anotherParticipantSharing
                  ? (strings.isZh
                      ? '其他成员正在共享'
                      : 'Another participant is sharing')
                  : strings.screenShare,
              icon: const Icon(Icons.screen_share_outlined),
              selected: mode == SharedContentMode.screen,
              enabled:
                  status.content?.canShareScreen == true &&
                  shared.canShare &&
                  !shared.anotherParticipantSharing,
              onSelected: () => unawaited(changeMode(SharedContentMode.screen)),
            ),
            if (isSharing && canManage)
              RealtimeCompactMenuAction(
                label: strings.stopSharing,
                icon: const Icon(Icons.stop_screen_share_rounded),
                destructive: true,
                dividerBefore: true,
                onSelected: () =>
                    unawaited(changeMode(SharedContentMode.members)),
              ),
          ],
          triggerBuilder: (toggle) => RealtimeDockItem(
            icon: isSharing
                ? (mode == SharedContentMode.whiteboard
                      ? Icons.draw_rounded
                      : Icons.screen_share_rounded)
                : Icons.present_to_all_rounded,
            label: isSharing
                ? (mode == SharedContentMode.whiteboard
                      ? strings.whiteboard
                      : strings.stopSharing)
                : strings.shareContent,
            isActive: isSharing,
            isLoading: status.busy,
            onPressed: canShowMenu ? toggle : null,
            showLabel: showLabel,
            activeColor: RealtimeStyle.of(context).speakStrong,
          ),
        );
      },
    );
  }
}

/// Dock raise-hand button aligned with [RealtimeDockItem] geometry and badges.
