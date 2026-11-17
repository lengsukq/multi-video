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
  IvsEngineEvents _createEngineEvents() {
    final generation = _session._connectionGeneration;
    final engine = _session._engine;
    bool currentLease() =>
        generation == _session._connectionGeneration &&
        identical(engine, _session._engine) &&
        !_session._disposed &&
        !state.isTerminal &&
        state != MediaSessionState.leaving;
    return IvsEngineEvents(
      onError: (code, message) {
        if (currentLease()) _session._onNativeError(code, message);
      },
      onParticipantJoined: (id, name) {
        if (currentLease()) _participantJoined(id, name);
      },
      onParticipantLeft: (id) {
        if (currentLease()) _participantLeft(id);
      },
      onRemoteVideoChanged: (id, available) {
        if (currentLease()) _remoteVideoChanged(id, available);
      },
      onRemoteAudioChanged: (id, available) {
        if (currentLease()) _remoteAudioChanged(id, available);
      },
      onReconnecting: () {
        if (!currentLease()) return;
        if (_session._state == MediaSessionState.connected) {
          _session._setState(MediaSessionState.reconnecting);
        }
      },
      onRecovered: () {
        if (!currentLease()) return;
        if (_session._state == MediaSessionState.reconnecting) {
          _session._setState(MediaSessionState.connected);
        }
      },
      onDisconnected: () {
        if (!currentLease()) return;
        _session._setSnapshot(
          _session._snapshot.copyWith(
            participants: const [],
            clearLocalParticipantId: true,
            localMuted: true,
            localVideoEnabled: false,
            clearContentShareTrack: true,
          ),
        );
        _session._setState(MediaSessionState.ended);
      },
      onStats: (values) {
        if (currentLease()) _session._statistics._onStats(values);
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
    _session._setSnapshot(
      _session._snapshot.copyWith(
        participants: _session._snapshot.participants
            .where((item) => item.id != userId)
            .toList(),
      ),
    );
    _session._emit(
      MediaParticipantLeft(
        participantId: userId,
        displayName: existing.displayName,
      ),
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
