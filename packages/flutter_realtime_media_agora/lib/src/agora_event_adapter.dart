part of 'agora_media_session.dart';

class _AgoraEventAdapter {
  _AgoraEventAdapter(this._session);
  final _AgoraMediaSession _session;
  String get providerId => _session.providerId;
  MediaCapabilities get capabilities => _session.capabilities;
  MediaRole get role => _session.role;
  MediaSessionState get state => _session.state;
  MediaSnapshot get snapshot => _session.snapshot;
  Duration get cleanupTimeout => _session.cleanupTimeout;

  agora.RtcEngineEventHandler _buildEventHandler() {
    return agora.RtcEngineEventHandler(
      onError: (err, message) {
        final error = RealtimeException(
          code: RealtimeErrorCode.providerError,
          message: 'agora.nativeEvent failed.',
          domain: 'media',
          operation: 'nativeEvent',
          details: Map<String, Object>.unmodifiable({
            'code': err,
            'message': message,
          }),
          providerId: providerId,
        );
        _failPendingJoin(error);
        _session._reportFailure(error);
      },
      onJoinChannelSuccess: (connection, elapsed) {
        if (_session._disposed ||
            _session._joinCancelled ||
            _session._state == MediaSessionState.leaving ||
            _session._state == MediaSessionState.ended) {
          return;
        }
        final uid = connection.localUid ?? _session._joinInfo?.uid;
        if (uid != null) {
          _session._localUid = uid;
          final info = _session._joinInfo;
          _session._mapper._participants[uid.toString()] = MediaParticipant(
            id: uid.toString(),
            displayName: (info?.displayName.isNotEmpty ?? false)
                ? info!.displayName
                : uid.toString(),
            isLocal: true,
            isMuted: _session._publishing._localMuted,
            isVideoEnabled: _session._publishing._localVideoEnabled,
            videoTrack: _session._publishing._localVideoEnabled
                ? _session._mapper._videoTrack(uid, local: true)
                : null,
            joinedAt: DateTime.now(),
          );
        }
        _session._refreshSnapshot();
        if (_session._state != MediaSessionState.connected) {
          _session._setState(MediaSessionState.connected);
        }
        final completer = _session._joinCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.complete();
        }
      },
      onRtcStats: (connection, value) {
        _updateConnectionStats(
          (_session._connectionStats ??
                  MediaConnectionStats(
                    timestampMs: DateTime.now().millisecondsSinceEpoch,
                  ))
              .copyWith(
                timestampMs: DateTime.now().millisecondsSinceEpoch,
                rttMs: value.lastmileDelay,
                uplinkPacketLossPercent: value.txPacketLossRate?.toDouble(),
                downlinkPacketLossPercent: value.rxPacketLossRate?.toDouble(),
                uploadKbps: value.txKBitRate,
                downloadKbps: value.rxKBitRate,
              ),
        );
      },
      onNetworkQuality: (connection, remoteUid, txQuality, rxQuality) {
        if (remoteUid != 0) return;
        _updateConnectionStats(
          (_session._connectionStats ??
                  MediaConnectionStats(
                    timestampMs: DateTime.now().millisecondsSinceEpoch,
                  ))
              .copyWith(
                timestampMs: DateTime.now().millisecondsSinceEpoch,
                upstreamQuality: _mapAgoraQuality(txQuality),
                downstreamQuality: _mapAgoraQuality(rxQuality),
              ),
        );
      },
      onRejoinChannelSuccess: (connection, elapsed) {
        _session._refreshSnapshot();
        _session._setState(MediaSessionState.connected);
      },
      onConnectionStateChanged: (connection, state, reason) {
        switch (state) {
          case agora.ConnectionStateType.connectionStateConnecting:
            if (_session._state != MediaSessionState.joining) {
              _session._setState(
                MediaSessionState.connecting,
                reason: reason.name,
              );
            }
          case agora.ConnectionStateType.connectionStateConnected:
            if (_session._state == MediaSessionState.reconnecting) {
              _session._setState(
                MediaSessionState.connected,
                reason: reason.name,
              );
            }
          case agora.ConnectionStateType.connectionStateReconnecting:
            _session._setState(
              MediaSessionState.reconnecting,
              reason: reason.name,
            );
          case agora.ConnectionStateType.connectionStateFailed:
            final error = RealtimeException(
              code: RealtimeErrorCode.providerError,
              message: 'agora.connection failed.',
              details: reason,
              providerId: providerId,
            );
            _failPendingJoin(error);
            _session._reportFailure(error);
            _session._setState(
              MediaSessionState.failed,
              reason: reason.name,
              error: error,
            );
          case agora.ConnectionStateType.connectionStateDisconnected:
            final pending = _session._joinCompleter;
            if (pending != null && !pending.isCompleted) {
              final error = RealtimeException(
                code: RealtimeErrorCode.providerError,
                message: 'agora.join disconnected.',
                providerId: providerId,
              );
              _failPendingJoin(error);
              _session._reportFailure(error);
              _session._setState(
                MediaSessionState.failed,
                reason: reason.name,
                error: error,
              );
              return;
            }
            if (_session._state != MediaSessionState.leaving &&
                _session._state != MediaSessionState.ended &&
                _session._state != MediaSessionState.disposed &&
                _session._state != MediaSessionState.failed &&
                _session._state != MediaSessionState.idle) {
              _session._setState(MediaSessionState.ended, reason: reason.name);
            }
        }
      },
      onUserJoined: (connection, uid, elapsed) {
        final id = uid.toString();
        final previous = _session._mapper._participants[id];
        final participant =
            previous ??
            MediaParticipant(id: id, displayName: id, joinedAt: DateTime.now());
        _session._mapper._participants[id] = participant;
        _session._refreshSnapshot();
        if (previous == null) {
          _session._emit(MediaParticipantJoined(participant));
        }
        // RTC data has no history: announce to late joiners.
        if (_session._publishing._localScreenShareEnabled) {
          unawaited(_session._data._announceScreenShareState(true));
        }
      },
      onUserOffline: (connection, uid, reason) {
        final id = uid.toString();
        final removed = _session._mapper._participants.remove(id);
        _session._mapper._remoteScreenState.remove(uid);
        final screen = _session._mapper._remoteScreenTracks.remove(uid);
        if (screen != null) {
          _session._emit(
            MediaTrackUnpublished(
              trackId: screen.id,
              participantId: id,
              wasScreenShare: true,
            ),
          );
        }
        if (_session._mapper._activeSpeakerUid == uid) {
          _session._mapper._activeSpeakerUid = null;
        }
        _session._refreshSnapshot();
        _session._emit(
          MediaParticipantLeft(
            participantId: id,
            displayName: removed?.displayName,
          ),
        );
      },
      onUserMuteAudio: (connection, remoteUid, muted) {
        _session._mapper._updateRemoteParticipant(
          remoteUid,
          (participant) => participant.copyWith(isMuted: muted),
        );
        _session._emit(
          MediaTrackMutedChanged(
            participantId: remoteUid.toString(),
            muted: muted,
            kind: MediaTrackKind.audio,
          ),
        );
      },
      onUserMuteVideo: (connection, remoteUid, muted) {
        _session._mapper._setRemoteVideoState(remoteUid, enabled: !muted);
        _session._emit(
          MediaTrackMutedChanged(
            participantId: remoteUid.toString(),
            muted: muted,
            trackId:
                'agora:${_session._joinInfo?.channelName}:$remoteUid:${_session._mapper._remoteScreenState.isScreenPublisher(remoteUid) ? 'screen' : 'camera'}',
          ),
        );
      },
      onRemoteVideoStateChanged:
          (connection, remoteUid, state, reason, elapsed) {
            final enabled =
                state == agora.RemoteVideoState.remoteVideoStateStarting ||
                state == agora.RemoteVideoState.remoteVideoStateDecoding ||
                state == agora.RemoteVideoState.remoteVideoStateFrozen;
            _session._mapper._setRemoteVideoState(remoteUid, enabled: enabled);
          },
      onLocalVideoStateChanged: (source, state, reason) {
        if (state == agora.LocalVideoStreamState.localVideoStreamStateFailed) {
          if (source == agora.VideoSourceType.videoSourceScreen &&
              _session._publishing._localScreenShareEnabled) {
            _session._publishing._stopScreenShareAnnouncements();
            final track = _session._publishing._localScreenTrack;
            _session._publishing._localScreenShareEnabled = false;
            _session._publishing._localScreenTrack = null;
            if (track != null) {
              _session._emit(
                MediaTrackUnpublished(
                  trackId: track.id,
                  participantId: track.participantId,
                  wasScreenShare: true,
                ),
              );
            }
            _session._refreshSnapshot();
            final engine = _session._engine;
            if (engine != null) {
              unawaited(() async {
                try {
                  await engine.stopScreenCapture();
                  if (!_session._disposed && !_session._joinCancelled) {
                    await _session._publishing._updatePublishOptions();
                  }
                } catch (error, stack) {
                  _session._reportFailure(
                    _session._mapError(error, 'screenShare.stop', stack: stack),
                  );
                }
              }());
            }
          }
          _session._reportFailure(
            RealtimeException(
              code: RealtimeErrorCode.providerError,
              message: 'agora.localVideo failed.',
              details: reason,
              providerId: providerId,
            ),
          );
        }
      },
      onActiveSpeaker: (connection, uid) {
        final previous = _session._mapper._activeSpeakerUid;
        if (previous == uid) return;
        _session._mapper._activeSpeakerUid = uid == 0 ? null : uid;
        if (previous != null) {
          _session._mapper._updateRemoteParticipant(
            previous,
            (participant) => participant.copyWith(isSpeaking: false),
            emitSnapshot: false,
          );
          _session._emit(
            MediaSpeakingChanged(
              participantId: previous.toString(),
              isSpeaking: false,
            ),
          );
        }
        if (uid != 0) {
          _session._mapper._updateRemoteParticipant(
            uid,
            (participant) => participant.copyWith(isSpeaking: true),
            emitSnapshot: false,
          );
          _session._emit(
            MediaSpeakingChanged(
              participantId: uid.toString(),
              isSpeaking: true,
            ),
          );
        }
        _session._refreshSnapshot();
      },
      onStreamMessage: (connection, remoteUid, streamId, data, length, sentTs) {
        _session._data._handleStreamMessage(remoteUid, data, sentTs);
      },
      onRequestToken: (connection) {
        final error = RealtimeException(
          code: RealtimeErrorCode.providerError,
          message:
              'Agora requested a new token before the session finished joining. '
              'Check the App ID, App Certificate, token TTL, channel name, and UID.',
          providerId: providerId,
        );
        _failPendingJoin(error);
        _session._reportFailure(error);
      },
      onPermissionError: (permissionType) {
        final error = RealtimeException(
          code: RealtimeErrorCode.permissionDenied,
          message: 'agora.permission denied.',
          details: permissionType,
          providerId: providerId,
        );
        _failPendingJoin(error);
        _session._reportFailure(error);
      },
    );
  }

  void _updateConnectionStats(MediaConnectionStats value) {
    _session._connectionStats = value;
    if (!_session._statsController.isClosed) {
      _session._statsController.add(value);
    }
    _session._emit(MediaNetworkStatsUpdated(value));
  }

  MediaNetworkQuality _mapAgoraQuality(agora.QualityType value) =>
      switch (value) {
        agora.QualityType.qualityExcellent => MediaNetworkQuality.excellent,
        agora.QualityType.qualityGood => MediaNetworkQuality.good,
        agora.QualityType.qualityPoor => MediaNetworkQuality.fair,
        agora.QualityType.qualityBad => MediaNetworkQuality.poor,
        agora.QualityType.qualityVbad => MediaNetworkQuality.bad,
        agora.QualityType.qualityDown => MediaNetworkQuality.down,
        _ => MediaNetworkQuality.unknown,
      };
  bool _failPendingJoin(RealtimeException error) {
    final completer = _session._joinCompleter;
    if (completer == null || completer.isCompleted) return false;
    completer.completeError(error);
    return true;
  }
}
