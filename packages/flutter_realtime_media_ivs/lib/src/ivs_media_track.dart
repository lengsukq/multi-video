import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

class IvsMediaVideoTrack extends MediaVideoTrack {
  const IvsMediaVideoTrack({
    required this.userId,
    required this.local,
    this.generation = 0,
    this.processedSource,
  });

  final String userId;
  final bool local;
  final int generation;
  final ProcessedVideoSource? processedSource;

  @override
  String get id => 'ivs:$userId:camera:$generation';
  @override
  String get participantId => userId;
  @override
  bool get isLocal => local;
  @override
  bool get isScreenShare => false;
  @override
  int get width => processedSource?.width ?? 0;
  @override
  int get height => processedSource?.height ?? 0;
}
