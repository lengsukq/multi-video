import 'package:flutter_realtime_shared_content_preset/flutter_realtime_shared_content_preset.dart';
import 'package:flutter_realtime_classroom_preset/flutter_realtime_classroom_preset.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_realtime_classroom_ui/flutter_realtime_classroom_ui.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_whiteboard_ui/flutter_realtime_whiteboard_ui.dart';

import 'room_ui_controller.dart';
import 'realtime_desktop_screen_share_picker.dart';

/// Shared authoritative stage renderer used by both the composed layout and
/// the legacy complete-room template. The host owns all outer layout.
Widget? buildRoomSharedContentStage(
  RealtimeRoom room,
  MediaSnapshot snapshot, {
  Widget? members,
  bool withAnnotations = true,
  WhiteboardToolsController? whiteboardToolsController,
}) {
  final shared = room.sharedContent;
  final content = shared?.content;
  if (content == null || content.mode == SharedContentMode.members) {
    return members;
  }
  final candidate = snapshot.contentShareTrack;
  final track =
      candidate?.contentOwnerParticipantId == content.screen.participantId
      ? candidate
      : null;
  return SharedContentStage(
    mode: content.mode,
    whiteboard: shared!.whiteboard,
    whiteboardToolsController: whiteboardToolsController,
    members: members ?? const SizedBox.shrink(),
    screen: track == null
        ? null
        : MediaTrackView(
            renderer: room.renderer,
            track: track,
            fit: BoxFit.contain,
          ),
    screenAspectRatio: track?.aspectRatio ?? 16 / 9,
    screenAnnotations: withAnnotations ? shared.screenAnnotations : null,
    canAnnotateScreen:
        withAnnotations && content.canManage && track?.isLocal == true,
    onStopSharing: content.canManage
        ? () => shared.selectMode(SharedContentMode.members)
        : null,
    screenSharerName: content.screen.participantId.isNotEmpty
        ? content.screen.participantId
        : null,
    // The room dock owns sharing controls; the stage keeps its full height.
    showHeader: false,
  );
}

/// Room content (participants, whiteboard or shared screen) without a Scaffold.
class RealtimeSharedContentStage extends StatelessWidget {
  const RealtimeSharedContentStage({
    super.key,
    required this.members,
    this.withAnnotations = true,
  });

  final bool withAnnotations;

  final Widget members;

  @override
  Widget build(BuildContext context) {
    final room = RealtimeRoomUiScope.of(context).room;
    final shared = room.sharedContent;
    if (shared == null) return members;
    return StreamBuilder<SharedContentStatus>(
      stream: shared.statuses,
      initialData: shared.status,
      builder: (context, _) =>
          buildRoomSharedContentStage(
            room,
            room.media.session.snapshot,
            members: members,
            withAnnotations: withAnnotations,
          ) ??
          members,
    );
  }
}

/// One reusable classroom entry widget, suitable for any toolbar position.
class RealtimeClassroomButton extends StatelessWidget {
  const RealtimeClassroomButton({super.key, this.showLabel = false});
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final classroom = RealtimeRoomUiScope.of(context).room.classroom;
    return classroom == null
        ? const SizedBox.shrink()
        : ClassroomControlButton(
            key: ObjectKey(classroom),
            classroom: classroom,
            showLabel: showLabel,
          );
  }
}

/// Independently positionable selector for members, whiteboard and screen.
class RealtimeSharedContentButton extends StatelessWidget {
  const RealtimeSharedContentButton({super.key});

  @override
  Widget build(BuildContext context) {
    final roomController = RealtimeRoomUiScope.of(context);
    final shared = roomController.room.sharedContent;
    if (shared == null) return const SizedBox.shrink();
    return StreamBuilder<SharedContentStatus>(
      stream: shared.statuses,
      initialData: shared.status,
      builder: (context, snapshot) {
        final status = snapshot.data ?? shared.status;
        if (status.content?.canManage != true &&
            status.content?.canShareScreen != true) {
          return const SizedBox.shrink();
        }
        final zh = RealtimeStrings.of(context).isZh;
        Future<void> run(Future<void> Function() action) async {
          try {
            await action();
          } catch (error) {
            if (context.mounted) {
              RealtimeRoomUiScope.of(context).reportActionError(error);
            }
          }
        }

        return PopupMenuButton<String>(
          tooltip: zh ? '共享内容' : 'Shared content',
          enabled: !status.busy,
          icon: const Icon(Icons.present_to_all_rounded),
          onSelected: (value) {
            if (value == 'system') {
              unawaited(
                run(() async {
                  await Future<void>.delayed(Duration.zero);
                  if (!context.mounted) return;
                  if (shared.systemAnnotations.active) {
                    await shared.stopSystemAnnotations();
                    return;
                  }
                  final approved = await showDialog<bool>(
                    context: context,
                    useRootNavigator: true,
                    builder: (dialogContext) => RealtimeGlassDialog(
                      title: Text(zh ? '跨应用标注' : 'Draw across apps'),
                      content: Text(
                        zh
                            ? '共享整个主屏幕后，悬浮标注才能正确显示给其他参会者。'
                            : 'Share your entire primary display so annotations align for viewers.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(false),
                          child: Text(zh ? '取消' : 'Cancel'),
                        ),
                        FilledButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(true),
                          child: Text(zh ? '继续' : 'Continue'),
                        ),
                      ],
                    ),
                  );
                  if (approved == true && context.mounted) {
                    await shared.startSystemAnnotations(
                      languageCode: zh ? 'zh' : 'en',
                    );
                  }
                }),
              );
            } else {
              unawaited(
                run(() async {
                  final mode = SharedContentMode.values.byName(value);
                  if (mode == SharedContentMode.screen &&
                      !await selectDesktopScreenShareSource(
                        context, roomController,
                      )) {
                    return;
                  }
                  await shared.selectMode(mode);
                }),
              );
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: SharedContentMode.members.name,
              enabled: status.content?.canManage == true,
              child: Text(zh ? '成员画面' : 'Participants'),
            ),
            PopupMenuItem(
              value: SharedContentMode.whiteboard.name,
              enabled: status.content?.whiteboard.canEdit == true,
              child: Text(zh ? '白板' : 'Whiteboard'),
            ),
            PopupMenuItem(
              value: SharedContentMode.screen.name,
              enabled:
                  shared.canShare && status.content?.canShareScreen == true,
              child: Text(zh ? '屏幕共享' : 'Share screen'),
            ),
            PopupMenuItem(
              value: 'system',
              enabled:
                  status.captureActive &&
                  status.content?.canAnnotateScreen == true &&
                  status.content?.mode == SharedContentMode.screen,
              child: Text(
                shared.systemAnnotations.active
                    ? (zh ? '关闭跨应用标注' : 'Stop system annotations')
                    : (zh ? '跨应用标注' : 'System annotations'),
              ),
            ),
          ],
        );
      },
    );
  }
}
