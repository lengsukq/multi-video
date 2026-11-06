part of 'media_room_session.dart';

/// Owns backend presence; media failures never belong to this stream.
class _RoomPresence {
  _RoomPresence(
    this._presence,
    this.roomCode,
    this.participantId,
    this._heartbeatInterval,
  );
  final MediaRoomPresence? _presence;
  final String roomCode;
  final String participantId;
  final Duration _heartbeatInterval;
  final _backendErrorController =
      StreamController<RealtimeException>.broadcast();
  Timer? _heartbeatTimer;
  Timer? _initialHeartbeatTimer;
  Future<void>? _heartbeatFuture;
  Future<void>? _leaveNotificationFuture;
  Future<void>? _disposeFuture;
  bool leaveNotified = false;
  bool _disposed = false;
  Stream<RealtimeException> get errors => _backendErrorController.stream;
  Future<void> drain() async {
    await _heartbeatFuture;
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();
  Future<void> _dispose() async {
    _disposed = true;
    stop();
    await _backendErrorController.close();
  }

  void start() {
    if (_presence == null) return;
    if (_heartbeatInterval <= Duration.zero) return;
    _initialHeartbeatTimer = Timer(
      Duration.zero,
      () => unawaited(_heartbeat()),
    );
    _heartbeatTimer = Timer.periodic(
      _heartbeatInterval,
      (_) => unawaited(_heartbeat()),
    );
  }

  void stop() {
    _initialHeartbeatTimer?.cancel();
    _initialHeartbeatTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _heartbeat() {
    if (_disposed || leaveNotified) return Future<void>.value();
    final current = _heartbeatFuture;
    if (current != null) return current;
    late final Future<void> future;
    future = _sendHeartbeat().whenComplete(() {
      if (identical(_heartbeatFuture, future)) _heartbeatFuture = null;
    });
    _heartbeatFuture = future;
    return future;
  }

  Future<void> _sendHeartbeat() async {
    final presence = _presence;
    if (presence == null) return;
    try {
      await presence.heartbeat(roomCode, participantId: participantId);
    } on RealtimeException catch (error) {
      if (error.code == RealtimeErrorCode.roomNotFound) {
        // A previously joined room disappearing is an authoritative end,
        // rather than a transient network failure. Mark this heartbeat as the
        // source so room UIs don't mistake unrelated 404s for a room close.
        stop();
        _reportBackendError(
          RealtimeException(
            code: error.code,
            message: error.message,
            domain: 'media',
            operation: 'room.presence.heartbeat',
            providerId: error.providerId,
            statusCode: error.statusCode,
            details: error.details,
          ),
        );
      } else {
        _reportBackendError(error);
      }
    }
  }

  Future<void> notifyLeave() {
    final current = _leaveNotificationFuture;
    if (current != null) return current;
    if (leaveNotified) return Future<void>.value();
    if (_presence == null) {
      leaveNotified = true;
      return Future<void>.value();
    }
    leaveNotified = true;
    late final Future<void> future;
    future = _sendLeaveBestEffort().whenComplete(() {
      if (identical(_leaveNotificationFuture, future)) {
        _leaveNotificationFuture = null;
      }
    });
    _leaveNotificationFuture = future;
    return future;
  }

  Future<void> _sendLeaveBestEffort() async {
    final presence = _presence;
    if (presence == null) return;
    try {
      await presence.leave(roomCode, participantId: participantId);
    } on RealtimeException catch (error) {
      _reportBackendError(error);
    }
  }

  void _reportBackendError(RealtimeException error) {
    if (!_backendErrorController.isClosed) {
      _backendErrorController.add(error);
    }
  }
}
