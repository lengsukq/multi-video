part of 'ivs_media_session.dart';

class _IvsCredentialRefresh {
  _IvsCredentialRefresh(this._session);
  final _IvsMediaSession _session;
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
  Future<void>? _refreshFuture;
  Timer? _refreshTimer;
  MediaCredentialRefreshCallback? _refreshCallback;
  MediaRoleChangeCallback? _roleChangeCallback;

  void setCredentialRefreshCallback(MediaCredentialRefreshCallback? callback) {
    _refreshCallback = callback;
    _scheduleCredentialRefresh();
  }

  void setRoleChangeCallback(MediaRoleChangeCallback? callback) {
    _roleChangeCallback = callback;
  }

  void _adoptFrom(_IvsCredentialRefresh previous) {
    _refreshCallback = previous._refreshCallback;
    _roleChangeCallback = previous._roleChangeCallback;
    previous.cancel();
    _scheduleCredentialRefresh();
  }

  Future<MediaSession> switchRole(MediaRole targetRole) async {
    _session._requireActive();
    if (targetRole == _session.role) return _session;
    final callback = _roleChangeCallback;
    if (callback == null) {
      throw _session._error(
        RealtimeErrorCode.invalidState,
        'No role-change credential provider is attached.',
      );
    }
    final engine = _session._engine;
    final current = _session._joinInfo;
    if (engine == null || current == null) {
      throw _session._error(
        RealtimeErrorCode.invalidState,
        'IVS session is not active.',
      );
    }
    final nextJoinInfo = _validateRefreshedInfo(
      current,
      await callback(targetRole),
      expectedRole: targetRole,
    );
    if (targetRole == MediaRole.viewer) {
      if (_session._snapshot.localScreenShareEnabled) {
        try {
          await _session._publishing._setScreenShareEnabled(false);
        } catch (_) {
          await _session._publishing._revokeAuxiliaryScreenTokenIfNeeded();
        }
      }
      await _session._publishing.detachProcessedVideoSource();
    }
    await engine.exchangeToken(
      nextJoinInfo.token,
      role: targetRole,
      capabilities: nextJoinInfo.capabilities,
    );
    if (_session._disposed) return _session;
    _session._joinInfo = nextJoinInfo;
    _scheduleCredentialRefresh();
    final _IvsMediaSession next = switch (targetRole) {
      MediaRole.host => IvsBroadcastHostSession(
        engineFactory: _session.engineFactory,
      ),
      MediaRole.viewer => IvsBroadcastViewerSession(
        engineFactory: _session.engineFactory,
      ),
      MediaRole.participant => IvsParticipantSession(
        engineFactory: _session.engineFactory,
      ),
    };
    next._adoptStateFrom(_session);
    return next;
  }

  Future<void> _refreshCredentials() {
    final current = _refreshFuture;
    if (current != null) return current;
    late final Future<void> future;
    future = _refreshCredentialsOnce().whenComplete(() {
      if (identical(_refreshFuture, future)) _refreshFuture = null;
    });
    _refreshFuture = future;
    return future;
  }

  Future<void> _refreshCredentialsOnce() async {
    final generation = _session._connectionGeneration;
    final engine = _session._engine;
    bool currentLease() =>
        generation == _session._connectionGeneration &&
        identical(engine, _session._engine) &&
        !_session._disposed &&
        !state.isTerminal &&
        state != MediaSessionState.leaving;
    if (!currentLease() || engine == null) return;
    final callback = _refreshCallback;
    final current = _session._joinInfo;
    if (_session._disposed ||
        callback == null ||
        current == null ||
        _session._engine == null) {
      return;
    }
    _refreshTimer?.cancel();
    try {
      final refreshed = _validateRefreshedInfo(
        current,
        await callback(current),
      );
      if (!currentLease()) return;
      await engine.exchangeToken(refreshed.token);
      if (!currentLease()) return;
      _session._joinInfo = refreshed;
      _scheduleCredentialRefresh();
    } catch (error, stack) {
      if (!currentLease()) return;
      final mapped = _session._mapError(
        error,
        'refreshCredentials',
        stack: stack,
      );
      _session._setSnapshot(_session._snapshot.copyWith(lastError: mapped));
      _session._emit(MediaFailureEvent(mapped));
    }
  }

  IvsJoinInfo _validateRefreshedInfo(
    IvsJoinInfo current,
    MediaJoinInfo refreshed, {
    MediaRole? expectedRole,
  }) {
    final targetRole = expectedRole ?? current.role;
    if (refreshed is! IvsJoinInfo ||
        refreshed.providerId != current.providerId ||
        refreshed.roomCode != current.roomCode ||
        refreshed.participantId != current.participantId ||
        refreshed.stageArn != current.stageArn ||
        refreshed.role != targetRole) {
      throw _session._error(
        RealtimeErrorCode.invalidArgument,
        'IVS refreshed credentials changed the active stage or identity.',
      );
    }
    return refreshed;
  }

  void _scheduleCredentialRefresh() {
    _refreshTimer?.cancel();
    final info = _session._joinInfo;
    if (info == null ||
        _refreshCallback == null ||
        _session._state != MediaSessionState.connected) {
      return;
    }
    final delayMs =
        info.expiresAtMs - 30000 - DateTime.now().millisecondsSinceEpoch;
    _refreshTimer = Timer(
      Duration(milliseconds: delayMs > 0 ? delayMs : 0),
      () => unawaited(_refreshCredentials()),
    );
  }
}
