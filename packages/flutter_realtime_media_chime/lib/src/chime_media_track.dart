import 'package:flutter_aws_chime/flutter_aws_chime.dart' as chime;
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

/// Core video-track handle backed by an existing Chime native video tile.
class ChimeMediaVideoTrack extends MediaVideoTrack
    implements MediaContentOwnerTrack {
  const ChimeMediaVideoTrack(this.tile, {this.processedSource});

  final chime.MeetingVideoTile tile;
  final ProcessedVideoSource? processedSource;

  @override
  String get id => 'chime-tile-${tile.tileId}';

  @override
  String get participantId => tile.attendeeId;

  @override
  String get contentOwnerParticipantId =>
      tile.isContentShare && tile.attendeeId.endsWith('#content')
      ? tile.attendeeId.substring(0, tile.attendeeId.length - '#content'.length)
      : tile.attendeeId;

  @override
  bool get isLocal => tile.isLocal;

  @override
  bool get isScreenShare => tile.isContentShare;

  @override
  int get width => tile.width > 0 ? tile.width : (processedSource?.width ?? 0);

  @override
  int get height =>
      tile.height > 0 ? tile.height : (processedSource?.height ?? 0);
}
