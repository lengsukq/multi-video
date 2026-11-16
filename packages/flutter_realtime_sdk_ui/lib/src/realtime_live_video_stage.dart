import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'room_ui_controller.dart';
import 'package:flutter_realtime_room_ui/flutter_realtime_room_ui.dart'
    show RealtimeVideoTile;

class RealtimeLiveVideoStage extends StatelessWidget {
  const RealtimeLiveVideoStage({
    super.key,
    this.placeholder,
    this.fit,
    this.showNameTag = false,
  });

  final Widget? placeholder;
  final BoxFit? fit;
  final bool showNameTag;

  @override
  Widget build(BuildContext context) {
    final controller = RealtimeRoomUiScope.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final snapshot = controller.snapshot;
        final members = snapshot.participants;
        final localHost = controller.room.media.role == MediaRole.host;
        final MediaParticipant? host = localHost
            ? (members.where((p) => p.isLocal).firstOrNull ??
                  members
                      .where((p) => p.id == snapshot.localParticipantId)
                      .firstOrNull ??
                  MediaParticipant(
                    id: controller.room.media.participantId,
                    displayName: controller.room.media.participantId,
                    isLocal: true,
                    isVideoEnabled: snapshot.localVideoEnabled,
                  ))
            : (members
                      .where(
                        (p) =>
                            !p.isLocal &&
                            (p.isVideoEnabled || p.videoTrack != null),
                      )
                      .firstOrNull ??
                  members.where((p) => !p.isLocal).firstOrNull);
        if (host == null) {
          return placeholder ??
              ColoredBox(
                color: RealtimeUiTokens.surfaceSubtle,
                child: Center(
                  child: Icon(
                    Icons.videocam_off_outlined,
                    size: 42,
                    color: RealtimeUiTokens.textMuted,
                  ),
                ),
              );
        }
        return RealtimeVideoTile(
          key: ValueKey(host.id),
          participant: host,
          showNameTag: showNameTag,
          borderless: true,
          fit: fit ?? BoxFit.contain,
        );
      },
    );
  }
}

/// A short floating chat feed for live broadcasts. No room layout is imposed.
/// The same chat messages are available separately in RealtimeChatPanel.
