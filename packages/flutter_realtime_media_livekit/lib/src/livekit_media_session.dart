import 'livekit_device_controller.dart';
import 'ios_in_app_screen_share.dart';
import 'ios_system_broadcast_wait.dart';
import 'ios_screen_share_mode.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
// Flutter LiveKit 2.13.x exposes BroadcastManager internally; this is its
// documented iOS system broadcasting coordinator (shared with LocalParticipant).
// ignore: implementation_imports
import 'package:livekit_client/src/managers/broadcast_manager.dart' as lkb;

import 'livekit_join_info.dart';
import 'livekit_media_track.dart';
import 'livekit_processed_video.dart';
import 'package:flutter_realtime_processed_video/flutter_realtime_processed_video.dart';

part 'livekit_publishing.dart';
part 'livekit_data_messenger.dart';
part 'livekit_event_adapter.dart';
part 'livekit_snapshot_mapper.dart';

part 'livekit_capabilities.dart';

part 'livekit_interactive_session.dart';

part 'livekit_host_session.dart';

part 'livekit_viewer_session.dart';

part 'livekit_screen_share.dart';

part 'livekit_failures.dart';

const _androidScreenShareChannel = MethodChannel(
  'flutter_realtime_media_livekit/screen_share',
);

/// Shared LiveKit lifecycle and event translation.
abstract class LiveKitMediaSessionBase
    implements
        MediaSession,
        MediaDataMessenger,
        MediaAdvancedDataMessenger,
        MediaDeviceController,
        MediaStatsProvider {
  LiveKitMediaSessionBase({
    required this.role,
    required MediaCapabilities capabilities,
    lk.Room Function()? roomFactory,
    this.iosScreenShareMode = IosScreenShareMode.system,
  }) : _roomFactory =
           roomFactory ??
           (() => lk.Room(
             roomOptions:
                 !kIsWeb &&
                     defaultTargetPlatform == TargetPlatform.iOS &&
                     iosScreenShareMode == IosScreenShareMode.system
                 ? const lk.RoomOptions(
                     defaultScreenShareCaptureOptions:
                         lk.ScreenShareCaptureOptions(
                           useiOSBroadcastExtension: true,
                         ),
                   )
                 : const lk.RoomOptions(),
           )),
       _capabilities = capabilities,
       _snapshot = MediaSnapshot(role: role, capabilities: capabilities);

  @override
  String get providerId => LiveKitJoinInfo.providerIdValue;

  late final _failures = _LiveKitFailures(providerId);
  late final _screenShare = _LiveKitScreenShare(this);
  late final _publishing = _LiveKitPublishing(this);
  late final _data = _LiveKitDataMessenger(this);
  late final _eventAdapter = _LiveKitEventAdapter(this);
  late final _mapper = _LiveKitSnapshotMapper(this);

  @override
  final MediaRole role;

  final IosScreenShareMode iosScreenShareMode;

  MediaCapabilities _capabilities;
  MediaSnapshot _snapshot;
  final lk.Room Function() _roomFactory;
  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _listener;
  LiveKitJoinInfo? _joinInfo;
  bool _disposed = false;
  bool _leaveRequestedDuringJoin = false;
  Duration cleanupTimeout = const Duration(seconds: 10);
  Future<void>? _joinFuture;
  Future<void>? _leaveFuture;
  Future<void>? _disposeFuture;

  final StreamController<MediaSessionState> _stateController =
      StreamController<MediaSessionState>.broadcast();
  final StreamController<MediaSnapshot> _snapshotController =
      StreamController<MediaSnapshot>.broadcast();
  final StreamController<MediaEvent> _eventController =
      StreamController<MediaEvent>.broadcast();
  final StreamController<MediaConnectionStats> _statsController =
      StreamController<MediaConnectionStats>.broadcast();
  MediaConnectionStats? _connectionStats;

  /// Underlying LiveKit room for provider-specific advanced integrations.
  lk.Room? get liveKitRoom => _room;

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
  Future<void> join(MediaJoinInfo joinInfo) {
    final current = _joinFuture;
    if (current != null) {
      if (_leaveRequestedDuringJoin) {
        return Future.error(
          const RealtimeException(
            code: RealtimeErrorCode.cancelled,
            message: 'The previous LiveKit join is still being cancelled.',
            providerId: LiveKitJoinInfo.providerIdValue,
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

  late final _devices = LiveKitDeviceController(
    capabilities: () => capabilities,
    requireRoom: _requireRoom,
    ensureActive: _ensureActive,
  );
  @override
  Future<List<MediaDevice>> listMediaDevices({Set<MediaDeviceKind>? kinds}) =>
      _devices.listMediaDevices(kinds: kinds);
  @override
  Future<void> selectMediaDevice(MediaDevice device) =>
      _devices.selectMediaDevice(device);

  Future<void> _join(MediaJoinInfo rawJoinInfo) async {
    _ensureNotDisposed();
    if (state != MediaSessionState.idle &&
        state != MediaSessionState.ended &&
        state != MediaSessionState.failed) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'This LiveKit session is already joining or active.',
        providerId: LiveKitJoinInfo.providerIdValue,
      );
    }
    if (rawJoinInfo is! LiveKitJoinInfo ||
        rawJoinInfo.providerId != providerId ||
        rawJoinInfo.role != role) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Join information does not match this LiveKit session.',
        providerId: LiveKitJoinInfo.providerIdValue,
      );
    }

    _joinInfo = rawJoinInfo;
    _setState(MediaSessionState.joining);
    final room = _roomFactory();
    _room = room;
    _eventAdapter._attachRoomEvents(room);
    _setState(MediaSessionState.connecting);
    try {
      await room.connect(
        rawJoinInfo.url,
        rawJoinInfo.token,
        connectOptions: const lk.ConnectOptions(autoSubscribe: true),
      );
      if (_disposed || _leaveRequestedDuringJoin) {
        throw const RealtimeException(
          code: RealtimeErrorCode.cancelled,
          message: 'Session is closing.',
        );
      }
      final local = room.localParticipant;
      if (local == null) {
        throw const RealtimeException(
          code: RealtimeErrorCode.providerError,
          message: 'LiveKit connected without a local participant.',
          providerId: LiveKitJoinInfo.providerIdValue,
        );
      }
      if (local.identity != rawJoinInfo.identity) {
        throw RealtimeException(
          code: RealtimeErrorCode.invalidArgument,
          message:
              'LiveKit token identity "${local.identity}" does not match '
              'participantId "${rawJoinInfo.identity}".',
          providerId: providerId,
        );
      }
      _validatePermissions(local.permissions);
      _capabilities = _capabilitiesWithDataPermission(
        _capabilities,
        local.permissions.canPublishData,
      );
      _mapper._refreshSnapshot(clearLastError: true);
      _setState(MediaSessionState.connected);
    } on RealtimeException catch (error, stack) {
      await _rollbackJoin(error, stack);
    } catch (error, stack) {
      final mapped = _mapError(
        error,
        'join',
        operation: 'join',
        stackTrace: stack,
      );
      await _rollbackJoin(mapped, stack);
    }
  }

  void _validatePermissions(lk.ParticipantPermissions permissions) {
    if (!permissions.canSubscribe) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'LiveKit credentials do not allow subscribing to media.',
        providerId: providerId,
      );
    }
    if (role == MediaRole.viewer && permissions.canPublish) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Viewer credentials must not grant media publish permission.',
        providerId: providerId,
      );
    }
    if (role.canPublishMedia && !permissions.canPublish) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Publisher credentials do not grant media publish permission.',
        providerId: providerId,
      );
    }
  }

  @override
  Future<void> leave() => _leaveFuture ??= _leave().whenComplete(() {
    _leaveFuture = null;
  });

  Future<void> _leave() async {
    if (_disposed) return;
    if (state == MediaSessionState.joining ||
        state == MediaSessionState.connecting) {
      _leaveRequestedDuringJoin = true;
      // Do not await the pending connect: some native SDK transports do not
      // complete that future when the user leaves. Tear down the room now;
      // a late connect result is rejected by _join's cancellation guard.
      await _tearDownRoom();
      if (!_disposed) _setState(MediaSessionState.ended);
      return;
    }
    if (_disposed) return;
    if (state == MediaSessionState.idle ||
        state == MediaSessionState.ended ||
        state == MediaSessionState.failed) {
      if (state != MediaSessionState.ended) {
        _setState(MediaSessionState.ended);
      }
      return;
    }
    if (state == MediaSessionState.disposed) return;
    _setState(MediaSessionState.leaving);
    try {
      await _detachProcessedVideoBeforeRoomTeardown();
      await _room?.disconnect();
    } catch (error, stack) {
      final mapped = _mapError(error, 'leave', stackTrace: stack);
      _reportFailure(mapped);
    }
    await _tearDownRoom();
    _setState(MediaSessionState.ended);
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run('join.pending', () async {
      try {
        await _joinFuture;
      } catch (_) {
        /* The join caller receives its failure. */
      }
    });
    await cleanup.run('engine', () async {
      await _tearDownRoom();
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

  @override
  Future<void> sendMessage(String message, {String topic = 'chat'}) =>
      _data.sendMessage(message, topic: topic);
  @override
  Future<void> sendDataMessage(
    String message, {
    MediaSendOptions options = const MediaSendOptions(),
  }) => _data.sendDataMessage(message, options: options);

  lk.LocalParticipant _requireLocalParticipant() {
    final local = _room?.localParticipant;
    if (local == null) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'The LiveKit local participant is unavailable.',
        providerId: providerId,
      );
    }
    return local;
  }

  lk.Room _requireRoom() {
    final room = _room;
    if (room == null) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'The LiveKit room is unavailable.',
        providerId: providerId,
      );
    }
    return room;
  }

  void _ensureActive() {
    _ensureNotDisposed();
    if (!state.isActive) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'The LiveKit session is not active.',
        providerId: providerId,
      );
    }
  }

  void _ensureNotDisposed() {
    if (_disposed || state == MediaSessionState.disposed) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'The LiveKit session has been disposed.',
        providerId: providerId,
      );
    }
  }

  void _setState(
    MediaSessionState next, {
    RealtimeException? error,
    String? reason,
  }) {
    if (_disposed) {
      if (next == MediaSessionState.disposed) {
        _snapshot = _snapshot.copyWith(state: next);
      }
      return;
    }
    if (_snapshot.state == next && error == null) return;
    final previous = _snapshot.state;
    _replaceSnapshot(
      error == null
          ? _snapshot.copyWith(state: next)
          : _snapshot.copyWith(state: next, lastError: error),
    );
    if (!_stateController.isClosed) _stateController.add(next);
    _emit(
      MediaConnectionStateChanged(
        previous: previous,
        current: next,
        reason: reason,
      ),
    );
    if (error != null) _emit(MediaFailureEvent(error));
  }

  void _reportFailure(RealtimeException error) {
    _replaceSnapshot(_snapshot.copyWith(lastError: error));
    _emit(MediaFailureEvent(error));
  }

  void _replaceSnapshot(MediaSnapshot next) {
    if (_disposed) return;
    _snapshot = next;
    if (!_snapshotController.isClosed) _snapshotController.add(next);
  }

  void _emit(MediaEvent event) {
    if (!_disposed && !_eventController.isClosed) _eventController.add(event);
  }

  Future<void> _detachProcessedVideoBeforeRoomTeardown() =>
      _publishing.detachProcessedVideoSource();

  Future<Never> _rollbackJoin(
    RealtimeException primary,
    StackTrace stack,
  ) async {
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run('join.rollback', _tearDownRoom);
    if (!_leaveRequestedDuringJoin) {
      _setState(MediaSessionState.failed, error: primary);
    }
    cleanup.finish(domain: providerId, cause: primary);
    Error.throwWithStackTrace(primary, stack);
  }

  Future<void> _tearDownRoom() async {
    final room = _room;
    final listener = _listener;
    _listener = null;
    _room = null;
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run(
      'processed.input',
      _detachProcessedVideoBeforeRoomTeardown,
    );
    await cleanup.run(
      'screenShare.service',
      _screenShare._stopAndroidScreenShareService,
    );
    await cleanup.run(
      'screenShare.iosBroadcast',
      _screenShare._stopIosBroadcastOnRoomTeardown,
    );
    if (listener != null) await cleanup.run('room.listener', listener.dispose);
    if (room != null && !room.isDisposed) {
      await cleanup.run('room.dispose', room.dispose);
    }
    cleanup.finish(domain: providerId);
  }

  RealtimeException _mapError(
    Object error,
    String stage, {
    String? operation,
    StackTrace? stackTrace,
  }) =>
      _failures.map(error, stage, operation: operation, stackTrace: stackTrace);
}
