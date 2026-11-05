part of 'trtc_media_session.dart';

class _TrtcCredentialRefresh {
  _TrtcCredentialRefresh(this._session);
  final _TrtcSessionBase _session;
  String get providerId => _session.providerId;
  MediaCapabilities get capabilities => _session.capabilities;
  MediaRole get role => _session.role;
  MediaSessionState get state => _session.state;
  MediaSnapshot get snapshot => _session.snapshot;
  Duration get cleanupTimeout => _session.cleanupTimeout;
  void cancel() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  Future<void>? _disposeFuture;
  Future<void> dispose() => _disposeFuture ??= Future<void>.sync(() {
    cancel();
    _refreshCallback = null;
  });
  Timer? _refreshTimer;
  Future<void>? _refreshFuture;
  MediaCredentialRefreshCallback? _refreshCallback;
  void setCredentialRefreshCallback(MediaCredentialRefreshCallback? callback) {
    _refreshCallback = callback;
    if (callback == null) _refreshTimer?.cancel();
    if (callback != null && state == MediaSessionState.connected) {
      _scheduleCredentialRefresh();
    }
  }

  Future<void> _refreshAndRejoin() {
    final current = _refreshFuture;
    if (current != null) return current;
    late final Future<void> future;
    future = _refreshAndRejoinOnce().whenComplete(() {
      if (identical(_refreshFuture, future)) _refreshFuture = null;
    });
    _refreshFuture = future;
    return future;
  }

  Future<void> _refreshAndRejoinOnce() async {
    final generation = _session._connectionGeneration;
    final engine = _session._engine;
    bool currentLease() =>
        generation == _session._connectionGeneration &&
        identical(engine, _session._engine) &&
        !_session._disposed &&
        !_session._disposing &&
        state != MediaSessionState.leaving &&
        !state.isTerminal;
    if (!currentLease() || engine == null) return;
    final callback = _refreshCallback;
    final current = _session._joinInfo;
    if (_session._disposed || current == null || callback == null) {
      _session._reportFailure(
        RealtimeException(
          code: RealtimeErrorCode.providerError,
          message:
              'TRTC credentials expired and no refresh callback is available.',
          providerId: providerId,
        ),
      );
      return;
    }
    _refreshTimer?.cancel();
    _session._setState(MediaSessionState.reconnecting);
    try {
      final refreshed = await _refreshCredentials(current);
      if (!currentLease()) return;
      final source = _session._publishing._processedSink.source;
      await _session._exitCloudRoom();
      if (!currentLease()) return;
      _session._joinInfo = refreshed;
      _session._mapper._streamGeneration++;
      await _session._enterRoom(refreshed);
      if (!currentLease()) return;
      if (source != null) {
        await _session._publishing._processedSink.attach(source);
      }
      if (!currentLease()) return;
      if (role.canPublishMedia) {
        if (!_session._snapshot.localMuted) {
          _session._publishing._ensureAudioStarted();
          _session._engine!.muteLocalAudio(false);
        }
        if (_session._snapshot.localVideoEnabled) {
          _session._engine!.muteLocalVideo(false);
        }
        if (_session._snapshot.localScreenShareEnabled) {
          _session._engine!.startScreenCapture();
        }
      }
      _session._mapper._refreshLocalTrack();
      _session._setState(MediaSessionState.connected);
      _scheduleCredentialRefresh();
    } catch (error, stack) {
      if (!currentLease()) return;
      final mapped = _session._mapError(
        error,
        'refreshCredentials',
        stack: stack,
      );
      _session._reportFailure(mapped);
      await _session._releaseCloud();
      if (identical(_activeTrtcSession, _session)) _activeTrtcSession = null;
      _session._setState(MediaSessionState.failed, error: mapped);
    }
  }

  Future<TrtcJoinInfo> _refreshCredentials(TrtcJoinInfo current) async {
    final callback = _refreshCallback;
    if (callback == null) {
      throw RealtimeException(
        code: RealtimeErrorCode.providerError,
        message: 'No backend credential refresh callback is configured.',
        providerId: providerId,
      );
    }
    final refreshed = await callback(current);
    if (refreshed is! TrtcJoinInfo ||
        refreshed.providerId != current.providerId ||
        refreshed.roomCode != current.roomCode ||
        refreshed.participantId != current.participantId ||
        refreshed.userId != current.userId ||
        refreshed.role != current.role ||
        refreshed.strRoomId != current.strRoomId) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'TRTC refresh credentials changed the current room identity.',
        providerId: providerId,
      );
    }
    return refreshed;
  }

  void _scheduleCredentialRefresh() {
    _refreshTimer?.cancel();
    final info = _session._joinInfo;
    if (_session._disposed ||
        _session._disposing ||
        state != MediaSessionState.connected ||
        info == null ||
        _refreshCallback == null ||
        info.expiresAtMs <= 0) {
      return;
    }
    final refreshAtMs = info.expiresAtMs - 30000;
    final delayMs = refreshAtMs - DateTime.now().millisecondsSinceEpoch;
    _refreshTimer = Timer(
      Duration(milliseconds: delayMs > 0 ? delayMs : 0),
      () => unawaited(_refreshAndRejoin()),
    );
  }
}
