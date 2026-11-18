import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

class IvsMediaVideoTrack extends MediaVideoTrack
    implements MediaContentOwnerTrack {
  const IvsMediaVideoTrack({
    required this.userId,
    required this.local,
    this.generation = 0,
    this.processedSource,
    this.isScreenShare = false,
    this.explicitContentOwnerId,
  });

  final String userId;
  final bool local;
  final int generation;
  final ProcessedVideoSource? processedSource;
  @override
  final bool isScreenShare;
  final String? explicitContentOwnerId;

  @override
  String get id => isScreenShare
      ? 'ivs:$userId:screen:$generation'
      : 'ivs:$userId:camera:$generation';
  @override
  String get participantId => userId;
  @override
  String get contentOwnerParticipantId {
    final explicit = explicitContentOwnerId;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    return userId.endsWith('#content')
        ? userId.substring(0, userId.length - '#content'.length)
        : userId;
  }

  @override
  bool get isLocal => local;
  @override
  int get width => processedSource?.width ?? 0;
  @override
  int get height => processedSource?.height ?? 0;
}
