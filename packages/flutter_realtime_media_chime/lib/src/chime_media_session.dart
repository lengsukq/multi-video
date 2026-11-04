import 'package:flutter_realtime_processed_video/flutter_realtime_processed_video.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_aws_chime/flutter_aws_chime.dart' as chime;
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'chime_join_info.dart';
import 'chime_media_track.dart';

part 'chime_media_controls.dart';
part 'chime_snapshot_mapper.dart';

MediaCapabilities get _chimeCapabilities => MediaCapabilities(
  canPublishAudio: true,
  canPublishVideo: true,
  canScreenShare: !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS,
  canSwitchCamera: defaultTargetPlatform != TargetPlatform.macOS,
  canSendData: true,
  canReceiveData: true,
  canSubscribeVideo: true,
  canEnumerateAudioDevices: true,
  canSelectAudioOutput: true,
  maxDataMessageBytes: 2048,
);

/// Adapts the existing [chime.ChimeMeetingSession] without changing its native bridge.
class ChimeMediaSession
    implements
        InteractiveMediaSession,
        MediaDeviceController,
        ProcessedVideoSink {
  ChimeMediaSession({chime.ChimeMeetingSession? session})
    : _session = session ?? chime.ChimeMeetingSession();

  final chime.ChimeMeetingSession _session;
  final _stateController = StreamController<MediaSessionState>.broadcast();
  final _snapshotController = StreamController<MediaSnapshot>.broadcast();
  final _eventController = StreamController<MediaEvent>.broadcast();

  StreamSubscription<chime.MeetingSnapshot>? _snapshotSubscription;
  StreamSubscription<chime.ChimeEvent>? _eventSubscription;
  MediaSnapshot _snapshot = MediaSnapshot(
    role: MediaRole.participant,
    capabilities: _chimeCapabilities,
  );
  bool _disposed = false;
  Duration cleanupTimeout = const Duration(seconds: 10);
  Future<void>? _joinFuture;
  bool _joinCancelled = false;
  Future<void>? _leaveFuture;
  Future<void>? _disposeFuture;

  /// Existing provider session for advanced Chime-specific integrations.
  chime.ChimeMeetingSession get chimeSession => _session;

  void _ensureJoinNotCancelled() {
    if (_joinCancelled || _disposed) {
      throw RealtimeException(
        code: RealtimeErrorCode.cancelled,
        providerId: providerId,
        message: 'The Chime join was cancelled.',
      );
    }
  }

  late final _controls = _ChimeMediaControls(this);
  late final _mapper = _ChimeSnapshotMapper(this);

  @override
  String get providerId => ChimeJoinInfo.providerIdValue;

  @override
  MediaRole get role => MediaRole.participant;

  @override
  MediaCapabilities get capabilities => _chimeCapabilities.copyWith(
    canBlurBackground:
        _chimeCapabilities.canPublishVideo && _controls._effectsPlatform,
    canReplaceBackgroundImage:
        _chimeCapabilities.canPublishVideo && _controls._effectsPlatform,
    canEnumerateCameras: _controls._effectsPlatform,
    canSelectCamera: _controls._effectsPlatform,
  );

  @override
  MediaSessionState get state => _snapshot.state;

  @override
  MediaSnapshot get snapshot => _snapshot.copyWith(capabilities: capabilities);

  @override
  Stream<MediaSessionState> get states => _stateController.stream;

  @override
  Stream<MediaSnapshot> get snapshots => _snapshotController.stream;

  @override
  Stream<MediaEvent> get events => _eventController.stream;

  @override
  bool supportsProcessedVideoSource(ProcessedVideoSource source) =>
      _controls.supportsProcessedVideoSource(source);
  @override
  Future<void> attachProcessedVideoSource(ProcessedVideoSource source) =>
      _controls.attachProcessedVideoSource(source);
  @override
  Future<void> detachProcessedVideoSource() =>
      _controls.detachProcessedVideoSource();
  @override
  Future<List<MediaDevice>> listMediaDevices({Set<MediaDeviceKind>? kinds}) =>
      _controls.listMediaDevices(kinds: kinds);
  @override
  Future<void> selectMediaDevice(MediaDevice device) =>
      _controls.selectMediaDevice(device);
  @override
  Future<void> setMuted(bool muted) => _controls.setMuted(muted);
  @override
  Future<void> toggleMute() => _controls.toggleMute();
  @override
  Future<void> setVideoEnabled(bool enabled) =>
      _controls.setVideoEnabled(enabled);
  @override
  Future<void> setScreenShareEnabled(bool enabled) =>
      _controls.setScreenShareEnabled(enabled);
  @override
  Future<void> switchCamera(MediaCameraPosition position) =>
      _controls.switchCamera(position);
  @override
  Future<List<MediaAudioDevice>> listAudioDevices() =>
      _controls.listAudioDevices();
  @override
  Future<void> selectAudioDevice(MediaAudioDevice device) =>
      _controls.selectAudioDevice(device);
  @override
  Future<void> sendMessage(String message, {String topic = 'chat'}) =>
      _controls.sendMessage(message, topic: topic);

  @override
  Future<void> join(MediaJoinInfo joinInfo) {
    final current = _joinFuture;
    if (current != null) return current;
    _joinCancelled = false;
    late final Future<void> future;
    future = _join(joinInfo).whenComplete(() {
      if (identical(_joinFuture, future)) _joinFuture = null;
    });
    _joinFuture = future;
    return future;
  }

  Future<void> _join(MediaJoinInfo rawJoinInfo) async {
    _ensureNotDisposed();
    if (rawJoinInfo is! ChimeJoinInfo || rawJoinInfo.role != role) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Join information does not match this Chime session.',
        providerId: ChimeJoinInfo.providerIdValue,
      );
    }
    if (state != MediaSessionState.idle &&
        state != MediaSessionState.ended &&
        state != MediaSessionState.failed) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'This Chime session is already joining or active.',
        providerId: ChimeJoinInfo.providerIdValue,
      );
    }

    _attachProviderStreams();
    try {
      await _session.join(rawJoinInfo.chimeJoinInfo);
      _ensureJoinNotCancelled();
      await _controls._probeProcessedVideoInput();
      _ensureJoinNotCancelled();
      _mapper._onProviderSnapshot(_session.snapshot, clearLastError: true);
    } on chime.RealtimeException catch (error, stack) {
      if (_joinCancelled || _disposed) rethrow;
      final mapped = _mapError(error, stage: 'join', stack: stack);
      _replaceSnapshot(_snapshot.copyWith(lastError: mapped));
      _emit(MediaFailureEvent(mapped));
      throw mapped;
    } catch (error, stack) {
      if (_joinCancelled || _disposed) {
        throw RealtimeException(
          code: RealtimeErrorCode.cancelled,
          providerId: providerId,
          message: 'The Chime join was cancelled.',
          cause: error,
        );
      }
      final mapped = RealtimeException(
        code: error is TimeoutException
            ? RealtimeErrorCode.timeout
            : RealtimeErrorCode.providerError,
        message: 'chime.join failed.',
        operation: 'join',
        domain: 'media',
        cause: error,
        stackTrace: stack,
        providerId: providerId,
      );
      _replaceSnapshot(_snapshot.copyWith(lastError: mapped));
      _emit(MediaFailureEvent(mapped));
      throw mapped;
    }
  }

  void _attachProviderStreams() {
    _snapshotSubscription ??= _session.snapshots.listen(
      _mapper._onProviderSnapshot,
    );
    _eventSubscription ??= _session.events.listen(_mapper._onProviderEvent);
    _mapper._onProviderSnapshot(_session.snapshot);
  }

  @override
  Future<void> leave() => _leaveFuture ??= _leave().whenComplete(() {
    _leaveFuture = null;
  });

  Future<void> _leave() async {
    if (_disposed ||
        state == MediaSessionState.disposed ||
        state == MediaSessionState.ended ||
        (state == MediaSessionState.idle && _joinFuture == null)) {
      return;
    }
    if (_joinFuture != null) _joinCancelled = true;
    try {
      try {
        await _controls._stopIosSystemScreenCapture();
        await _controls.detachProcessedVideoSource();
      } finally {
        await _session.leave();
      }
      _mapper._onProviderSnapshot(_session.snapshot);
    } on chime.RealtimeException catch (error, stack) {
      throw _mapError(error, stage: 'leave', stack: stack);
    }
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _joinCancelled = true;
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run('processedVideo', () async {
      await _controls.detachProcessedVideoSource();
    });
    await cleanup.run('screenCapture', _controls._stopIosSystemScreenCapture);
    await cleanup.run('session', () async {
      await _session.dispose();
    });
    await cleanup.run('snapshot.subscription', () async {
      await _snapshotSubscription?.cancel();
    });
    await cleanup.run('event.subscription', () async {
      await _eventSubscription?.cancel();
    });
    await cleanup.run('terminal', () async {
      _transition(MediaSessionState.disposed);
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
    cleanup.finish(domain: providerId);
  }

  void _transition(MediaSessionState next) {
    if (_snapshot.state == next) return;
    final previous = _snapshot.state;
    _replaceSnapshot(_snapshot.copyWith(state: next));
    if (!_stateController.isClosed) _stateController.add(next);
    _emit(MediaConnectionStateChanged(previous: previous, current: next));
  }

  void _replaceSnapshot(MediaSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_disposed && !_snapshotController.isClosed) {
      _snapshotController.add(snapshot);
    }
  }

  void _emit(MediaEvent event) {
    if (!_disposed && !_eventController.isClosed) _eventController.add(event);
  }

  void _ensureNotDisposed() {
    if (_disposed || state == MediaSessionState.disposed) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'This Chime adapter session has been disposed.',
        providerId: providerId,
      );
    }
  }

  void _ensureActive() {
    _ensureNotDisposed();
    if (!state.isActive) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'The Chime session is not active.',
        providerId: providerId,
      );
    }
  }
}

MediaSessionState _mapState(chime.MeetingState state) => switch (state) {
  chime.MeetingState.idle => MediaSessionState.idle,
  chime.MeetingState.joining => MediaSessionState.joining,
  chime.MeetingState.connecting => MediaSessionState.connecting,
  chime.MeetingState.connected => MediaSessionState.connected,
  chime.MeetingState.reconnecting => MediaSessionState.reconnecting,
  chime.MeetingState.leaving => MediaSessionState.leaving,
  chime.MeetingState.ended => MediaSessionState.ended,
  chime.MeetingState.failed => MediaSessionState.failed,
  chime.MeetingState.disposed => MediaSessionState.disposed,
};

MediaAudioDevice _mapAudioDevice(chime.ChimeAudioDevice device) =>
    MediaAudioDevice(
      label: device.label,
      type: switch (device.type) {
        chime.ChimeAudioDeviceType.bluetooth => MediaAudioDeviceType.bluetooth,
        chime.ChimeAudioDeviceType.wiredHeadset =>
          MediaAudioDeviceType.wiredHeadset,
        chime.ChimeAudioDeviceType.speaker => MediaAudioDeviceType.speaker,
        chime.ChimeAudioDeviceType.earpiece => MediaAudioDeviceType.earpiece,
        chime.ChimeAudioDeviceType.other => MediaAudioDeviceType.other,
      },
    );

RealtimeException _mapError(
  chime.RealtimeException error, {
  String stage = 'provider',
  StackTrace? stack,
}) => normalizeRealtimeException(
  RealtimeException(
    code: error.code == RealtimeErrorCode.unknown
        ? RealtimeErrorCode.providerError
        : error.code,
    message: 'chime.$stage failed.',
    providerId: 'chime',
    domain: 'media',
    operation: stage,
    cause: error.cause ?? error,
    details: error.details,
    statusCode: error.statusCode,
    recoverable: error.recoverable,
    suggestedAction: error.suggestedAction,
    stackTrace: stack ?? error.stackTrace,
  ),
  domain: 'media',
  operation: stage,
  providerId: 'chime',
  stackTrace: stack,
);
