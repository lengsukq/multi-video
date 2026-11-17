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
        final activeCohostIds = {
          for (final member in controller.liveState?.activeCohosts ?? const [])
            ...{member.userId, member.participantId},
        };
        final cohosts = members
            .where((p) {
              if (p.id == host.id) return false;
              if (p.isLocal) {
                return controller.room.media.role == MediaRole.participant;
              }
              return p.isVideoEnabled ||
                  p.videoTrack != null ||
                  activeCohostIds.contains(p.id);
            })
            .toList(growable: false);
        final mainTile = RealtimeVideoTile(
          key: ValueKey(host.id),
          participant: host,
          showNameTag: showNameTag || cohosts.isNotEmpty,
          borderless: true,
          fit: fit ?? BoxFit.contain,
        );
        if (cohosts.isEmpty) return mainTile;
        return LayoutBuilder(
          builder: (context, viewport) {
            final compact = viewport.maxWidth < 480;
            final pipWidth = compact ? 92.0 : 136.0;
            final pipHeight = compact ? 124.0 : 92.0;
            return Stack(
              fit: StackFit.expand,
              children: [
                mainTile,
                Positioned(
                  top: compact ? 76 : 14,
                  right: 12,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final cohost in cohosts.take(4)) ...[
                        Container(
                          width: pipWidth,
                          height: pipHeight,
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(
                              RealtimeUiTokens.compactRadius,
                            ),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.28),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.35),
                                blurRadius: 8,
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: RealtimeVideoTile(
                            key: ValueKey('cohost-${cohost.id}'),
                            participant: cohost,
                            showNameTag: true,
                            borderless: true,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// A short floating chat feed for live broadcasts. No room layout is imposed.
/// The same chat messages are available separately in RealtimeChatPanel.
