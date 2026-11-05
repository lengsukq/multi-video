part of 'livekit_media_session.dart';

class _LiveKitSnapshotMapper {
  _LiveKitSnapshotMapper(this._session);
  final LiveKitMediaSessionBase _session;
  // Use the authoritative room event rather than relying on the timing of
  // individual Participant.isSpeaking updates on different native platforms.
  Set<String>? _activeSpeakerIds;
  String get providerId => _session.providerId;
  MediaCapabilities get capabilities => _session.capabilities;
  MediaRole get role => _session.role;
  MediaSessionState get state => _session.state;
  MediaSnapshot get snapshot => _session.snapshot;
  Duration get cleanupTimeout => _session.cleanupTimeout;

  // On iOS LiveKit's publication.muted is metadata updated by a track event.
  // The local track's muted value changes synchronously during setMuted().
  // Reading publication.muted in that same call can return the PREVIOUS value.
  bool _localMicrophoneMuted(lk.LocalParticipant? participant) {
    final publication = participant?.getTrackPublicationBySource(
      lk.TrackSource.microphone,
    );
    return publication?.track?.muted ?? publication?.muted ?? true;
  }

  void _refreshSnapshot({bool clearLastError = false}) {
    final room = _session._room;
    if (room == null) return;
    final participants = <MediaParticipant>[];
    final local = room.localParticipant;
    if (local != null) participants.add(_mapLocalParticipant(local));
    participants.addAll(
      room.remoteParticipants.values.map(_mapRemoteParticipant),
    );
    final screenShare = _findScreenShare(room);
    final localScreenShareEnabled =
        local?.getTrackPublicationBySource(lk.TrackSource.screenShareVideo) !=
        null;
    _session._replaceSnapshot(
      MediaSnapshot(
        state: _session._snapshot.state,
        role: role,
        participants: participants,
        messages: _session._snapshot.messages,
        localParticipantId:
            local?.identity ?? _session._joinInfo?.participantId,
        // Participant.isMuted reads the first audio publication, which can
        // be screen-share audio rather than the microphone. The room controls
        // specifically toggle TrackSource.microphone.
        localMuted: _localMicrophoneMuted(local),
        localVideoEnabled: local?.isCameraEnabled() ?? false,
        localScreenShareEnabled: localScreenShareEnabled,
        contentShareTrack: screenShare,
        capabilities: _session._capabilities,
        lastError: clearLastError ? null : _session._snapshot.lastError,
      ),
    );
  }

  MediaParticipant _mapLocalParticipant(lk.LocalParticipant participant) {
    final fallbackName = _session._joinInfo?.displayName ?? '';
    return MediaParticipant(
      id: participant.identity,
      displayName: participant.name.isNotEmpty
          ? participant.name
          : fallbackName.isNotEmpty
          ? fallbackName
          : participant.identity,
      isLocal: true,
      isMuted: _localMicrophoneMuted(participant),
      isVideoEnabled: participant.isCameraEnabled(),
      isSpeaking:
          _activeSpeakerIds?.contains(participant.identity) ??
          participant.isSpeaking,
      videoTrack: _cameraTrackLocal(participant),
      joinedAt: participant.joinedAt,
    );
  }

  MediaParticipant _mapRemoteParticipant(lk.RemoteParticipant participant) =>
      MediaParticipant(
        id: participant.identity,
        displayName: participant.name.isEmpty
            ? participant.identity
            : participant.name,
        isMuted: !participant.isMicrophoneEnabled(),
        isVideoEnabled: participant.isCameraEnabled(),
        isSpeaking:
            _activeSpeakerIds?.contains(participant.identity) ??
            participant.isSpeaking,
        videoTrack: _cameraTrackRemote(participant),
        joinedAt: participant.joinedAt,
      );

  LiveKitMediaVideoTrack? _cameraTrackLocal(lk.LocalParticipant participant) {
    final publication = participant.getTrackPublicationBySource(
      lk.TrackSource.camera,
    );
    final track = publication?.track;
    if (publication == null || publication.muted || track == null) return null;
    return _videoTrack(publication, track, participant.identity, isLocal: true);
  }

  LiveKitMediaVideoTrack? _cameraTrackRemote(lk.RemoteParticipant participant) {
    final publication = participant.getTrackPublicationBySource(
      lk.TrackSource.camera,
    );
    final track = publication?.track;
    if (publication == null || publication.muted || track == null) return null;
    return _videoTrack(
      publication,
      track,
      participant.identity,
      isLocal: false,
    );
  }

  LiveKitMediaVideoTrack? _findScreenShare(lk.Room room) {
    final local = room.localParticipant;
    if (local != null) {
      final publication = local.getTrackPublicationBySource(
        lk.TrackSource.screenShareVideo,
      );
      final track = publication?.track;
      if (publication != null && track != null) {
        final mapped = _videoTrack(
          publication,
          track,
          local.identity,
          isLocal: true,
        );
        if (mapped != null) return mapped;
      }
    }
    for (final participant in room.remoteParticipants.values) {
      final publication = participant.getTrackPublicationBySource(
        lk.TrackSource.screenShareVideo,
      );
      final track = publication?.track;
      if (publication != null && track != null) {
        final mapped = _videoTrack(
          publication,
          track,
          participant.identity,
          isLocal: false,
        );
        if (mapped != null) return mapped;
      }
    }
    return null;
  }

  LiveKitMediaVideoTrack? _videoTrack(
    lk.TrackPublication<lk.Track> publication,
    lk.Track track,
    String participantId, {
    required bool isLocal,
  }) {
    if (track is! lk.VideoTrack || publication.kind != lk.TrackType.VIDEO) {
      return null;
    }
    final dimensions = publication.dimensions;
    return LiveKitMediaVideoTrack(
      liveKitTrack: track,
      id: publication.sid,
      participantId: participantId,
      isLocal: isLocal,
      isScreenShare: publication.isScreenShare,
      width: dimensions?.width ?? 0,
      height: dimensions?.height ?? 0,
    );
  }
}
