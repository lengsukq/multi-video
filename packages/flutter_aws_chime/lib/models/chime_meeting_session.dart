import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../src/chime_native_channel.dart';
import 'audio_device.dart';
import 'chime_exception.dart';
import 'join_info.model.dart';
import 'meeting_event.model.dart';
import 'meeting_snapshot.dart';

/// Owns one AWS Chime meeting session for the current Flutter engine.
///
/// Meeting resources are created by your application backend. The client
/// receives [JoinInfo] and uses it only to connect to the media session.
class ChimeMeetingSession {
  ChimeMeetingSession();

  static const String _chatTopic = 'chat';

  final _channel = ChimeNativeChannel.instance;
  final _snapshotController = StreamController<MeetingSnapshot>.broadcast();
  final _stateController = StreamController<MeetingState>.broadcast();
  final _eventController = StreamController<ChimeEvent>.broadcast();

  MeetingSnapshot _snapshot = MeetingSnapshot();
  bool _disposed = false;
  bool _disposing = false;
  bool _reserved = false;
  bool _nativeJoinStarted = false;
  Future<void>? _leaveFuture;
  Duration cleanupTimeout = const Duration(seconds: 10);
  Completer<void>? _joinCompletion;
  Completer<void>? _leaveCompletion;

  /// The latest immutable attendee, media, message, and connection snapshot.
  MeetingSnapshot get snapshot => _snapshot;

  /// The current connection state.
  MeetingState get state => _snapshot.state;

  /// Emits a new snapshot whenever meeting data changes.
  Stream<MeetingSnapshot> get snapshots => _snapshotController.stream;

  /// Emits connection-state changes. Read [snapshot] for the current state.
  Stream<MeetingState> get states => _stateController.stream;

  /// Emits typed Chime SDK events.
  Stream<ChimeEvent> get events => _eventController.stream;

  /// Joins a meeting using short-lived credentials returned by your backend.
  /// On macOS camera and microphone permissions are optional for listening.
  /// The user can grant either permission later without blocking meeting join.
  Future<void> join(JoinInfo joinInfo) async {
    _ensureNotDisposed();
    if (_snapshot.state != MeetingState.idle &&
        _snapshot.state != MeetingState.ended &&
        _snapshot.state != MeetingState.failed) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'This meeting session is already joining or active.',
      );
    }

    try {
      joinInfo.validate();
    } on FormatException catch (error) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: error.message.toString(),
      );
    }

    _channel.reserve(this, _handleNativeCall);
    _reserved = true;
    final localId = joinInfo.attendee.attendeeId;
    _replaceSnapshot(
      MeetingSnapshot(
        localAttendeeId: localId,
        attendees: [
          MeetingAttendee(
            attendeeId: localId,
            externalUserId: joinInfo.attendee.externalUserId,
            isLocal: true,
            isMuted: true,
          ),
        ],
      ),
    );
    _setState(MeetingState.joining);
    final joinCompletion = Completer<void>();
    _joinCompletion = joinCompletion;

    try {
      for (final method in [
        'manageAudioPermissions',
        'manageVideoPermissions',
      ]) {
        try {
          _ensureNotDisposed();
          await _channel.invoke(method);
        } on RealtimeException catch (error) {
          if (error.code != RealtimeErrorCode.permissionDenied) rethrow;
          // Device capture is optional at join time on Android and iOS too.
          // A denied permission must not prevent listening with camera/mic
          // off. The host Pre-Join UI shows the permission and offers a retry
          // or system settings action before the user enables capture.
        }
      }
      _ensureNotDisposed();
      _nativeJoinStarted = true;
      await _channel.invoke('join', joinInfo.toJson());
      _ensureNotDisposed();
      if (_snapshot.state == MeetingState.joining) {
        _setState(MeetingState.connecting);
      }
      try {
        await listAudioDevices();
        final selected = await _channel.invoke('initialAudioSelection');
        if (selected is String) {
          _replaceSnapshot(
            _snapshot.copyWith(
              selectedAudioDevice: ChimeAudioDevice.fromLabel(selected),
            ),
          );
        }
      } on RealtimeException {
        // Device discovery is optional and must not turn a successful join
        // into a failed meeting.
      }
    } catch (error, stack) {
      final primary = normalizeRealtimeException(
        error,
        domain: 'media',
        operation: 'join',
        providerId: 'chime',
        stackTrace: stack,
      );
      if (!_disposing) {
        final cleanup = Cleanup(timeout: cleanupTimeout);
        if (_nativeJoinStarted) {
          await cleanup.run('chime.native.rollback', () async {
            await _channel.invoke('stop');
          });
        }
        _nativeJoinStarted = false;
        _failJoin();
        _releaseChannel();
        cleanup.finish(domain: 'chime', cause: primary);
      }
      Error.throwWithStackTrace(primary, stack);
    } finally {
      if (!joinCompletion.isCompleted) joinCompletion.complete();
      if (identical(_joinCompletion, joinCompletion)) _joinCompletion = null;
    }
  }

  /// Leaves the current meeting. Calling this while idle or after leaving is
  /// safe and does not issue an extra native stop request.
  Future<void> leave() => _leaveFuture ??= _leave().whenComplete(() {
    _leaveFuture = null;
  });

  Future<void> _leave() async {
    _ensureNotDisposed();
    final state = _snapshot.state;
    if (state == MeetingState.idle ||
        state == MeetingState.ended ||
        state == MeetingState.failed) {
      _releaseChannel();
      if (state != MeetingState.ended) _setState(MeetingState.ended);
      return;
    }
    if (state == MeetingState.joining || state == MeetingState.leaving) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'The meeting cannot leave while another transition is active.',
      );
    }

    _setState(MeetingState.leaving);
    final leaveCompletion = Completer<void>();
    _leaveCompletion = leaveCompletion;
    try {
      await _channel.invoke('stop');
      _finishMeeting();
    } on RealtimeException catch (error) {
      if (error.code == RealtimeErrorCode.invalidState) {
        _finishMeeting();
        return;
      }
      if (_snapshot.state == MeetingState.leaving) _setState(state);
      rethrow;
    } finally {
      if (!leaveCompletion.isCompleted) leaveCompletion.complete();
      if (identical(_leaveCompletion, leaveCompletion)) _leaveCompletion = null;
    }
  }

  /// Releases stream resources. It is safe to call more than once.
  Future<void>? _disposeCompletion;
  Future<void> dispose() => _disposeCompletion ??= _dispose();

  Future<void> _dispose() async {
    _disposing = true;
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run('chime.join.pending', () async {
      await _joinCompletion?.future;
    });
    await cleanup.run('chime.leave.pending', () async {
      await _leaveCompletion?.future;
    });
    if (_reserved && _nativeJoinStarted) {
      await cleanup.run('chime.native.stop', () async {
        try {
          await _channel.invoke('stop');
        } on RealtimeException catch (error) {
          if (error.code != RealtimeErrorCode.invalidState) rethrow;
        }
      });
    }
    _nativeJoinStarted = false;
    await cleanup.run('chime.channel', _releaseChannel);
    _disposed = true;
    _snapshot = MeetingSnapshot(state: MeetingState.disposed);
    await cleanup.run('chime.snapshots', _snapshotController.close);
    await cleanup.run('chime.states', _stateController.close);
    await cleanup.run('chime.events', _eventController.close);
    cleanup.finish(domain: 'chime');
  }

  void _releaseChannel() {
    _reserved = false;
    _channel.release(this);
  }

  Future<void> setMuted(bool muted) async {
    _ensureActive();
    await _channel.invoke(muted ? 'mute' : 'unmute');
    _setLocalMuted(muted);
  }

  Future<void> toggleMute() => setMuted(!_snapshot.localMuted);

  Future<void> setVideoEnabled(bool enabled) async {
    _ensureActive();
    if (_snapshot.localVideoEnabled == enabled) return;
    await _channel.invoke(enabled ? 'startLocalVideo' : 'stopLocalVideo');
    _setLocalVideoEnabled(enabled);
  }

  Future<void> switchCamera(CameraPosition position) async {
    _ensureActive();
    await _channel.invoke('setCameraPosition', {'position': position.name});
  }

  Future<List<ChimeAudioDevice>> listAudioDevices() async {
    _ensureActive();
    final value = await _channel.invoke('listAudioDevices');
    if (value is! List) {
      throw const RealtimeException(
        code: RealtimeErrorCode.providerError,
        message: 'The native SDK returned an invalid audio-device list.',
      );
    }
    final devices = value
        .map((item) => ChimeAudioDevice.fromLabel(item.toString()))
        .toList(growable: false);
    _replaceSnapshot(_snapshot.copyWith(audioDevices: devices));
    return devices;
  }

  Future<void> selectAudioDevice(ChimeAudioDevice device) async {
    _ensureActive();
    if (device.label.trim().isEmpty) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Audio device name must not be empty.',
      );
    }
    await _channel.invoke('updateAudioDevice', device.label);
    _replaceSnapshot(_snapshot.copyWith(selectedAudioDevice: device));
  }

  Future<void> sendMessage(
    String message, {
    String topic = _chatTopic,
    int lifetimeMs = 300000,
  }) async {
    _ensureActive();
    if (message.trim().isEmpty || topic.trim().isEmpty || lifetimeMs <= 0) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Message, topic, and positive lifetime are required.',
      );
    }
    await _channel.invoke('sendMessage', {
      'topic': topic,
      'message': message,
      'lifetimeMs': lifetimeMs,
    });
    final attendee = _snapshot.localAttendee;
    if (attendee != null) {
      _appendMessage(
        MeetingMessage(
          attendeeId: attendee.attendeeId,
          externalUserId: attendee.externalUserId,
          message: message,
          topic: topic,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (_disposed || _disposing) return;
    final args = call.arguments;
    switch (call.method) {
      case 'join':
        if (args is Map) _upsertAttendee(Map<String, dynamic>.from(args));
      case 'leave':
      case 'drop':
        if (args is Map) _removeAttendee(args['attendeeId']?.toString());
      case 'mute':
        if (args is Map) {
          _setAttendeeMuted(args['attendeeId']?.toString(), true);
        }
      case 'unmute':
        if (args is Map) {
          _setAttendeeMuted(args['attendeeId']?.toString(), false);
        }
      case 'videoTileAdd':
        if (args is Map) _addVideoTile(Map<String, dynamic>.from(args));
      case 'videoTileRemove':
        if (args is Map) _removeVideoTile(Map<String, dynamic>.from(args));
      case 'messageReceived':
        if (args is Map) {
          final message = MeetingMessage.fromJson(
            Map<String, dynamic>.from(args),
          );
          if (!message.throttled) _appendMessage(message);
        }
      case 'meetingEvent':
        if (args is Map) _handleMeetingEvent(Map<String, dynamic>.from(args));
      case 'audioSessionDidStop':
        _finishMeeting();
    }
  }

  void _handleMeetingEvent(Map<String, dynamic> json) {
    final event = ChimeEvent.fromJson(json);
    if (event == null) return;
    _eventController.add(event);
    if (event is MeetingSessionEvent) {
      switch (event.kind) {
        case MeetingSessionEventKind.audioConnecting:
          _setState(MeetingState.connecting);
        case MeetingSessionEventKind.audioStarted:
          _setState(MeetingState.connected);
        case MeetingSessionEventKind.audioDropped:
          _setState(MeetingState.reconnecting);
        case MeetingSessionEventKind.audioStopped:
          _finishMeeting();
        case MeetingSessionEventKind.audioReconnectCancelled:
          _finishMeeting();
        case MeetingSessionEventKind.videoConnecting:
        case MeetingSessionEventKind.videoStarted:
        case MeetingSessionEventKind.videoStopped:
          break;
      }
    }
  }

  void _upsertAttendee(Map<String, dynamic> json) {
    final id = json['attendeeId']?.toString() ?? '';
    if (id.isEmpty || id == _snapshot.localAttendeeId || id.contains('#')) {
      return;
    }
    final index = _snapshot.attendees.indexWhere(
      (item) => item.attendeeId == id,
    );
    final attendee = MeetingAttendee(
      attendeeId: id,
      externalUserId: json['externalUserId']?.toString() ?? '',
      joinedAt: DateTime.now(),
    );
    final attendees = [..._snapshot.attendees];
    if (index < 0) {
      attendees.add(attendee);
    } else {
      final old = attendees[index];
      attendees[index] = MeetingAttendee(
        attendeeId: old.attendeeId,
        externalUserId: attendee.externalUserId,
        isLocal: old.isLocal,
        isMuted: old.isMuted,
        isVideoEnabled: old.isVideoEnabled,
        videoTile: old.videoTile,
        joinedAt: old.joinedAt,
      );
    }
    _replaceSnapshot(_snapshot.copyWith(attendees: attendees));
  }

  void _removeAttendee(String? attendeeId) {
    if (attendeeId == null) return;
    final attendees = _snapshot.attendees
        .where((item) => item.attendeeId != attendeeId)
        .toList(growable: false);
    _replaceSnapshot(_snapshot.copyWith(attendees: attendees));
  }

  void _setAttendeeMuted(String? attendeeId, bool muted) {
    if (attendeeId == null) return;
    final attendees = _snapshot.attendees
        .map(
          (item) => item.attendeeId == attendeeId
              ? item.copyWith(isMuted: muted)
              : item,
        )
        .toList(growable: false);
    _replaceSnapshot(_snapshot.copyWith(attendees: attendees));
    if (attendeeId == _snapshot.localAttendeeId) _setLocalMuted(muted);
  }

  void _addVideoTile(Map<String, dynamic> json) {
    final tile = MeetingVideoTile.fromJson(json);
    if (tile.isContentShare) {
      _replaceSnapshot(_snapshot.copyWith(contentShareTile: tile));
      return;
    }
    if (!_snapshot.attendees.any(
      (item) => item.attendeeId == tile.attendeeId,
    )) {
      _upsertAttendee({
        'attendeeId': tile.attendeeId,
        'externalUserId': tile.attendeeId,
      });
    }
    final attendees = _snapshot.attendees
        .map((item) {
          if (item.attendeeId != tile.attendeeId) return item;
          return item.copyWith(isVideoEnabled: true, videoTile: tile);
        })
        .toList(growable: false);
    _replaceSnapshot(_snapshot.copyWith(attendees: attendees));
    if (tile.isLocal) _setLocalVideoEnabled(true);
  }

  void _removeVideoTile(Map<String, dynamic> json) {
    final tile = MeetingVideoTile.fromJson(json);
    if (tile.isContentShare) {
      _replaceSnapshot(_snapshot.copyWith(clearContentShareTile: true));
      return;
    }
    final attendees = _snapshot.attendees
        .map((item) {
          if (item.attendeeId != tile.attendeeId) return item;
          return item.copyWith(isVideoEnabled: false, clearVideoTile: true);
        })
        .toList(growable: false);
    _replaceSnapshot(_snapshot.copyWith(attendees: attendees));
    if (tile.isLocal) _setLocalVideoEnabled(false);
  }

  void _appendMessage(MeetingMessage message) {
    _replaceSnapshot(
      _snapshot.copyWith(messages: [..._snapshot.messages, message]),
    );
  }

  void _setLocalMuted(bool muted) {
    final attendees = _snapshot.attendees
        .map(
          (item) => item.attendeeId == _snapshot.localAttendeeId
              ? item.copyWith(isMuted: muted)
              : item,
        )
        .toList(growable: false);
    _replaceSnapshot(
      _snapshot.copyWith(localMuted: muted, attendees: attendees),
    );
  }

  void _setLocalVideoEnabled(bool enabled) {
    final attendees = _snapshot.attendees
        .map(
          (item) => item.attendeeId == _snapshot.localAttendeeId
              ? item.copyWith(isVideoEnabled: enabled)
              : item,
        )
        .toList(growable: false);
    _replaceSnapshot(
      _snapshot.copyWith(localVideoEnabled: enabled, attendees: attendees),
    );
  }

  void _setState(MeetingState state) {
    if (_disposing || _disposed) return;
    if (_snapshot.state == state) return;
    _replaceSnapshot(_snapshot.copyWith(state: state));
    _stateController.add(state);
  }

  void _finishMeeting() {
    if (_disposing || _disposed) return;
    _releaseChannel();
    final stateChanged = _snapshot.state != MeetingState.ended;
    _replaceSnapshot(
      MeetingSnapshot(
        state: MeetingState.ended,
        attendees: const [],
        messages: _snapshot.messages,
        localAttendeeId: null,
      ),
    );
    if (stateChanged && !_stateController.isClosed) {
      _stateController.add(MeetingState.ended);
    }
  }

  void _failJoin() {
    if (_disposing || _disposed) return;
    _releaseChannel();
    _replaceSnapshot(MeetingSnapshot(state: MeetingState.failed));
    if (!_stateController.isClosed) _stateController.add(MeetingState.failed);
  }

  void _replaceSnapshot(MeetingSnapshot snapshot) {
    if (_disposing || _disposed) return;
    _snapshot = snapshot;
    if (!_snapshotController.isClosed) _snapshotController.add(snapshot);
  }

  bool _isActiveState(MeetingState state) =>
      state == MeetingState.connecting ||
      state == MeetingState.connected ||
      state == MeetingState.reconnecting;

  void _ensureNotDisposed() {
    if (_disposed || _disposing) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'This meeting session has been disposed.',
      );
    }
  }

  void _ensureActive() {
    _ensureNotDisposed();
    if (!_isActiveState(_snapshot.state)) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'Join a meeting before calling this operation.',
      );
    }
  }
}
