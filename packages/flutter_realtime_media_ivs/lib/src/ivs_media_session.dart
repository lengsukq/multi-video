import 'package:flutter_realtime_processed_video/flutter_realtime_processed_video.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'ivs_engine.dart';
import 'ivs_join_info.dart';
import 'ivs_media_track.dart';

part 'ivs_publishing.dart';
part 'ivs_credential_refresh.dart';
part 'ivs_statistics.dart';
part 'ivs_snapshot_mapper.dart';

part 'ivs_participant_session.dart';

part 'ivs_broadcast_host_session.dart';

part 'ivs_broadcast_viewer_session.dart';

_IvsMediaSession? _activeIvsSession;

abstract class _IvsMediaSession
    implements
        MediaSession,
        MediaCredentialRefreshable,
        MediaStatsProvider,
        ProcessedVideoSink,
        MediaDeviceController {
  _IvsMediaSession({required this.role, required this.engineFactory})
    : _snapshot = MediaSnapshot(role: role);

  final IvsEngineFactory engineFactory;
  final StreamController<MediaSessionState> _states =
      StreamController<MediaSessionState>.broadcast();
  final StreamController<MediaSnapshot> _snapshots =
      StreamController<MediaSnapshot>.broadcast();
  final StreamController<MediaEvent> _events =
      StreamController<MediaEvent>.broadcast();

  IvsEngine? _engine;
  IvsJoinInfo? _joinInfo;
  MediaSessionState _state = MediaSessionState.idle;
  MediaSnapshot _snapshot;
  bool _disposed = false;
  bool _joinCancelled = false;
  int _connectionGeneration = 0;
  Future<void>? _joinFuture;
  Future<void>? _disposeFuture;
  Duration cleanupTimeout = const Duration(seconds: 10);

  late final _publishing = _IvsPublishing(this);
  late final _credentials = _IvsCredentialRefresh(this);
  late final _statistics = _IvsStatistics(this);
  late final _mapper = _IvsSnapshotMapper(this);

  @override
  final MediaRole role;
  @override
  String get providerId => IvsJoinInfo.providerIdValue;

  @override
  MediaCapabilities get capabilities {
    final publisher = role != MediaRole.viewer;
    return MediaCapabilities(
      canPublishAudio: publisher,
      canPublishVideo: publisher,
      canScreenShare:
          publisher && !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS,
      canSwitchCamera:
          publisher && defaultTargetPlatform != TargetPlatform.macOS,
      canBlurBackground: publisher && _publishing._effectsPlatform,
      canReplaceBackgroundImage: publisher && _publishing._effectsPlatform,
      canEnumerateCameras: publisher && _publishing._effectsPlatform,
      canSelectCamera: publisher && _publishing._effectsPlatform,
      canSubscribeVideo: true,
      canReportNetworkStats: true,
      canListParticipants: role == MediaRole.host,
      canRemoveParticipants: role == MediaRole.host,
      canCloseRoom: role == MediaRole.host,
    );
  }

  @override
  MediaSessionState get state => _state;
  @override
  MediaSnapshot get snapshot => _snapshot;
  @override
  Stream<MediaSessionState> get states => _states.stream;
  @override
  Stream<MediaSnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<MediaEvent> get events => _events.stream;
  @override
  MediaConnectionStats? get connectionStats => _statistics._connectionStats;
  @override
  Stream<MediaConnectionStats> get stats => _statistics._stats.stream;

  @override
  void setCredentialRefreshCallback(MediaCredentialRefreshCallback? callback) =>
      _credentials.setCredentialRefreshCallback(callback);
  @override
  bool supportsProcessedVideoSource(ProcessedVideoSource source) =>
      _publishing.supportsProcessedVideoSource(source);
  @override
  Future<void> attachProcessedVideoSource(ProcessedVideoSource source) =>
      _publishing.attachProcessedVideoSource(source);
  @override
  Future<void> detachProcessedVideoSource() =>
      _publishing.detachProcessedVideoSource();
  @override
  Future<List<MediaDevice>> listMediaDevices({Set<MediaDeviceKind>? kinds}) =>
      _publishing.listMediaDevices(kinds: kinds);
  @override
  Future<void> selectMediaDevice(MediaDevice device) =>
      _publishing.selectMediaDevice(device);

  @override
  Future<void> join(MediaJoinInfo joinInfo) {
    if (_joinFuture != null) {
      return Future.error(
        _error(
          RealtimeErrorCode.invalidState,
          'An IVS join is already in progress.',
        ),
      );
    }
    _joinCancelled = false;
    late final Future<void> future;
    future = _join(joinInfo).whenComplete(() {
      if (identical(_joinFuture, future)) _joinFuture = null;
    });
    _joinFuture = future;
    return future;
  }

  Future<void> _join(MediaJoinInfo joinInfo) async {
    if (_disposed || _state == MediaSessionState.disposed) {
      throw _error(
        RealtimeErrorCode.invalidState,
        'An IVS session cannot join after dispose.',
      );
    }
    if (_state == MediaSessionState.joining || _state.isActive) {
      throw _error(
        RealtimeErrorCode.invalidState,
        'This IVS session is already joining or active.',
      );
    }
    if (joinInfo is! IvsJoinInfo ||
        joinInfo.providerId != providerId ||
        joinInfo.role != role) {
      throw _error(
        RealtimeErrorCode.invalidArgument,
        'IVS join information does not match this session.',
      );
    }
    if (_activeIvsSession != null && !identical(_activeIvsSession, this)) {
      throw _error(
        RealtimeErrorCode.invalidState,
        'The IVS Flutter bridge currently supports one active Stage per app process.',
      );
    }
    _connectionGeneration++;
    _activeIvsSession = this;
    _joinInfo = joinInfo;
    _setState(MediaSessionState.joining);
    try {
      _engine ??= await engineFactory();
      _ensureJoinNotCancelled();
      _setState(MediaSessionState.connecting);
      await _engine!.join(joinInfo, _mapper._createEngineEvents());
      _ensureJoinNotCancelled();
      await _publishing._probeProcessedVideoInput();
      _ensureJoinNotCancelled();
      final local = MediaParticipant(
        id: joinInfo.participantId,
        displayName: joinInfo.displayName.isEmpty
            ? joinInfo.participantId
            : joinInfo.displayName,
        isLocal: true,
        isMuted: true,
      );
      _setSnapshot(
        _snapshot.copyWith(
          participants: [local],
          localParticipantId: joinInfo.participantId,
          localMuted: true,
          localVideoEnabled: false,
          capabilities: capabilities,
          clearLastError: true,
        ),
      );
      _setState(MediaSessionState.connected);
      _credentials._scheduleCredentialRefresh();
      _statistics._startStatsPolling();
    } catch (error, stack) {
      final cancelled = _disposed || _joinCancelled;
      final mapped = cancelled
          ? _error(RealtimeErrorCode.cancelled, 'ivs.join cancelled.')
          : _mapError(error, 'join', stack: stack);
      final cleanup = Cleanup(timeout: cleanupTimeout);
      if (!cancelled) {
        await cleanup.run('rollback.leave', () => _releaseEngine(leave: true));
      }
      await cleanup.run('rollback.dispose', () => _releaseEngine(leave: false));
      if (identical(_activeIvsSession, this)) _activeIvsSession = null;
      if (!cancelled) _setState(MediaSessionState.failed, error: mapped);
      cleanup.finish(domain: providerId, cause: mapped);
      Error.throwWithStackTrace(mapped, stack);
    }
  }

  void _ensureJoinNotCancelled() {
    if (_disposed || _joinCancelled) {
      throw _error(RealtimeErrorCode.cancelled, 'The IVS join was cancelled.');
    }
  }

  Future<void>? _leaveFuture;
  @override
  Future<void> leave() => _leaveFuture ??= _leave().whenComplete(() {
    _leaveFuture = null;
  });
  Future<void> _leave() async {
    _connectionGeneration++;
    if (_disposed ||
        _state == MediaSessionState.idle ||
        _state == MediaSessionState.ended) {
      return;
    }
    _credentials.cancel();
    _statistics.stop();
    _joinCancelled = _joinCancelled || _joinFuture != null;
    _setState(MediaSessionState.leaving);
    final cleanup = Cleanup(timeout: cleanupTimeout);
    var left = false;
    await cleanup.run('engine.leave', () async {
      await _releaseEngine(leave: true);
      left = true;
    });
    if (!left || _joinCancelled) {
      await cleanup.run('engine.dispose', () => _releaseEngine(leave: false));
    }
    if (identical(_activeIvsSession, this)) _activeIvsSession = null;
    _mapper._trackGeneration++;
    _setSnapshot(
      _snapshot.copyWith(
        participants: const [],
        messages: const [],
        clearLocalParticipantId: true,
        localMuted: true,
        localVideoEnabled: false,
        clearContentShareTrack: true,
      ),
    );
    _setState(MediaSessionState.ended);
    cleanup.finish(domain: providerId);
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _connectionGeneration++;
    _disposed = true;
    _joinCancelled = true;
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run('refresh.timer', () async {
      await _credentials.dispose();
    });
    if (_state.isActive || _state == MediaSessionState.connecting) {
      await cleanup.run('engine.leave', () => _releaseEngine(leave: true));
    }
    await cleanup.run('engine.dispose', () => _releaseEngine(leave: false));
    await cleanup.run('active.owner', () async {
      if (identical(_activeIvsSession, this)) _activeIvsSession = null;
    });
    await cleanup.run('terminal', () async {
      _setState(MediaSessionState.disposed);
    });
    await cleanup.run('states', () async {
      await _states.close();
    });
    await cleanup.run('snapshots', () async {
      await _snapshots.close();
    });
    await cleanup.run('events', () async {
      await _events.close();
    });
    await cleanup.run('stats.timer', () async {
      _statistics.stop();
    });
    await cleanup.run('stats', () async {
      await _statistics.dispose();
    });
    cleanup.finish(domain: providerId);
  }

  void _onNativeError(int code, String message) {
    final error = RealtimeException(
      code: RealtimeErrorCode.providerError,
      message: 'ivs.nativeEvent failed.',
      domain: 'media',
      operation: 'nativeEvent',
      details: {'code': code, 'message': message},
      providerId: providerId,
    );
    _setSnapshot(_snapshot.copyWith(lastError: error));
    _emit(MediaFailureEvent(error));
  }

  Future<void> _unsupported(String feature) async {
    throw _error(
      RealtimeErrorCode.unsupportedFeature,
      'Amazon IVS Real-Time does not expose $feature through the media adapter.',
    );
  }

  void _setState(MediaSessionState next, {RealtimeException? error}) {
    if (_disposed) {
      if (next == MediaSessionState.disposed) {
        _state = next;
        _snapshot = _snapshot.copyWith(state: next);
      }
      return;
    }
    final previous = _state;
    if (previous == next && error == null) return;
    _state = next;
    _snapshot = _snapshot.copyWith(
      state: next,
      lastError: error,
      clearLastError: error == null,
    );
    _states.add(next);
    _snapshots.add(_snapshot);
    _emit(MediaConnectionStateChanged(previous: previous, current: next));
    if (error != null) _emit(MediaFailureEvent(error));
  }

  void _emit(MediaEvent event) {
    if (!_disposed && !_events.isClosed) _events.add(event);
  }

  void _setSnapshot(MediaSnapshot next) {
    if (_disposed) return;
    _snapshot = next;
    _snapshots.add(next);
  }

  Future<void> _releaseEngine({required bool leave}) async {
    final engine = _engine;
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run('screenCapture', _publishing._stopIosScreenCapture);
    await cleanup.run('processed.input', _publishing._processedSink.detach);
    if (engine != null) {
      if (leave) {
        await cleanup.run('engine.leave', engine.leave);
      } else {
        _engine = null;
        await cleanup.run('engine.dispose', engine.dispose);
      }
    }
    cleanup.finish(domain: providerId);
  }

  void _requireActive() {
    if (!_state.isActive || _engine == null) {
      throw _error(
        RealtimeErrorCode.invalidState,
        'IVS media controls require an active session.',
      );
    }
  }

  void _requireCapability(bool allowed, String feature) {
    if (!allowed) {
      throw _error(
        RealtimeErrorCode.unsupportedFeature,
        'IVS ${role.name} sessions do not support $feature.',
      );
    }
  }

  RealtimeException _mapError(Object error, String stage, {StackTrace? stack}) {
    final typed = error is RealtimeException ? error : null;
    return normalizeRealtimeException(
      RealtimeException(
        code:
            (typed?.code == RealtimeErrorCode.unknown ? null : typed?.code) ??
            (error is TimeoutException
                ? RealtimeErrorCode.timeout
                : RealtimeErrorCode.providerError),
        message: 'ivs.$stage failed.',
        providerId: providerId,
        domain: 'media',
        operation: stage,
        cause: typed?.cause ?? error,
        details: typed?.details,
        statusCode: typed?.statusCode,
        recoverable: typed?.recoverable ?? false,
        suggestedAction: typed?.suggestedAction,
        stackTrace: stack ?? typed?.stackTrace,
      ),
      domain: 'media',
      operation: stage,
      providerId: providerId,
      stackTrace: stack,
    );
  }

  RealtimeException _error(RealtimeErrorCode code, String message) =>
      RealtimeException(code: code, message: message, providerId: providerId);
}
