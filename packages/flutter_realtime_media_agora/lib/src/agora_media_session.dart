import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agora_rtc_engine/agora_rtc_engine.dart' as agora;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'agora_join_info.dart';
import 'package:flutter_realtime_processed_video/flutter_realtime_processed_video.dart';
import 'agora_media_track.dart';
import 'agora_screen_capture.dart';
import 'agora_screen_share_signals.dart';

part 'agora_publishing.dart';
part 'agora_data_stream.dart';
part 'agora_snapshot_mapper.dart';
part 'agora_event_adapter.dart';

part 'agora_interactive_session.dart';

part 'agora_host_session.dart';

part 'agora_viewer_session.dart';

part 'agora_capabilities.dart';

part 'agora_failures.dart';

abstract class _AgoraMediaSession
    implements
        MediaSession,
        MediaDataMessenger,
        MediaDataPayloadSizer,
        MediaStatsProvider,
        ProcessedVideoSink,
        MediaDeviceController {
  _AgoraMediaSession(this.role, {agora.RtcEngine Function()? engineFactory})
    : _engineFactory = engineFactory ?? agora.createAgoraRtcEngine,
      _capabilities = _capabilitiesForRole(role),
      _snapshot = MediaSnapshot(
        role: role,
        capabilities: _capabilitiesForRole(role),
      );
  late final _failures = _AgoraFailures(providerId);
  late final _publishing = _AgoraPublishing(this);
  late final _data = _AgoraDataStream(this);
  late final _mapper = _AgoraSnapshotMapper(this);
  late final _eventAdapter = _AgoraEventAdapter(this);

  @override
  final MediaRole role;

  final StreamController<MediaSessionState> _stateController =
      StreamController<MediaSessionState>.broadcast();
  final StreamController<MediaSnapshot> _snapshotController =
      StreamController<MediaSnapshot>.broadcast();
  final StreamController<MediaEvent> _eventController =
      StreamController<MediaEvent>.broadcast();
  final StreamController<MediaConnectionStats> _statsController =
      StreamController<MediaConnectionStats>.broadcast();

  final MediaCapabilities _capabilities;
  MediaSnapshot _snapshot;
  MediaSessionState _state = MediaSessionState.idle;
  final agora.RtcEngine Function() _engineFactory;
  agora.RtcEngine? _engine;
  agora.RtcEngineEventHandler? _eventHandler;
  AgoraJoinInfo? _joinInfo;
  Completer<void>? _joinCompleter;
  Future<void>? _joinFuture;
  Future<void>? _leaveFuture;
  Future<void>? _disposeFuture;
  int? _localUid;
  bool _disposed = false;
  bool _joinCancelled = false;
  Duration cleanupTimeout = const Duration(seconds: 10);
  MediaConnectionStats? _connectionStats;

  @override
  String get providerId => _agoraProviderId;

  @override
  MediaCapabilities get capabilities => _capabilities;

  @override
  MediaSessionState get state => _state;

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
  int dataPayloadSizeBytes(String message, MediaSendOptions options) =>
      _data.dataPayloadSizeBytes(message, options);
  @override
  Future<void> sendMessage(String message, {String topic = 'chat'}) =>
      _data.sendMessage(message, topic: topic);

  Future<void> setMutedInternal(bool muted) =>
      _publishing.setMutedInternal(muted);
  Future<void> toggleMuteInternal() => _publishing.toggleMuteInternal();
  Future<void> setVideoEnabledInternal(bool enabled) =>
      _publishing.setVideoEnabledInternal(enabled);
  Future<void> switchCameraInternal(MediaCameraPosition position) =>
      _publishing.switchCameraInternal(position);
  Future<void> setScreenShareEnabledInternal(bool enabled) =>
      _publishing.setScreenShareEnabledInternal(enabled);
  Future<List<MediaAudioDevice>> listAudioDevicesInternal() =>
      _publishing.listAudioDevicesInternal();
  Future<void> selectAudioDeviceInternal(MediaAudioDevice device) =>
      _publishing.selectAudioDeviceInternal(device);

  bool get _canPublish => role != MediaRole.viewer;

  @override
  Future<void> join(MediaJoinInfo joinInfo) =>
      _joinFuture ??= _join(joinInfo).whenComplete(() {
        _joinFuture = null;
      });

  Future<void> _join(MediaJoinInfo rawJoinInfo) async {
    _ensureNotDisposed();
    _joinCancelled = false;
    if (rawJoinInfo is! AgoraJoinInfo) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Agora session requires AgoraJoinInfo.',
        providerId: _agoraProviderId,
      );
    }
    if (rawJoinInfo.role != role) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message:
            'Agora session role ${role.wireName} does not match join role '
            '${rawJoinInfo.role.wireName}.',
        providerId: providerId,
      );
    }
    if (_state.isActive ||
        _state == MediaSessionState.joining ||
        _state == MediaSessionState.leaving) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'Agora session is already active or changing state.',
        providerId: providerId,
      );
    }

    _joinInfo = rawJoinInfo;
    _publishing._localMuted = true;
    _publishing._localVideoEnabled = false;
    _publishing._localScreenShareEnabled = false;
    _publishing._localScreenTrack = null;
    _publishing._cameraPosition = MediaCameraPosition.front;
    _mapper._participants.clear();
    _data._messages.clear();
    _mapper._remoteScreenState.clear();
    _mapper._remoteScreenTracks.clear();
    _mapper._activeSpeakerUid = null;
    _data._dataStreamId = null;
    _setState(MediaSessionState.joining);

    final engine = _engineFactory();
    _engine = engine;
    final completer = Completer<void>();
    _joinCompleter = completer;

    try {
      if (_disposed) {
        throw const RealtimeException(
          code: RealtimeErrorCode.cancelled,
          message: 'Session is closing.',
        );
      }
      await engine.initialize(
        agora.RtcEngineContext(
          appId: rawJoinInfo.appId,
          channelProfile:
              agora.ChannelProfileType.channelProfileLiveBroadcasting,
        ),
      );
      _ensureJoinNotCancelled();
      final handler = _eventAdapter._buildEventHandler();
      _eventHandler = handler;
      engine.registerEventHandler(handler);
      await engine.enableAudio();
      _ensureJoinNotCancelled();
      await engine.enableVideo();
      _ensureJoinNotCancelled();
      await engine.enableAudioVolumeIndication(
        interval: 250,
        smooth: 3,
        reportVad: true,
      );

      _setState(MediaSessionState.connecting);
      await engine.joinChannel(
        token: rawJoinInfo.token,
        channelId: rawJoinInfo.channelName,
        uid: rawJoinInfo.uid,
        options: _publishing._channelOptions(),
      );
      _ensureJoinNotCancelled();

      await completer.future.timeout(const Duration(seconds: 20));
      _ensureJoinNotCancelled();
      _refreshSnapshot(clearLastError: true);
      if (_state != MediaSessionState.connected) {
        _setState(MediaSessionState.connected);
      }
    } on RealtimeException catch (error, stack) {
      await _rollbackJoin(error, stack);
    } catch (error, stack) {
      final mapped = _mapError(error, 'join', stack: stack);
      await _rollbackJoin(mapped, stack);
    } finally {
      _joinCompleter = null;
    }
  }

  void _ensureJoinNotCancelled() {
    if (_disposed || _joinCancelled) {
      throw RealtimeException(
        code: RealtimeErrorCode.cancelled,
        message: 'The Agora join was cancelled.',
        providerId: providerId,
      );
    }
  }

  @override
  Future<void> leave() => _leaveFuture ??= _leave().whenComplete(() {
    _leaveFuture = null;
  });

  Future<void> _leave() async {
    if (_disposed || _state == MediaSessionState.disposed) return;
    if (_joinFuture != null) {
      _joinCancelled = true;
      final pending = _joinCompleter;
      if (pending != null && !pending.isCompleted) pending.complete();
    }
    if (_state == MediaSessionState.idle ||
        _state == MediaSessionState.ended ||
        _state == MediaSessionState.failed) {
      if (_state != MediaSessionState.ended) {
        _setState(MediaSessionState.ended);
      }
      await _tearDownEngine();
      return;
    }
    _setState(MediaSessionState.leaving);
    final engine = _engine;
    if (engine != null) {
      try {
        await engine.leaveChannel();
      } catch (error, stack) {
        if (!_joinCancelled) {
          _reportFailure(_mapError(error, 'leave', stack: stack));
        }
      }
    }
    await _tearDownEngine();
    _mapper._participants.clear();
    _data._messages.clear();
    _localUid = null;
    _data._dataStreamId = null;
    _refreshSnapshot();
    _setState(MediaSessionState.ended);
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _joinCancelled = true;
    final pending = _joinCompleter;
    if (pending != null && !pending.isCompleted) pending.complete();
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run('join.pending', () async {
      try {
        await _joinFuture;
      } catch (_) {
        /* The join caller receives its failure. */
      }
    });
    await cleanup.run('engine', () async {
      await _tearDownEngine();
    });
    await cleanup.run('terminal', () async {
      _setState(MediaSessionState.disposed);
    });
    await cleanup.run('states', () async {
      await _stateController.close();
    });
    await cleanup.run('snapshots', () async {
      await _snapshotController.close();
    });
    await cleanup.run('events', () async {
      await _eventController.close();
    });
    await cleanup.run('stats', () async {
      await _statsController.close();
    });
    cleanup.finish(domain: providerId);
  }

  Future<Never> _rollbackJoin(
    RealtimeException primary,
    StackTrace stack,
  ) async {
    final cancelled = _disposed || _joinCancelled;
    final error = cancelled
        ? RealtimeException(
            code: RealtimeErrorCode.cancelled,
            message: 'The Agora join was cancelled.',
            providerId: providerId,
            cause: primary,
          )
        : primary;
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run('join.rollback', _tearDownEngine);
    if (!cancelled) _setState(MediaSessionState.failed, error: error);
    cleanup.finish(domain: providerId, cause: error);
    Error.throwWithStackTrace(error, stack);
  }

  Future<void> _tearDownEngine() async {
    final engine = _engine;
    final handler = _eventHandler;
    final customTrackId = _publishing._customVideoTrackId;
    final hadScreenCapture = _publishing._localScreenShareEnabled;
    final hadIosScreenCapture = _publishing._iosScreenCaptureSource != null;
    _publishing._localScreenShareEnabled = false;
    _publishing._localScreenTrack = null;
    _engine = null;
    _eventHandler = null;
    _publishing._customVideoTrackId = null;
    _data._dataStreamId = null;
    _data._dataStreamFuture = null;
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run('processed.input', _publishing._processedSink.detach);
    if (engine != null) {
      if (hadIosScreenCapture) {
        await cleanup.run(
          'screenCapture.ios',
          () => _publishing._stopIosScreenCapture(engine),
        );
      } else if (hadScreenCapture) {
        await cleanup.run('engine.stopScreenCapture', engine.stopScreenCapture);
      }
      if (handler != null) {
        await cleanup.run(
          'engine.events',
          () => engine.unregisterEventHandler(handler),
        );
      }
      if (customTrackId != null) {
        await cleanup.run(
          'engine.customTrack',
          () => engine.destroyCustomVideoTrack(customTrackId),
        );
      }
      await cleanup.run('engine.release', engine.release);
    }
    cleanup.finish(domain: providerId);
  }

  agora.RtcEngine _requireEngine() {
    final engine = _engine;
    if (engine == null) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'The Agora engine is unavailable.',
        providerId: providerId,
      );
    }
    return engine;
  }

  void _ensureActive() {
    _ensureNotDisposed();
    if (!_state.isActive) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'The Agora session is not active.',
        providerId: providerId,
      );
    }
  }

  void _ensureNotDisposed() {
    if (_disposed || _state == MediaSessionState.disposed) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'The Agora session has been disposed.',
        providerId: providerId,
      );
    }
  }

  void _refreshSnapshot({
    RealtimeException? error,
    bool clearLastError = false,
  }) {
    if (_disposed) return;
    _snapshot = _snapshot.copyWith(
      state: _state,
      role: role,
      participants: _mapper._participants.values.toList(growable: false),
      messages: List<MediaMessage>.unmodifiable(_data._messages),
      localParticipantId: _localUid?.toString(),
      clearLocalParticipantId: _localUid == null,
      localMuted: _publishing._localMuted,
      localVideoEnabled: _publishing._localVideoEnabled,
      localScreenShareEnabled: _publishing._localScreenShareEnabled,
      contentShareTrack:
          _mapper._remoteScreenTracks.values.lastOrNull ??
          _publishing._localScreenTrack,
      clearContentShareTrack:
          _mapper._remoteScreenTracks.isEmpty &&
          _publishing._localScreenTrack == null,
      capabilities: _capabilities,
      lastError: error,
      clearLastError: clearLastError,
    );
    if (!_snapshotController.isClosed) {
      _snapshotController.add(_snapshot);
    }
  }

  void _setState(
    MediaSessionState next, {
    String? reason,
    RealtimeException? error,
  }) {
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
    _refreshSnapshot(error: error);
    if (!_stateController.isClosed) _stateController.add(next);
    _emit(
      MediaConnectionStateChanged(
        previous: previous,
        current: next,
        reason: reason,
      ),
    );
  }

  void _reportFailure(RealtimeException error) {
    _refreshSnapshot(error: error);
    _emit(MediaFailureEvent(error));
  }

  void _emit(MediaEvent event) {
    if (!_disposed && !_eventController.isClosed) _eventController.add(event);
  }

  RealtimeException _mapError(
    Object error,
    String stage, {
    StackTrace? stack,
  }) => _failures.map(error, stage, stack: stack);
}
