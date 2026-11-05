import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'trtc_engine.dart';
import 'package:flutter_realtime_processed_video/flutter_realtime_processed_video.dart';
import 'trtc_join_info.dart';
import 'trtc_media_track.dart';

part 'trtc_publishing.dart';
part 'trtc_credential_refresh.dart';
part 'trtc_data_messenger.dart';
part 'trtc_snapshot_mapper.dart';

part 'trtc_capabilities.dart';

part 'trtc_participant_session.dart';

part 'trtc_host_session.dart';

part 'trtc_viewer_session.dart';

part 'trtc_interactive_session.dart';

const _customMessageCommandId = 1;
const _userSigCheckFailed = -100018;

TrtcMediaSession? _activeTrtcSession;

/// Shared TRTC room lifecycle exposed for provider-specific integrations.
abstract class TrtcMediaSession
    implements MediaSession, MediaCredentialRefreshable {}

abstract class _TrtcSessionBase
    implements
        TrtcMediaSession,
        MediaStatsProvider,
        MediaDataPayloadSizer,
        ProcessedVideoSink,
        MediaDeviceController {
  _TrtcSessionBase(this.role, this._capabilities, this._engineFactory)
    : _snapshot = MediaSnapshot(role: role, capabilities: _capabilities);

  @override
  String get providerId => TrtcJoinInfo.providerIdValue;

  late final _publishing = _TrtcPublishing(this);
  late final _credentials = _TrtcCredentialRefresh(this);
  late final _data = _TrtcDataMessenger(this);
  late final _mapper = _TrtcSnapshotMapper(this);

  @override
  final MediaRole role;

  final MediaCapabilities _capabilities;
  final TrtcEngineFactory _engineFactory;
  MediaSnapshot _snapshot;
  TrtcEngine? _engine;
  TrtcJoinInfo? _joinInfo;
  Future<void>? _joinFuture;
  Future<void>? _leaveFuture;
  Future<void>? _disposeFuture;
  bool _enterRequested = false;
  bool _disposed = false;
  bool _disposing = false;
  bool _leaveRequestedDuringJoin = false;
  Duration cleanupTimeout = const Duration(seconds: 10);
  int _connectionGeneration = 0;

  final _stateController = StreamController<MediaSessionState>.broadcast();
  final _snapshotController = StreamController<MediaSnapshot>.broadcast();
  final _eventController = StreamController<MediaEvent>.broadcast();
  final _statsController = StreamController<MediaConnectionStats>.broadcast();
  MediaConnectionStats? _connectionStats;

  @override
  MediaCapabilities get capabilities => _capabilities;

  @override
  MediaSessionState get state => _snapshot.state;

  @override
  MediaSnapshot get snapshot => _snapshot;

  @override
  Stream<MediaSessionState> get states => _stateController.stream;

  @override
  Stream<MediaSnapshot> get snapshots => _snapshotController.stream;

  @override
  Stream<MediaEvent> get events => _eventController.stream;

  @override
  MediaConnectionStats? get connectionStats => _connectionStats;

  @override
  Stream<MediaConnectionStats> get stats => _statsController.stream;

  @override
  void setCredentialRefreshCallback(MediaCredentialRefreshCallback? callback) =>
      _credentials.setCredentialRefreshCallback(callback);
  @override
  int dataPayloadSizeBytes(String message, MediaSendOptions options) =>
      _data.dataPayloadSizeBytes(message, options);
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
    final current = _joinFuture;
    if (current != null) {
      if (_leaveRequestedDuringJoin) {
        return Future.error(
          RealtimeException(
            code: RealtimeErrorCode.cancelled,
            providerId: providerId,
            message: 'The previous TRTC join is still being cancelled.',
          ),
        );
      }
      return current;
    }
    _leaveRequestedDuringJoin = false;
    late final Future<void> future;
    future = _join(joinInfo).whenComplete(() {
      if (identical(_joinFuture, future)) _joinFuture = null;
    });
    _joinFuture = future;
    return future;
  }

  Future<void> _join(MediaJoinInfo rawInfo) async {
    _ensureNotDisposed();
    if (state != MediaSessionState.idle &&
        state != MediaSessionState.ended &&
        state != MediaSessionState.failed) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'This TRTC session is already joining or active.',
        providerId: providerId,
      );
    }
    if (rawInfo is! TrtcJoinInfo ||
        rawInfo.providerId != providerId ||
        rawInfo.role != role ||
        rawInfo.participantId != rawInfo.userId) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Join information does not match this TRTC session.',
        providerId: providerId,
      );
    }
    if (_activeTrtcSession != null && !identical(_activeTrtcSession, this)) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'Another TRTC session is already using the native engine.',
        providerId: providerId,
      );
    }
    _connectionGeneration++;
    _activeTrtcSession = this;
    _joinInfo = rawInfo;
    _setState(MediaSessionState.joining);
    try {
      var refreshedOnJoin = false;
      while (true) {
        try {
          await _enterRoom(_joinInfo!);
          if (_leaveRequestedDuringJoin || _disposed) {
            throw RealtimeException(
              code: RealtimeErrorCode.cancelled,
              providerId: providerId,
              message: 'The TRTC join was cancelled.',
            );
          }
          break;
        } on RealtimeException catch (error) {
          if (refreshedOnJoin ||
              !_isCredentialError(error) ||
              _credentials._refreshCallback == null) {
            rethrow;
          }
          refreshedOnJoin = true;
          await _exitCloudRoom();
          _joinInfo = await _credentials._refreshCredentials(_joinInfo!);
        }
      }
      // Microphone capture is deliberately lazy. The participant explicitly
      // unmutes via InteractiveMediaSession.setMuted(false).
      _setSnapshot(
        _snapshot.copyWith(
          participants: [
            MediaParticipant(
              id: _joinInfo!.userId,
              displayName: _joinInfo!.displayName,
              isLocal: true,
              isMuted: role.canPublishMedia,
            ),
          ],
          localParticipantId: _joinInfo!.userId,
          localMuted: role.canPublishMedia,
          localVideoEnabled: false,
          clearLastError: true,
        ),
      );
      _setState(MediaSessionState.connected);
      _credentials._scheduleCredentialRefresh();
    } catch (error, stack) {
      final cancelled = _leaveRequestedDuringJoin || _disposed;
      final mapped = cancelled
          ? RealtimeException(
              code: RealtimeErrorCode.cancelled,
              providerId: providerId,
              message: 'The TRTC join was cancelled.',
              cause: error,
            )
          : _mapError(error, 'join', stack: stack);
      await _releaseCloud();
      if (identical(_activeTrtcSession, this)) _activeTrtcSession = null;
      if (!cancelled) _setState(MediaSessionState.failed, error: mapped);
      throw mapped;
    }
  }

  Future<void> _enterRoom(TrtcJoinInfo info) async {
    _engine ??= await _engineFactory();
    if (_leaveRequestedDuringJoin || _disposed) {
      throw RealtimeException(
        code: RealtimeErrorCode.cancelled,
        providerId: providerId,
        message: 'The TRTC join was cancelled.',
      );
    }
    _setState(
      state == MediaSessionState.reconnecting
          ? MediaSessionState.reconnecting
          : MediaSessionState.connecting,
    );
    _enterRequested = true;
    final result = await _engine!
        .enterRoom(info, _mapper._engineEvents)
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw RealtimeException(
            code: RealtimeErrorCode.timeout,
            message: 'trtc.enterRoom timed out.',
            providerId: providerId,
          ),
        );
    if (result <= 0) {
      throw RealtimeException(
        code: RealtimeErrorCode.providerError,
        message: 'trtc.enterRoom failed.',
        details: {'code': result},
        providerId: providerId,
      );
    }
  }

  Future<void> _exitCloudRoom() async {
    if (_publishing._iosScreenCaptureSource != null) {
      try {
        await _publishing._stopIosScreenCapture();
      } catch (error, stack) {
        _reportFailure(_mapError(error, 'screenShare.ios.stop', stack: stack));
      }
    }
    try {
      await _publishing._processedSink.detach();
    } catch (error, stack) {
      _reportFailure(_mapError(error, 'processedVideo.detach', stack: stack));
    }
    final engine = _engine;
    if (engine == null || !_enterRequested) return;
    try {
      await engine.exitRoom();
    } on TimeoutException {
      // A timeout must not keep the app from releasing the SDK or applying a
      // refreshed credential. The next enter attempt remains the final check.
    } finally {
      _enterRequested = false;
      _publishing._audioStarted = false;
    }
  }

  Future<void> _releaseCloud() async {
    _credentials.cancel();
    try {
      await _exitCloudRoom();
    } finally {
      final engine = _engine;
      _engine = null;
      if (engine != null) await engine.dispose();
    }
  }

  bool _isCredentialError(RealtimeException error) =>
      error.details is Map &&
      (error.details as Map)['code'] == _userSigCheckFailed;

  bool _isUserSigFailure(int code, String message) =>
      code == _userSigCheckFailed ||
      (message.toLowerCase().contains('usersig') &&
          (message.toLowerCase().contains('expired') ||
              message.toLowerCase().contains('过期')));

  RealtimeException _mapError(Object error, String stage, {StackTrace? stack}) {
    final typed = error is RealtimeException ? error : null;
    return normalizeRealtimeException(
      RealtimeException(
        code:
            (typed?.code == RealtimeErrorCode.unknown ? null : typed?.code) ??
            (error is TimeoutException
                ? RealtimeErrorCode.timeout
                : RealtimeErrorCode.providerError),
        message: 'trtc.$stage failed.',
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

  void _reportFailure(RealtimeException error) {
    _setSnapshot(_snapshot.copyWith(lastError: error));
    _eventController.add(MediaFailureEvent(error));
  }

  void _setState(MediaSessionState value, {RealtimeException? error}) {
    if (_snapshot.state == value && error == null) return;
    final previous = _snapshot.state;
    _setSnapshot(_snapshot.copyWith(state: value, lastError: error));
    if (previous != value) {
      if (!_stateController.isClosed) _stateController.add(value);
      _eventController.add(
        MediaConnectionStateChanged(previous: previous, current: value),
      );
    }
  }

  void _setSnapshot(MediaSnapshot value) {
    _snapshot = value;
    if (!_snapshotController.isClosed) _snapshotController.add(value);
  }

  void _requireConnected() {
    if (state != MediaSessionState.connected) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'The TRTC session is not connected.',
        providerId: providerId,
      );
    }
  }

  void _ensureNotDisposed() {
    if (_disposed || _disposing) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'The TRTC session has been disposed.',
        providerId: providerId,
      );
    }
  }

  @override
  Future<void> leave() {
    final current = _leaveFuture;
    if (current != null) return current;
    late final Future<void> future;
    future = _leave().whenComplete(() {
      if (identical(_leaveFuture, future)) _leaveFuture = null;
    });
    _leaveFuture = future;
    return future;
  }

  Future<void> _leave() async {
    _connectionGeneration++;
    if (_disposed) return;
    final joining = _joinFuture;
    if (joining != null) {
      _leaveRequestedDuringJoin = true;
      // A native enterRoom can be unresponsive until its provider timeout.
      // Release immediately and reject any later completion in _join.
      await _releaseCloud();
      if (identical(_activeTrtcSession, this)) _activeTrtcSession = null;
      _setState(MediaSessionState.ended);
      return;
    }
    if (state == MediaSessionState.ended || state == MediaSessionState.idle) {
      _setState(MediaSessionState.ended);
      if (identical(_activeTrtcSession, this)) _activeTrtcSession = null;
      return;
    }
    _setState(MediaSessionState.leaving);
    _credentials.cancel();
    await _releaseCloud();
    if (identical(_activeTrtcSession, this)) _activeTrtcSession = null;
    _setSnapshot(
      _snapshot.copyWith(
        participants: const [],
        clearLocalParticipantId: true,
        localVideoEnabled: false,
        localScreenShareEnabled: false,
        clearContentShareTrack: true,
      ),
    );
    _setState(MediaSessionState.ended);
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _connectionGeneration++;
    _disposing = true;
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run('trtc.leave', leave);
    _disposed = true;
    await cleanup.run('credentials', _credentials.dispose);
    _setState(MediaSessionState.disposed);
    await cleanup.run('states', _stateController.close);
    await cleanup.run('snapshots', _snapshotController.close);
    await cleanup.run('events', _eventController.close);
    await cleanup.run('stats', _statsController.close);
    cleanup.finish(domain: providerId);
  }
}
