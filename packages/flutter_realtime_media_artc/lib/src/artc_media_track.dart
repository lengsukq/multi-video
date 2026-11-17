import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

/// Renderable ARTC camera track, identified by its provider user id.
class ArtcMediaVideoTrack extends MediaVideoTrack {
  const ArtcMediaVideoTrack({
    required this.userId,
    required this.local,
    this.screenShare = false,
    this.generation = 0,
    this.processedSource,
  });

  final String userId;
  final bool local;
  final bool screenShare;
  final int generation;
  final ProcessedVideoSource? processedSource;

  @override
  String get id =>
      'artc:$userId:${screenShare ? 'screen' : 'camera'}:$generation';

  @override
  String get participantId => userId;

  @override
  bool get isLocal => local;

  @override
  bool get isScreenShare => screenShare;

  @override
  int get width => processedSource?.width ?? 0;

  @override
  int get height => processedSource?.height ?? 0;
}
