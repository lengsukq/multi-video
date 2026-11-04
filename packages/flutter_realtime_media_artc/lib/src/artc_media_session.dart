import 'package:flutter_realtime_processed_video/flutter_realtime_processed_video.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'artc_engine.dart';
import 'artc_join_info.dart';
import 'artc_media_track.dart';

part 'artc_publishing.dart';
part 'artc_credential_refresh.dart';
part 'artc_data_messenger.dart';
part 'artc_snapshot_mapper.dart';

part 'artc_participant_session.dart';

part 'artc_broadcast_host_session.dart';

part 'artc_broadcast_viewer_session.dart';

_ArtcMediaSession? _activeArtcSession;

typedef ArtcSessionEngineFactory = Future<ArtcEngine> Function();

abstract class _ArtcMediaSession
    implements
        MediaSession,
        MediaCredentialRefreshable,
        MediaDataPayloadSizer,
        ProcessedVideoSink,
        MediaDeviceController {
  _ArtcMediaSession({required this.role, required this.engineFactory});

  final ArtcSessionEngineFactory engineFactory;
  final StreamController<MediaSessionState> _states =
      StreamController<MediaSessionState>.broadcast();
  final StreamController<MediaSnapshot> _snapshots =
      StreamController<MediaSnapshot>.broadcast();
  final StreamController<MediaEvent> _events =
      StreamController<MediaEvent>.broadcast();

  ArtcEngine? _engine;
  ArtcJoinInfo? _joinInfo;
  MediaSessionState _state = MediaSessionState.idle;
  MediaCapabilities _capabilities = const MediaCapabilities.none();
  late MediaSnapshot _snapshot = MediaSnapshot(role: role);
  bool _disposed = false;
  bool _joinCancelled = false;
  int _connectionGeneration = 0;
  Future<void>? _joinFuture;
  Future<void>? _disposeFuture;
  Duration cleanupTimeout = const Duration(seconds: 10);

  late final _publishing = _ArtcPublishing(this);
  late final _credentials = _ArtcCredentialRefresh(this);
  late final _data = _ArtcDataMessenger(this);
  late final _mapper = _ArtcSnapshotMapper(this);

  @override
  final MediaRole role;

  @override
  String get providerId => ArtcJoinInfo.providerIdValue;

  @override
  MediaCapabilities get capabilities => _capabilities.copyWith(
    canBlurBackground:
        _capabilities.canPublishVideo && _publishing._effectsPlatform,
    canReplaceBackgroundImage:
        _capabilities.canPublishVideo && _publishing._effectsPlatform,
    canEnumerateCameras:
        _capabilities.canPublishVideo && _publishing._effectsPlatform,
    canSelectCamera:
        _capabilities.canPublishVideo && _publishing._effectsPlatform,
  );

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
    if (_joinFuture != null) {
      return Future.error(
        _error(
          RealtimeErrorCode.invalidState,
          'An ARTC join is already in progress.',
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
        'An ARTC session cannot join after dispose.',
      );
    }
    if (_state == MediaSessionState.joining || _state.isActive) {
      throw _error(
        RealtimeErrorCode.invalidState,
        'This ARTC session is already joining or active.',
      );
    }
    if (joinInfo is! ArtcJoinInfo ||
        joinInfo.providerId != providerId ||
        joinInfo.role != role ||
        joinInfo.participantId != joinInfo.userId) {
      throw _error(
        RealtimeErrorCode.invalidArgument,
        'ARTC join information does not match this session.',
      );
    }
    if (_activeArtcSession != null && !identical(_activeArtcSession, this)) {
      throw _error(
        RealtimeErrorCode.invalidState,
        'ARTC supports one active engine session per app process.',
      );
    }

    _connectionGeneration++;
    _activeArtcSession = this;
    _joinInfo = joinInfo;
    _capabilities = switch (role) {
      MediaRole.participant => const MediaCapabilities(
        canPublishAudio: true,
        canPublishVideo: true,
        canSwitchCamera: false,
        canSendData: true,
        canReceiveData: true,
        canSubscribeVideo: true,
        maxDataMessageBytes: 1024,
      ),
      MediaRole.host => const MediaCapabilities(
        canPublishAudio: true,
        canPublishVideo: true,
        canSwitchCamera: false,
        canSendData: true,
        canReceiveData: true,
        canSubscribeVideo: true,
        maxDataMessageBytes: 1024,
        canListParticipants: true,
        canCloseRoom: true,
      ),
      MediaRole.viewer => const MediaCapabilities.broadcastViewer(
        canSendData: false,
      ),
    };
    if (role != MediaRole.viewer &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      _capabilities = _capabilities.copyWith(canSwitchCamera: true);
    }
    if (role != MediaRole.viewer &&
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      _capabilities = _capabilities.copyWith(canScreenShare: true);
    }
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
        id: joinInfo.userId,
        displayName: joinInfo.displayName.isEmpty
            ? joinInfo.userId
            : joinInfo.displayName,
        isLocal: true,
        isMuted: role != MediaRole.viewer,
      );
      _setSnapshot(
        _snapshot.copyWith(
          participants: [local],
          localParticipantId: joinInfo.userId,
          localMuted: role != MediaRole.viewer,
          localVideoEnabled: false,
          localScreenShareEnabled: false,
          capabilities: capabilities,
          clearLastError: true,
        ),
      );
      _setState(MediaSessionState.connected);
      _credentials._scheduleCredentialRefresh();
    } catch (error, stack) {
      final cancelled = _disposed || _joinCancelled;
      final mapped = cancelled
          ? _error(RealtimeErrorCode.cancelled, 'artc.join cancelled.')
          : _mapError(error, 'join', stack: stack);
      final cleanup = Cleanup(timeout: cleanupTimeout);
      if (!cancelled) {
        await cleanup.run('rollback.leave', () => _releaseEngine(leave: true));
      }
      await cleanup.run('rollback.dispose', () => _releaseEngine(leave: false));
      if (identical(_activeArtcSession, this)) _activeArtcSession = null;
      if (!cancelled) _setState(MediaSessionState.failed, error: mapped);
      cleanup.finish(domain: providerId, cause: mapped);
      Error.throwWithStackTrace(mapped, stack);
    }
  }

  void _ensureJoinNotCancelled() {
    if (_disposed || _joinCancelled) {
      throw _error(RealtimeErrorCode.cancelled, 'The ARTC join was cancelled.');
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
        _state == MediaSessionState.ended ||
        _state == MediaSessionState.idle) {
      return;
    }
    _credentials.cancel();
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
    if (identical(_activeArtcSession, this)) _activeArtcSession = null;
    _mapper._trackGeneration++;
    _publishing._screenShareEnabled = false;
    _publishing._localScreenTrack = null;
    _mapper._remoteScreens.clear();
    _setSnapshot(
      _snapshot.copyWith(
        participants: const [],
        messages: const [],
        clearLocalParticipantId: true,
        localMuted: true,
        localVideoEnabled: false,
        localScreenShareEnabled: false,
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
      if (identical(_activeArtcSession, this)) _activeArtcSession = null;
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
    cleanup.finish(domain: providerId);
  }

  Future<void> _releaseEngine({required bool leave}) async {
    final engine = _engine;
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run('processed.input', _publishing._processedSink.detach);
    if (_publishing._iosScreenCaptureSource != null) {
      await cleanup.run('screen.ios', _publishing._stopIosSystemScreenCapture);
    }
    if (engine != null) {
      if (_publishing._screenShareEnabled &&
          !(defaultTargetPlatform == TargetPlatform.iOS && !kIsWeb)) {
        await cleanup.run(
          'screen.stop',
          () => engine.setScreenShareEnabled(false),
        );
        _publishing._screenShareEnabled = false;
        _publishing._localScreenTrack = null;
      }
      if (leave) {
        await cleanup.run('engine.leave', engine.leave);
      } else {
        _engine = null;
        await cleanup.run('engine.dispose', engine.dispose);
      }
    }
    cleanup.finish(domain: providerId);
  }

  void _onNativeError(int code, String message) {
    final error = RealtimeException(
      code: RealtimeErrorCode.providerError,
      message: 'artc.nativeEvent failed.',
      domain: 'media',
      operation: 'nativeEvent',
      details: {'code': code, 'message': message},
      providerId: providerId,
    );
    _setSnapshot(_snapshot.copyWith(lastError: error));
    _emit(MediaFailureEvent(error));
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

  RealtimeException _mapError(Object error, String stage, {StackTrace? stack}) {
    final typed = error is RealtimeException ? error : null;
    return normalizeRealtimeException(
      RealtimeException(
        code:
            (typed?.code == RealtimeErrorCode.unknown ? null : typed?.code) ??
            (error is TimeoutException
                ? RealtimeErrorCode.timeout
                : RealtimeErrorCode.providerError),
        message: 'artc.$stage failed.',
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

  void _requireActive() {
    if (!_state.isActive || _engine == null) {
      throw _error(
        RealtimeErrorCode.invalidState,
        'ARTC media controls require an active session.',
      );
    }
  }

  void _requireCapability(bool allowed, String feature) {
    if (!allowed) {
      throw _error(
        RealtimeErrorCode.unsupportedFeature,
        'ARTC $role sessions do not support $feature.',
      );
    }
  }
}
