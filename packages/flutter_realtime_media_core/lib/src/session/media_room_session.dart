import 'dart:async';
import 'dart:convert';
import 'package:flutter_realtime_foundation/flutter_realtime_foundation.dart';
import '../model/media_identity.dart';
import '../model/media_send_options.dart';
import 'media_data_controller.dart';

import '../client/media_backend_error.dart';
import '../model/media_background_effect.dart';
import '../model/media_error.dart';
import '../model/media_event.dart';
import '../model/media_management_capability.dart';
import '../model/media_recovery_status.dart';
import '../model/media_role.dart';
import '../model/media_room_participant_summary.dart';
import '../model/media_snapshot.dart';
import '../model/media_state.dart';
import '../recording/cloud_recording_blueprints.dart';
import '../recording/cloud_recording_descriptor.dart';
import '../recording/recording_options.dart';
import 'interactive_media_session.dart';
import 'media_session.dart';
import '../model/media_meeting_mode.dart';
import 'media_background_effects_controller.dart';
import 'media_role_switch.dart';
import 'media_room_extensions.dart';

part 'room_presence.dart';
part 'room_recovery.dart';
part 'room_management.dart';
part 'room_participant_profiles.dart';

/// High-level room lifecycle returned by `MediaClient`.
///
/// The underlying [session] stays the source of media state and controls. This
/// wrapper only adds backend presence: heartbeat while the media session is
/// alive and a best-effort leave notification.
///
/// Backend presence failures are reported on [backendErrors] and never stop
/// healthy media, exactly like the Chime `ChimeRoomSession`.
class MediaRoomSession implements MediaBackgroundEffectsController {
  /// Creates a room wrapper without a Backend Contract dependency.
  factory MediaRoomSession.direct({
    required String roomCode,
    required String participantId,
    required MediaSession session,
    MediaIdentity? identity,
    Map<String, dynamic> backendMetadata = const {},
  }) => MediaRoomSession._(
    null,
    null,
    Duration.zero,
    roomCode: roomCode,
    participantId: participantId,
    initialSession: session,
    identity: identity,
    backendMetadata: Map.unmodifiable(backendMetadata),
  );
  MediaRoomSession._(
    this._presence,
    this._management,
    this._heartbeatInterval, {
    required this.roomCode,
    required this.participantId,
    this.participantCredential,
    this.roomOwnerCredential,
    this.chatProvider,
    this.backendMetadata = const {},
    required MediaSession initialSession,
    MediaIdentity? identity,
    void Function(MediaSession next)? onSessionReplaced,
  }) : _session = initialSession {
    _sessionReplacedCallback = onSessionReplaced;
    _bindSessionSubscriptions(initialSession);
    _presenceOwner.start();
    _profiles = _RoomParticipantProfiles(
      initialSession,
      participantId,
      identity: identity,
      metadata: backendMetadata,
      reportError: _presenceOwner._reportBackendError,
    );
  }

  /// Attaches backend presence handling to an already joined [session].
  static MediaRoomSession attach({
    required String roomCode,
    required String participantId,
    String? participantCredential,
    String? roomOwnerCredential,
    String? chatProvider,
    Map<String, dynamic> backendMetadata = const {},
    MediaIdentity? identity,
    required MediaSession session,
    required MediaRoomPresence presence,
    required MediaRoomManagement management,
    required Duration heartbeatInterval,
    void Function(MediaSession next)? onSessionReplaced,
  }) => MediaRoomSession._(
    presence,
    management,
    heartbeatInterval,
    roomCode: roomCode,
    participantId: participantId,
    participantCredential: participantCredential,
    roomOwnerCredential: roomOwnerCredential,
    chatProvider: chatProvider,
    backendMetadata: Map.unmodifiable(backendMetadata),
    initialSession: session,
    identity: identity,
    onSessionReplaced: onSessionReplaced,
  );

  final String roomCode;
  final String participantId;
  final String? participantCredential;
  final String? roomOwnerCredential;
  final String? chatProvider;

  /// Provider-neutral backend response metadata retained for high-level
  /// orchestration such as capability negotiation.
  final Map<String, dynamic> backendMetadata;

  /// Authoritative meeting policy, absent for direct and broadcast sessions.
  MediaMeetingMode? get meetingMode => backendMetadata['roomMode'] == 'meeting'
      ? MediaMeetingMode.fromMetadata(backendMetadata)
      : null;

  /// Whether the room host/backend enabled room-wide screen-capture protection.
  bool get roomPreventScreenCapture =>
      backendMetadata['preventScreenCapture'] == true;
  MediaSession _session;
  MediaSession get session => _session;
  void Function(MediaSession next)? _sessionReplacedCallback;
  late final _RoomParticipantProfiles _profiles;
  final MediaRoomPresence? _presence;
  final MediaRoomManagement? _management;
  final Duration _heartbeatInterval;
  late final _presenceOwner = _RoomPresence(
    _presence,
    roomCode,
    participantId,
    _heartbeatInterval,
  );
  final _recovery = _RoomRecovery();
  late final _roomManagement = _RoomManagement(
    session: _session,
    management: _management,
    roomCode: roomCode,
    participantId: participantId,
    participantCredential: participantCredential,
    roomOwnerCredential: roomOwnerCredential,
    backendMetadata: backendMetadata,
  );

  void _bindSessionSubscriptions(MediaSession target) {
    unawaited(_stateSubscription?.cancel());
    unawaited(_eventSubscription?.cancel());
    _stateSubscription = target.states.listen(_onStateChanged);
    _eventSubscription = target.events.listen(_onSessionEvent);
  }

  bool get canSwitchRole => _session is MediaRoleSwitchable;

  Future<void> switchRole(MediaRole targetRole) async {
    if (_disposed) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'MediaRoomSession is disposed.',
        providerId: providerId,
      );
    }
    final active = _session;
    if (active is! MediaRoleSwitchable) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'The active provider does not support live role switching.',
        providerId: providerId,
      );
    }
    final next = await (active as MediaRoleSwitchable).switchRole(targetRole);
    if (!identical(next, _session)) {
      _session = next;
      _roomManagement.session = next;
      _sessionReplacedCallback?.call(next);
      _bindSessionSubscriptions(next);
      _profiles.rebindSession(next);
    }
  }

  final _cleanupErrors = StreamController<RealtimeException>.broadcast();
  final _localScreenShareStarting = StreamController<bool>.broadcast();
  Future<void> Function()? beforeLocalScreenShareStart;
  bool _isLocalScreenShareStarting = false;
  bool get isLocalScreenShareStarting => _isLocalScreenShareStarting;
  Stream<bool> get localScreenShareStartingChanges =>
      _localScreenShareStarting.stream;

  Future<void> setScreenShareEnabled(bool enabled) async {
    if (_disposed) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'MediaRoomSession is disposed.',
        providerId: providerId,
      );
    }
    final active = _session;
    if (active is! InteractiveMediaSession) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'Screen sharing is unavailable for this role.',
        providerId: providerId,
      );
    }
    if (!enabled) {
      await active.setScreenShareEnabled(false);
      return;
    }
    _isLocalScreenShareStarting = true;
    if (!_localScreenShareStarting.isClosed) {
      _localScreenShareStarting.add(true);
    }
    try {
      await beforeLocalScreenShareStart?.call();
      await active.setScreenShareEnabled(true);
    } finally {
      _isLocalScreenShareStarting = false;
      if (!_localScreenShareStarting.isClosed) {
        _localScreenShareStarting.add(false);
      }
    }
  }

  StreamSubscription<MediaSessionState>? _stateSubscription;
  StreamSubscription<MediaEvent>? _eventSubscription;
  bool _disposed = false;
  Duration cleanupTimeout = const Duration(seconds: 10);
  Future<void>? _disposeFuture;
  Future<void>? _closeRoomFuture;
  Future<void>? _leaveFuture;
  String get providerId => session.providerId;
  MediaRole get role => session.role;
  bool get isLogicalOwner => _roomManagement.isLogicalOwner;
  bool get isLeavingOrClosing =>
      _disposed || _leaveFuture != null || _closeRoomFuture != null;
  MediaManagementCapabilities get managementCapabilities =>
      _roomManagement.capabilities;

  /// Latest media snapshot.
  MediaSnapshot get snapshot => _profiles.snapshot;
  Stream<MediaSnapshot> get snapshots => _profiles.snapshots;

  /// Background effects supported by the active media adapter.
  @override
  MediaBackgroundCapabilities get backgroundCapabilities {
    final active = session;
    if (active is MediaBackgroundEffectsController) {
      return (active as MediaBackgroundEffectsController)
          .backgroundCapabilities;
    }
    return MediaBackgroundCapabilities(
      canBlur: active.capabilities.canBlurBackground,
      canReplaceImage: active.capabilities.canReplaceBackgroundImage,
    );
  }

  /// Currently selected local background effect.
  @override
  MediaBackgroundEffect get backgroundEffect {
    final active = session;
    return active is MediaBackgroundEffectsController
        ? (active as MediaBackgroundEffectsController).backgroundEffect
        : const MediaBackgroundEffect.none();
  }

  /// Applies a provider-neutral local camera background effect.
  @override
  Future<void> setBackgroundEffect(MediaBackgroundEffect effect) {
    if (!effect.enabled && session is! MediaBackgroundEffectsController) {
      return Future<void>.value();
    }
    if (!session.capabilities.canPublishVideo ||
        !backgroundCapabilities.supports(effect)) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message:
            'The active provider does not support the requested background '
            'effect for this role or platform.',
        providerId: providerId,
      );
    }
    final active = session;
    final MediaBackgroundEffectsController? controller =
        active is MediaBackgroundEffectsController
        ? active as MediaBackgroundEffectsController
        : null;
    if (controller == null) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message:
            'The active provider does not expose background effect controls.',
        providerId: providerId,
      );
    }
    return controller.setBackgroundEffect(effect);
  }

  /// Generates a structured [CloudRecordingDescriptor] for this room session
  /// using the active provider's official API specifications.
  CloudRecordingDescriptor describeCloudRecording([RecordingOptions? options]) {
    return CloudRecordingBlueprints.buildDescriptor(
      providerId: providerId,
      roomCode: roomCode,
      participantId: participantId,
      options: options ?? const RecordingOptions(mode: RecordingMode.cloud),
    );
  }

  Stream<RealtimeException> get backendErrors => _presenceOwner.errors;
  MediaRecoveryStatus? get recoveryStatus => _recovery.status;
  Stream<MediaRecoveryStatus> get recoveries => _recovery.stream;

  /// Non-replaying local cleanup failures after an authoritative room close.
  /// The room is already closed; closeRoom still completes successfully.
  /// Ordinary leave/dispose failures are reported by their returned futures.
  Stream<RealtimeException> get cleanupErrors => _cleanupErrors.stream;

  Future<List<MediaRoomParticipantSummary>> listParticipants() =>
      _roomManagement.listParticipants();
  Future<void> muteParticipant(String targetParticipantId) =>
      _roomManagement.muteParticipant(targetParticipantId);
  Future<void> stopParticipantVideo(String targetParticipantId) =>
      _roomManagement.stopParticipantVideo(targetParticipantId);
  Future<void> changeParticipantRole(
    String targetParticipantId,
    MediaRole role,
  ) => _roomManagement.changeParticipantRole(targetParticipantId, role);
  Future<void> removeParticipant(String targetParticipantId) =>
      _roomManagement.removeParticipant(targetParticipantId);

  /// Closes the logical room for future joins using backend-authoritative
  /// permissions.
  Future<void> closeRoom() {
    final current = _closeRoomFuture;
    if (current != null) return current;
    late final Future<void> future;
    future = _closeRoom().whenComplete(() {
      if (identical(_closeRoomFuture, future)) _closeRoomFuture = null;
    });
    _closeRoomFuture = future;
    return future;
  }

  Future<void> _closeRoom() async {
    final management = _roomManagement.executor(
      managementCapabilities.closeRoom,
      'close the logical room',
    );
    if (_disposed || _presenceOwner.leaveNotified) return;
    _presenceOwner.stop();
    await _presenceOwner.drain();
    try {
      await management.closeRoomManaged(
        roomCode,
        requesterParticipantId: participantId,
        participantCredential: participantCredential,
        roomOwnerCredential: roomOwnerCredential,
      );
    } on RealtimeException catch (error) {
      if (error.code != RealtimeErrorCode.roomNotFound &&
          error.statusCode != 404) {
        if (!_disposed &&
            !_presenceOwner.leaveNotified &&
            !session.state.isTerminal) {
          _presenceOwner.start();
        }
        rethrow;
      }
    } catch (_) {
      if (!_disposed &&
          !_presenceOwner.leaveNotified &&
          !session.state.isTerminal) {
        _presenceOwner.start();
      }
      rethrow;
    }

    // Closing a room supersedes the normal leave notification. Mark it before
    // disconnecting local media because terminal state callbacks also attempt
    // the best-effort leave path.
    _presenceOwner.leaveNotified = true;
    try {
      await session.leave();
    } catch (error, stack) {
      if (!_cleanupErrors.isClosed) {
        _cleanupErrors.add(
          RealtimeException(
            code: RealtimeErrorCode.cleanupFailed,
            message: 'closeRoom.localLeave failed.',
            domain: 'media',
            operation: 'closeRoom.localLeave',
            providerId: providerId,
            cause: error,
            stackTrace: stack,
            details: Map<String, Object>.unmodifiable({
              'roomClosed': true,
              'cleanupFailures': List<CleanupFailure>.unmodifiable([
                CleanupFailure('session.leave', error, stack),
              ]),
            }),
          ),
        );
      }
    }
  }

  /// Leaves media and always attempts the best-effort backend notification.
  Future<void> leave() => _leaveFuture ??= _leave();
  Future<void> _leave() async {
    if (_disposed) return;
    _presenceOwner.stop();
    try {
      await session.leave();
    } finally {
      await _presenceOwner.notifyLeave();
    }
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();
  Future<void> _dispose() async {
    _disposed = true;
    _presenceOwner.stop();
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run('participant.profiles', _profiles.dispose);
    await cleanup.run('presence.heartbeat', _presenceOwner.drain);
    await cleanup.run('session.states', () async {
      await _stateSubscription?.cancel();
    });
    await cleanup.run('session.events', () async {
      await _eventSubscription?.cancel();
    });
    await cleanup.run('session', session.dispose);
    await cleanup.run('presence.leave', _presenceOwner.notifyLeave);
    await cleanup.run('backend.errors', _presenceOwner.dispose);
    await cleanup.run('recovery', _recovery.dispose);
    await cleanup.run('cleanup.errors', _cleanupErrors.close);
    await cleanup.run('screenShareStarting', _localScreenShareStarting.close);
    beforeLocalScreenShareStart = null;
    cleanup.finish(domain: 'media');
  }

  void _onStateChanged(MediaSessionState state) {
    _recovery.onState(state);
    if (state.isTerminal) {
      _presenceOwner.stop();
      unawaited(_presenceOwner.notifyLeave());
    }
  }

  void _onSessionEvent(MediaEvent event) => _recovery.onEvent(event);
}
