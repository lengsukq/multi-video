part of 'ivs_media_session.dart';

class _IvsSnapshotMapper {
  _IvsSnapshotMapper(this._session);
  final _IvsMediaSession _session;
  String get providerId => _session.providerId;
  MediaCapabilities get capabilities => _session.capabilities;
  MediaRole get role => _session.role;
  MediaSessionState get state => _session.state;
  MediaSnapshot get snapshot => _session.snapshot;
  Duration get cleanupTimeout => _session.cleanupTimeout;

  int _trackGeneration = 0;

  void _adoptFrom(_IvsSnapshotMapper previous) {
    _trackGeneration = previous._trackGeneration;
  }

  IvsEngineEvents _createEngineEvents() {
    final generation = _session._connectionGeneration;
    final engine = _session._engine;
    bool currentLease() {
      final target = _session._eventTarget;
      final targetState = target._state;
      return generation == target._connectionGeneration &&
          identical(engine, target._engine) &&
          !target._disposed &&
          !targetState.isTerminal &&
          targetState != MediaSessionState.leaving;
    }

    return IvsEngineEvents(
      onError: (code, message) {
        if (currentLease()) _session._eventTarget._onNativeError(code, message);
      },
      onParticipantJoined: (id, name) {
        if (currentLease()) {
          _session._eventTarget._mapper._participantJoined(id, name);
        }
      },
      onParticipantLeft: (id) {
        if (currentLease()) _session._eventTarget._mapper._participantLeft(id);
      },
      onRemoteVideoChanged: (id, available) {
        if (currentLease()) {
          _session._eventTarget._mapper._remoteVideoChanged(id, available);
        }
      },
      onRemoteScreenShareChanged: (ownerUserId, trackUserId, available) {
        if (currentLease()) {
          _session._eventTarget._mapper._remoteScreenShareChanged(
            ownerUserId,
            trackUserId,
            available,
          );
        }
      },
      onRemoteAudioChanged: (id, available) {
        if (currentLease()) {
          _session._eventTarget._mapper._remoteAudioChanged(id, available);
        }
      },
      onReconnecting: () {
        if (!currentLease()) return;
        final target = _session._eventTarget;
        if (target._state == MediaSessionState.connected) {
          target._setState(MediaSessionState.reconnecting);
        }
      },
      onRecovered: () {
        if (!currentLease()) return;
        final target = _session._eventTarget;
        if (target._state == MediaSessionState.reconnecting) {
          target._setState(MediaSessionState.connected);
        }
      },
      onDisconnected: () {
        if (!currentLease()) return;
        final target = _session._eventTarget;
        target._setSnapshot(
          target._snapshot.copyWith(
            participants: const [],
            clearLocalParticipantId: true,
            localMuted: true,
            localVideoEnabled: false,
            localScreenShareEnabled: false,
            clearContentShareTrack: true,
          ),
        );
        target._setState(MediaSessionState.ended);
      },
      onStats: (values) {
        if (currentLease()) _session._eventTarget._statistics._onStats(values);
      },
    );
  }

  void _participantJoined(String userId, String displayName) {
    if (userId.isEmpty || userId == _session._joinInfo?.participantId) return;
    final current = _participantById(userId);
    if (current != null) {
      if (displayName.isNotEmpty && displayName != current.displayName) {
        _session._setSnapshot(
          _session._snapshot.copyWith(
            participants: _session._snapshot.participants
                .map(
                  (item) => item.id == userId
                      ? item.copyWith(displayName: displayName)
                      : item,
                )
                .toList(),
          ),
        );
      }
      return;
    }
    final participant = MediaParticipant(
      id: userId,
      displayName: displayName.isEmpty ? userId : displayName,
      joinedAt: DateTime.now(),
    );
    _session._setSnapshot(
      _session._snapshot.copyWith(
        participants: [..._session._snapshot.participants, participant],
      ),
    );
    _session._emit(MediaParticipantJoined(participant));
  }

  void _participantLeft(String userId) {
    final existing = _participantById(userId);
    if (existing == null || existing.isLocal) return;
    final screen = _session._snapshot.contentShareTrack;
    final clearScreen =
        screen != null &&
        !screen.isLocal &&
        ((screen is MediaContentOwnerTrack &&
                screen.contentOwnerParticipantId == userId) ||
            screen.participantId == userId ||
            screen.participantId == '$userId#content');
    _session._setSnapshot(
      _session._snapshot.copyWith(
        participants: _session._snapshot.participants
            .where((item) => item.id != userId)
            .toList(),
        clearContentShareTrack: clearScreen,
      ),
    );
    if (clearScreen) {
      _session._emit(
        MediaTrackUnpublished(trackId: screen.id, participantId: userId),
      );
    }
    _session._emit(
      MediaParticipantLeft(
        participantId: userId,
        displayName: existing.displayName,
      ),
    );
  }

  void _remoteScreenShareChanged(
    String ownerUserId,
    String trackUserId,
    bool available,
  ) {
    if (_session._disposed) return;
    final existing = snapshot.contentShareTrack;
    if (available) {
      final track = IvsMediaVideoTrack(
        userId: trackUserId,
        local: false,
        generation: _trackGeneration,
        isScreenShare: true,
        explicitContentOwnerId: ownerUserId,
      );
      _session._setSnapshot(snapshot.copyWith(contentShareTrack: track));
      _session._emit(MediaTrackPublished(track));
      return;
    }
    final matchesOwner =
        existing != null &&
        !existing.isLocal &&
        (existing.participantId == trackUserId ||
            (existing is MediaContentOwnerTrack &&
                existing.contentOwnerParticipantId == ownerUserId));
    if (!matchesOwner) return;
    _session._setSnapshot(snapshot.copyWith(clearContentShareTrack: true));
    _session._emit(
      MediaTrackUnpublished(trackId: existing.id, participantId: ownerUserId),
    );
  }

  void _remoteVideoChanged(String userId, bool available) {
    if (userId == _session._joinInfo?.participantId) return;
    _ensureRemoteParticipant(userId);
    final participants = _session._snapshot.participants.map((item) {
      if (item.id != userId) return item;
      final track = available
          ? IvsMediaVideoTrack(
              userId: userId,
              local: false,
              generation: _trackGeneration,
            )
          : null;
      return item.copyWith(
        isVideoEnabled: available,
        videoTrack: track,
        clearVideoTrack: !available,
      );
    }).toList();
    _session._setSnapshot(
      _session._snapshot.copyWith(participants: participants),
    );
    if (available) {
      _session._emit(
        MediaTrackPublished(
          participants.firstWhere((item) => item.id == userId).videoTrack!,
        ),
      );
    } else {
      _session._emit(
        MediaTrackUnpublished(
          trackId: 'ivs:$userId:camera:$_trackGeneration',
          participantId: userId,
        ),
      );
    }
  }

  void _remoteAudioChanged(String userId, bool available) {
    if (userId == _session._joinInfo?.participantId) return;
    _ensureRemoteParticipant(userId);
    _session._setSnapshot(
      _session._snapshot.copyWith(
        participants: _session._snapshot.participants
            .map(
              (item) =>
                  item.id == userId ? item.copyWith(isMuted: !available) : item,
            )
            .toList(),
      ),
    );
    _session._emit(
      MediaTrackMutedChanged(
        participantId: userId,
        muted: !available,
        kind: MediaTrackKind.audio,
      ),
    );
  }

  void _ensureRemoteParticipant(String userId) {
    if (_participantById(userId) == null) _participantJoined(userId, userId);
  }

  MediaParticipant? _participantById(String id) {
    for (final participant in _session._snapshot.participants) {
      if (participant.id == id) return participant;
    }
    return null;
  }
}
