part of 'trtc_media_session.dart';

class _TrtcSnapshotMapper {
  _TrtcSnapshotMapper(this._session);
  final _TrtcSessionBase _session;
  String get providerId => _session.providerId;
  MediaCapabilities get capabilities => _session.capabilities;
  MediaRole get role => _session.role;
  MediaSessionState get state => _session.state;
  MediaSnapshot get snapshot => _session.snapshot;
  Duration get cleanupTimeout => _session.cleanupTimeout;

  int _streamGeneration = 0;
  TrtcEngineEvents get _engineEvents {
    final generation = _session._connectionGeneration;
    final engine = _session._engine;
    bool currentLease() =>
        !_session._disposed &&
        !_session._disposing &&
        generation == _session._connectionGeneration &&
        identical(engine, _session._engine) &&
        !state.isTerminal &&
        state != MediaSessionState.leaving;
    return TrtcEngineEvents(
      onError: (code, message) {
        if (!currentLease()) return;
        if (_session._isUserSigFailure(code, message) &&
            state == MediaSessionState.connected) {
          unawaited(_session._credentials._refreshAndRejoin());
          return;
        }
        if (state == MediaSessionState.connected ||
            state == MediaSessionState.reconnecting) {
          _session._reportFailure(
            RealtimeException(
              code: RealtimeErrorCode.providerError,
              message: 'trtc.nativeEvent failed.',
              domain: 'media',
              operation: 'nativeEvent',
              details: {'code': code, 'message': message},
              providerId: providerId,
            ),
          );
        }
      },
      onRemoteUserEnterRoom: (id) {
        if (currentLease()) _remoteUserEntered(id);
      },
      onRemoteUserLeaveRoom: (id) {
        if (currentLease()) _remoteUserLeft(id);
      },
      onUserVideoAvailable: (id, available) {
        if (currentLease()) _remoteVideoAvailable(id, available);
      },
      onUserSubStreamAvailable: (id, available) {
        if (currentLease()) _remoteScreenShareAvailable(id, available);
      },
      onUserAudioAvailable: (id, available) {
        if (currentLease()) _remoteAudioAvailable(id, available);
      },
      onAudioLevels: (volumes) {
        if (currentLease()) _applyAudioLevels(volumes);
      },
      onRecvCustomCmdMsg: (id, command, message) {
        if (currentLease()) {
          _session._data._messageReceived(id, command, message);
        }
      },
      onConnectionLost: () {
        if (currentLease()) _session._setState(MediaSessionState.reconnecting);
      },
      onTryToReconnect: () {
        if (currentLease()) _session._setState(MediaSessionState.reconnecting);
      },
      onConnectionRecovery: () {
        if (!currentLease()) return;
        if (state == MediaSessionState.reconnecting) {
          _session._setState(MediaSessionState.connected);
        }
      },
      onStats: (stats) {
        if (!currentLease()) return;
        _session._connectionStats = stats;
        if (!_session._statsController.isClosed) {
          _session._statsController.add(stats);
        }
        _session._eventController.add(MediaNetworkStatsUpdated(stats));
      },
    );
  }

  TrtcMediaVideoTrack _makeScreenShareTrack(String userId) {
    final engine = _session._engine!;
    // Screen shares must never be cropped: the TRTC sub-stream view defaults to
    // fill, which cuts off whatever does not match the tile aspect ratio.
    engine.setRemoteFillMode(userId, true, true);
    return TrtcMediaVideoTrack(
      userId: userId,
      local: false,
      screenShare: true,
      generation: _streamGeneration,
      frameWidth: engine.remoteWidth(userId, subStream: true),
      frameHeight: engine.remoteHeight(userId, subStream: true),
      startRendering: (viewId) =>
          engine.startRemoteSubStreamView(userId, viewId),
      stopRendering: () => engine.stopRemoteSubStreamView(userId),
    );
  }

  void _remoteUserEntered(String userId) {
    if (userId == _session._joinInfo?.userId) return;
    if (_findParticipant(userId) != null) return;
    final participant = MediaParticipant(id: userId, displayName: userId);
    _session._setSnapshot(
      _session._snapshot.copyWith(
        participants: [..._session._snapshot.participants, participant],
      ),
    );
    _session._eventController.add(MediaParticipantJoined(participant));
  }

  void _remoteUserLeft(String userId) {
    if (_findParticipant(userId) == null) return;
    final sharedTrack = _session._snapshot.contentShareTrack;
    _session._setSnapshot(
      _session._snapshot.copyWith(
        participants: _session._snapshot.participants
            .where((item) => item.id != userId)
            .toList(),
        clearContentShareTrack: sharedTrack?.participantId == userId,
      ),
    );
    _session._eventController.add(MediaParticipantLeft(participantId: userId));
    _session._eventController.add(
      MediaTrackUnpublished(
        trackId: 'trtc:$userId:camera',
        participantId: userId,
      ),
    );
    if (sharedTrack?.participantId == userId) {
      _session._eventController.add(
        MediaTrackUnpublished(
          trackId: sharedTrack!.id,
          participantId: userId,
          wasScreenShare: true,
        ),
      );
    }
  }

  void _remoteVideoAvailable(String userId, bool available) {
    if (userId == _session._joinInfo?.userId) return;
    var participant = _findParticipant(userId);
    if (participant == null) {
      _remoteUserEntered(userId);
      participant = _findParticipant(userId);
    }
    if (participant == null) return;
    if (available && _session._engine != null) {
      final track = _makeVideoTrack(userId, local: false);
      _replaceParticipant(
        participant.copyWith(videoTrack: track, isVideoEnabled: true),
      );
      _session._eventController.add(MediaTrackPublished(track));
    } else {
      _replaceParticipant(
        participant.copyWith(clearVideoTrack: true, isVideoEnabled: false),
      );
      _session._eventController.add(
        MediaTrackUnpublished(
          trackId: 'trtc:$userId:camera',
          participantId: userId,
        ),
      );
    }
  }

  void _remoteAudioAvailable(String userId, bool available) {
    if (userId == _session._joinInfo?.userId) return;
    var participant = _findParticipant(userId);
    if (participant == null) {
      _remoteUserEntered(userId);
      participant = _findParticipant(userId);
    }
    if (participant == null) return;
    _replaceParticipant(
      participant.copyWith(
        isMuted: !available,
        isSpeaking: available && participant.isSpeaking,
      ),
    );
    if (!available && participant.isSpeaking) {
      _session._eventController.add(
        MediaSpeakingChanged(participantId: userId, isSpeaking: false),
      );
    }
  }

  void _applyAudioLevels(Map<String, int> volumes) {
    const speakingThreshold = 12;
    final changed = <String, bool>{};
    final updated = <MediaParticipant>[
      for (final participant in _session._snapshot.participants)
        (() {
          final key = participant.isLocal ? '' : participant.id;
          final volume =
              volumes[key] ??
              (participant.isLocal ? volumes[participant.id] ?? 0 : 0);
          final speaking = !participant.isMuted && volume >= speakingThreshold;
          if (speaking != participant.isSpeaking) {
            changed[participant.id] = speaking;
          }
          return participant.copyWith(isSpeaking: speaking);
        })(),
    ];
    if (changed.isEmpty) return;
    _session._setSnapshot(_session._snapshot.copyWith(participants: updated));
    for (final entry in changed.entries) {
      _session._eventController.add(
        MediaSpeakingChanged(participantId: entry.key, isSpeaking: entry.value),
      );
    }
  }

  void _remoteScreenShareAvailable(String userId, bool available) {
    if (userId == _session._joinInfo?.userId) return;
    if (available && _session._engine != null) {
      final track = _makeScreenShareTrack(userId);
      _session._setSnapshot(
        _session._snapshot.copyWith(contentShareTrack: track),
      );
      _session._eventController.add(MediaTrackPublished(track));
      return;
    }
    final current = _session._snapshot.contentShareTrack;
    if (current?.participantId != userId) return;
    _session._setSnapshot(
      _session._snapshot.copyWith(clearContentShareTrack: true),
    );
    _session._eventController.add(
      MediaTrackUnpublished(
        trackId: current!.id,
        participantId: userId,
        wasScreenShare: true,
      ),
    );
  }

  MediaParticipant? _findParticipant(String id) {
    for (final participant in _session._snapshot.participants) {
      if (participant.id == id) return participant;
    }
    return null;
  }

  void _replaceParticipant(MediaParticipant replacement) {
    final participants = _session._snapshot.participants
        .map((item) => item.id == replacement.id ? replacement : item)
        .toList();
    _session._setSnapshot(
      _session._snapshot.copyWith(participants: participants),
    );
  }

  void _refreshLocalTrack() {
    final info = _session._joinInfo;
    if (info == null ||
        _session._engine == null ||
        !_session._snapshot.localVideoEnabled) {
      return;
    }
    final local = _findParticipant(info.userId);
    if (local == null) return;
    _replaceParticipant(
      local.copyWith(videoTrack: _makeVideoTrack(info.userId, local: true)),
    );
  }

  TrtcMediaVideoTrack _makeVideoTrack(String userId, {required bool local}) {
    final engine = _session._engine!;
    return TrtcMediaVideoTrack(
      userId: userId,
      local: local,
      generation: _streamGeneration,
      startRendering: local
          ? engine.startLocalPreview
          : (viewId) => engine.startRemoteView(userId, viewId),
      stopRendering: local
          ? engine.clearLocalView
          : () => engine.stopRemoteView(userId),
    );
  }
}
