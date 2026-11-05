part of 'livekit_media_session.dart';

class _LiveKitEventAdapter {
  _LiveKitEventAdapter(this._session);
  final LiveKitMediaSessionBase _session;
  String get providerId => _session.providerId;
  MediaCapabilities get capabilities => _session.capabilities;
  MediaRole get role => _session.role;
  MediaSessionState get state => _session.state;
  MediaSnapshot get snapshot => _session.snapshot;
  Duration get cleanupTimeout => _session.cleanupTimeout;

  void _attachRoomEvents(lk.Room room) {
    final listener = room.createListener();
    _session._listener = listener;
    listener.on<lk.RoomReconnectingEvent>((_) {
      _session._setState(
        MediaSessionState.reconnecting,
        reason: 'livekit.transportReconnecting',
      );
    });
    listener.on<lk.RoomResumingEvent>((_) {
      _session._setState(
        MediaSessionState.reconnecting,
        reason: 'livekit.transportResuming',
      );
    });
    listener.on<lk.RoomReconnectedEvent>((_) {
      _session._mapper._refreshSnapshot();
      _session._setState(
        MediaSessionState.connected,
        reason: 'livekit.transportReconnected',
      );
    });
    listener.on<lk.RoomDisconnectedEvent>((event) {
      if (state == MediaSessionState.leaving ||
          state == MediaSessionState.disposed) {
        return;
      }
      _session._setState(
        MediaSessionState.ended,
        reason: event.reason?.toString(),
      );
    });
    listener.on<lk.ParticipantConnectedEvent>((event) {
      final participant = _session._mapper._mapRemoteParticipant(
        event.participant,
      );
      _session._mapper._refreshSnapshot();
      _session._emit(MediaParticipantJoined(participant));
    });
    listener.on<lk.ParticipantDisconnectedEvent>((event) {
      final participant = event.participant;
      _session._mapper._refreshSnapshot();
      _session._emit(
        MediaParticipantLeft(
          participantId: participant.identity,
          displayName: participant.name.isEmpty ? null : participant.name,
        ),
      );
    });
    listener.on<lk.ParticipantConnectionQualityUpdatedEvent>((event) {
      final local = room.localParticipant;
      if (local == null || event.participant.identity != local.identity) return;
      final quality = switch (event.connectionQuality) {
        lk.ConnectionQuality.excellent => MediaNetworkQuality.excellent,
        lk.ConnectionQuality.good => MediaNetworkQuality.good,
        lk.ConnectionQuality.poor => MediaNetworkQuality.poor,
        lk.ConnectionQuality.lost => MediaNetworkQuality.down,
        _ => MediaNetworkQuality.unknown,
      };
      final value = MediaConnectionStats(
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        upstreamQuality: quality,
        downstreamQuality: quality,
      );
      _session._connectionStats = value;
      if (!_session._statsController.isClosed) {
        _session._statsController.add(value);
      }
      _session._emit(MediaNetworkStatsUpdated(value));
    });
    listener.on<lk.TrackSubscribedEvent>((event) {
      _session._mapper._refreshSnapshot();
      final track = _session._mapper._videoTrack(
        event.publication,
        event.track,
        event.participant.identity,
        isLocal: false,
      );
      if (track != null) _session._emit(MediaTrackPublished(track));
    });
    listener.on<lk.TrackUnsubscribedEvent>((event) {
      _session._mapper._refreshSnapshot();
      if (event.publication.kind == lk.TrackType.VIDEO) {
        _session._emit(
          MediaTrackUnpublished(
            trackId: event.publication.sid,
            participantId: event.participant.identity,
            wasScreenShare: event.publication.isScreenShare,
          ),
        );
      }
    });
    listener.on<lk.LocalTrackPublishedEvent>((event) {
      _session._mapper._refreshSnapshot();
      final track = event.publication.track;
      if (track != null) {
        final mapped = _session._mapper._videoTrack(
          event.publication,
          track,
          event.participant.identity,
          isLocal: true,
        );
        if (mapped != null) _session._emit(MediaTrackPublished(mapped));
      }
    });
    listener.on<lk.LocalTrackUnpublishedEvent>((event) {
      _session._mapper._refreshSnapshot();
      if (event.publication.kind == lk.TrackType.VIDEO) {
        _session._emit(
          MediaTrackUnpublished(
            trackId: event.publication.sid,
            participantId: event.participant.identity,
            wasScreenShare: event.publication.isScreenShare,
          ),
        );
      }
    });
    listener.on<lk.TrackMutedEvent>((event) {
      _session._mapper._refreshSnapshot();
      _emitTrackMute(event.participant, event.publication, true);
    });
    listener.on<lk.TrackUnmutedEvent>((event) {
      _session._mapper._refreshSnapshot();
      _emitTrackMute(event.participant, event.publication, false);
    });
    listener.on<lk.ActiveSpeakersChangedEvent>((event) {
      final before = <String, bool>{
        for (final participant in _session._snapshot.participants)
          participant.id: participant.isSpeaking,
      };
      final speakerIds = event.speakers.map((item) => item.identity).toSet();
      _session._mapper._activeSpeakerIds = speakerIds;
      _session._mapper._refreshSnapshot();
      for (final participant in _session._snapshot.participants) {
        final speaking = speakerIds.contains(participant.id);
        if ((before[participant.id] ?? false) != speaking) {
          _session._emit(
            MediaSpeakingChanged(
              participantId: participant.id,
              isSpeaking: speaking,
            ),
          );
        }
      }
    });
    listener.on<lk.DataReceivedEvent>((event) {
      final sender = event.participant;
      final message = MediaMessage(
        participantId: sender?.identity ?? 'server',
        displayName: sender == null || sender.name.isEmpty ? '' : sender.name,
        message: utf8.decode(event.data, allowMalformed: true),
        topic: event.topic?.trim().isNotEmpty == true ? event.topic! : 'data',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        providerId: providerId,
      );
      _session._replaceSnapshot(
        _session._snapshot.copyWith(
          messages: [..._session._snapshot.messages, message],
        ),
      );
      _session._emit(MediaMessageReceived(message));
    });
  }

  void _emitTrackMute(
    lk.Participant<lk.TrackPublication<lk.Track>> participant,
    lk.TrackPublication<lk.Track> publication,
    bool muted,
  ) {
    final kind = publication.source == lk.TrackSource.screenShareVideo
        ? MediaTrackKind.screenShare
        : publication.kind == lk.TrackType.AUDIO
        ? MediaTrackKind.audio
        : MediaTrackKind.video;
    _session._emit(
      MediaTrackMutedChanged(
        participantId: participant.identity,
        trackId: publication.sid,
        muted: muted,
        kind: kind,
      ),
    );
  }
}
