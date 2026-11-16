import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'realtime_room_ui_scope.dart';
import 'realtime_video_tile.dart';

class RealtimeVideoGrid extends StatelessWidget {
  const RealtimeVideoGrid({
    super.key,
    this.participants,
    this.crossAxisCount,
    this.spacing = 8,
    this.padding = const EdgeInsets.all(8),
    this.onParticipantTap,
    this.participantBuilder,
    this.videoFit = BoxFit.contain,
  });

  final Widget Function(BuildContext, MediaParticipant, MediaTrackRenderer)?
  participantBuilder;
  final List<MediaParticipant>? participants;
  final int? crossAxisCount;
  final double spacing;
  final EdgeInsetsGeometry padding;
  final ValueChanged<MediaParticipant>? onParticipantTap;
  final BoxFit videoFit;

  @override
  Widget build(BuildContext context) {
    final controller = RealtimeRoomUiScope.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final members = participants ?? controller.snapshot.participants;
        if (members.isEmpty) {
          return const Center(child: Icon(Icons.people_outline, size: 48));
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final columns =
                crossAxisCount ??
                math.min(
                  members.length,
                  math.max(1, (constraints.maxWidth / 290).ceil()),
                );
            final count = math.max(1, columns);
            final rows = (members.length / count).ceil();
            final insets = padding.resolve(Directionality.of(context));
            // Distribute short grids across the full viewport rather than
            // forcing 16:9 cells into the first row and leaving the remainder
            // empty. Keep a usable minimum height for crowded rooms; GridView
            // remains scrollable when all participants cannot fit at once.
            final availableHeight =
                constraints.maxHeight - insets.vertical - spacing * (rows - 1);
            final tileHeight = math.max(160.0, availableHeight / rows);
            return GridView.builder(
              padding: padding,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: count,
                crossAxisSpacing: spacing,
                mainAxisSpacing: spacing,
                mainAxisExtent: tileHeight,
              ),
              itemCount: members.length,
              itemBuilder: (context, index) {
                final member = members[index];
                if (participantBuilder != null) {
                  return participantBuilder!(
                    context,
                    member,
                    controller.room.renderer,
                  );
                }
                return RealtimeVideoTile(
                  key: ValueKey(member.id),
                  participant: member,
                  fit: videoFit,
                  onTap: onParticipantTap == null
                      ? null
                      : () => onParticipantTap!(member),
                );
              },
            );
          },
        );
      },
    );
  }
}
