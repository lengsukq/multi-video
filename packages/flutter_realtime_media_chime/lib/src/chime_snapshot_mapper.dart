part of 'chime_media_session.dart';

class _ChimeSnapshotMapper {
  _ChimeSnapshotMapper(this._session);
  final ChimeMediaSession _session;
  String get providerId => _session.providerId;
  MediaCapabilities get capabilities => _session.capabilities;
  MediaRole get role => _session.role;
  MediaSessionState get state => _session.state;
  MediaSnapshot get snapshot => _session.snapshot;
  Duration get cleanupTimeout => _session.cleanupTimeout;

  final Set<String> _speakingParticipantIds = <String>{};
  void _onProviderSnapshot(
    chime.MeetingSnapshot providerSnapshot, {
    bool clearLastError = false,
  }) {
    if (_session._disposed ||
        (_session._joinCancelled &&
            providerSnapshot.state != chime.MeetingState.ended &&
            providerSnapshot.state != chime.MeetingState.disposed)) {
      return;
    }
    final previous = _session._snapshot;
    final next = _mapSnapshot(providerSnapshot, clearLastError: clearLastError);
    _session._replaceSnapshot(next);
    _emitSnapshotDiff(previous, next);
  }

  MediaSnapshot _mapSnapshot(
    chime.MeetingSnapshot providerSnapshot, {
    required bool clearLastError,
  }) {
    final participants = providerSnapshot.attendees
        .map(
          (attendee) => MediaParticipant(
            id: attendee.attendeeId,
            displayName: attendee.externalUserId.isEmpty
                ? attendee.attendeeId
                : attendee.externalUserId,
            isLocal: attendee.isLocal,
            isMuted: attendee.isMuted,
            isVideoEnabled: attendee.isVideoEnabled,
            isSpeaking: _speakingParticipantIds.contains(attendee.attendeeId),
            videoTrack: attendee.videoTile == null
                ? null
                : ChimeMediaVideoTrack(attendee.videoTile!),
            joinedAt: attendee.joinedAt,
          ),
        )
        .toList(growable: false);
    final messages = providerSnapshot.messages
        .map(
          (message) => MediaMessage(
            participantId: message.attendeeId,
            displayName: message.externalUserId,
            message: message.message,
            topic: message.topic,
            timestampMs: message.timestampMs,
            providerId: providerId,
          ),
        )
        .toList(growable: false);
    return MediaSnapshot(
      state: _mapState(providerSnapshot.state),
      role: role,
      participants: participants,
      messages: messages,
      localParticipantId: providerSnapshot.localAttendeeId,
      localMuted: providerSnapshot.localMuted,
      localVideoEnabled: providerSnapshot.localVideoEnabled,
      localScreenShareEnabled:
          _session._controls._iosScreenCaptureSource != null,
      contentShareTrack: providerSnapshot.contentShareTile == null
          ? null
          : ChimeMediaVideoTrack(providerSnapshot.contentShareTile!),
      capabilities: capabilities,
      lastError: clearLastError ? null : _session._snapshot.lastError,
    );
  }

  void _emitSnapshotDiff(MediaSnapshot previous, MediaSnapshot next) {
    if (previous.state != next.state) {
      if (!_session._stateController.isClosed) {
        _session._stateController.add(next.state);
      }
      _session._emit(
        MediaConnectionStateChanged(
          previous: previous.state,
          current: next.state,
        ),
      );
    }

    final oldParticipants = {
      for (final item in previous.participants) item.id: item,
    };
    final newParticipants = {
      for (final item in next.participants) item.id: item,
    };
    for (final participant in next.participants) {
      final old = oldParticipants[participant.id];
      if (old == null && !participant.isLocal) {
        _session._emit(MediaParticipantJoined(participant));
      }
      final oldTrack = old?.videoTrack;
      final newTrack = participant.videoTrack;
      if (oldTrack == null && newTrack != null) {
        _session._emit(MediaTrackPublished(newTrack));
      } else if (oldTrack != null && newTrack == null) {
        _session._emit(
          MediaTrackUnpublished(
            trackId: oldTrack.id,
            participantId: participant.id,
          ),
        );
      } else if (oldTrack != null &&
          newTrack != null &&
          oldTrack.id != newTrack.id) {
        _session._emit(
          MediaTrackUnpublished(
            trackId: oldTrack.id,
            participantId: participant.id,
          ),
        );
        _session._emit(MediaTrackPublished(newTrack));
      }
      if (old != null && old.isMuted != participant.isMuted) {
        _session._emit(
          MediaTrackMutedChanged(
            participantId: participant.id,
            muted: participant.isMuted,
            kind: MediaTrackKind.audio,
          ),
        );
      }
    }
    for (final participant in previous.participants) {
      if (!participant.isLocal &&
          !newParticipants.containsKey(participant.id)) {
        _session._emit(
          MediaParticipantLeft(
            participantId: participant.id,
            displayName: participant.displayName,
          ),
        );
      }
    }

    if (previous.localMuted != next.localMuted ||
        previous.localVideoEnabled != next.localVideoEnabled) {
      _session._emit(
        MediaLocalMediaChanged(
          muted: previous.localMuted == next.localMuted
              ? null
              : next.localMuted,
          videoEnabled: previous.localVideoEnabled == next.localVideoEnabled
              ? null
              : next.localVideoEnabled,
        ),
      );
    }

    if (next.messages.length > previous.messages.length) {
      for (final message in next.messages.skip(previous.messages.length)) {
        _session._emit(MediaMessageReceived(message));
      }
    }

    final oldContent = previous.contentShareTrack;
    final newContent = next.contentShareTrack;
    if (oldContent == null && newContent != null) {
      _session._emit(MediaTrackPublished(newContent));
    } else if (oldContent != null && newContent == null) {
      _session._emit(
        MediaTrackUnpublished(
          trackId: oldContent.id,
          participantId: oldContent.participantId,
          wasScreenShare: true,
        ),
      );
    }
  }

  void _onProviderEvent(chime.ChimeEvent event) {
    if (_session._disposed) return;
    if (event is chime.AttendeeVolumeEvent) {
      final speaking = switch (event.volumeLevel) {
        chime.MeetingVolumeLevel.low ||
        chime.MeetingVolumeLevel.medium ||
        chime.MeetingVolumeLevel.high => true,
        chime.MeetingVolumeLevel.muted ||
        chime.MeetingVolumeLevel.notSpeaking => false,
        chime.MeetingVolumeLevel.unknown => _speakingParticipantIds.contains(
          event.attendeeId,
        ),
      };
      final wasSpeaking = _speakingParticipantIds.contains(event.attendeeId);
      if (speaking) {
        _speakingParticipantIds.add(event.attendeeId);
      } else {
        _speakingParticipantIds.remove(event.attendeeId);
      }
      if (speaking != wasSpeaking) {
        _onProviderSnapshot(_session._session.snapshot);
        _session._emit(
          MediaSpeakingChanged(
            participantId: event.attendeeId,
            isSpeaking: speaking,
          ),
        );
      }
      return;
    }

    if (event is chime.VideoTileEvent &&
        (event.kind == chime.VideoTileEventKind.paused ||
            event.kind == chime.VideoTileEventKind.resumed)) {
      final tile = event.videoTile;
      _session._emit(
        MediaTrackMutedChanged(
          participantId: tile.attendeeId,
          trackId: ChimeMediaVideoTrack(tile).id,
          muted: event.kind == chime.VideoTileEventKind.paused,
          kind: tile.isContentShare
              ? MediaTrackKind.screenShare
              : MediaTrackKind.video,
        ),
      );
    }
  }
}
