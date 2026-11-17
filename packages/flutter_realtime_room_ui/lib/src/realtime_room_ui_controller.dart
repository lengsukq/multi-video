import 'realtime_room_ui_action.dart';
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_chat_ui/flutter_realtime_chat_ui.dart';

/// Presentation state and commands; never owns provider sessions or rendering.
///
/// A single instance is shared by every room component. Subscriptions are
/// attached once, and disposing the UI does not disconnect the actual room.
class RealtimeRoomUiController extends ChangeNotifier {
  RealtimeRoomUiController(
    this.room, {
    this.onActionError,
    MediaCameraPosition initialCameraPosition = MediaCameraPosition.front,
  }) : _cameraPosition = initialCameraPosition {
    _snapshot = room.snapshot;
    _mediaSubscription = room.snapshots.listen((snapshot) {
      if (_disposed) return;
      _snapshot = snapshot;
      notifyListeners();
    });
    _failureSubscription = room.events.listen((event) {
      if (_disposed) return;
      final failure = switch (event) {
        RealtimeBackendFailure(:final error) => error,
        RealtimeMediaEvent(event: MediaFailureEvent(:final error)) => error,
        _ => null,
      };
      if (failure != null) {
        // Room pages handle this terminal presence event by leaving; it is
        // not a recoverable action error to present as an HTTP 404 snackbar.
        if (failure.code == RealtimeErrorCode.roomNotFound &&
            failure.operation == 'room.presence.heartbeat') {
          return;
        }
        reportActionError(failure);
      }
    });
    final chat = room.chat;
    if (chat != null) {
      _chatUi = ChatUiController(chat, moderation: room.chatModeration);
      _chatUi!.addListener(_onChatChanged);
    }
  }

  /// Shares the same partially-successful bulk moderation service as the
  /// legacy room. Failures are retained so a host can retry only failed IDs.
  Future<void> muteAllParticipants({bool retryFailed = false}) async {
    if (!canMuteAllParticipants) return;
    final targets = retryFailed ? _bulkMuteFailures.keys.toList() : null;
    if (targets != null && targets.isEmpty) return;
    await execute(RealtimeRoomUiAction.participantManagement, () async {
      final result = await _memberDirectory.muteAll(
        room.media,
        targets: targets,
        isCurrent: () => !_disposed,
      );
      if (_disposed || !result.completed) return;
      _bulkMuteFailures = result.failures;
      notifyListeners();
      await refreshManagedMembers();
    });
  }

  Future<void> removeParticipant(String participantId) => execute(
    RealtimeRoomUiAction.participantManagement,
    () => _memberDirectory.manageMedia(
      room.media,
      participantId,
      RoomMediaMemberAction.remove,
    ),
  );

  Future<void> muteParticipant(String participantId) => execute(
    RealtimeRoomUiAction.participantManagement,
    () => _memberDirectory.manageMedia(
      room.media,
      participantId,
      RoomMediaMemberAction.mute,
    ),
  );

  Future<void> stopParticipantVideo(String participantId) => execute(
    RealtimeRoomUiAction.participantManagement,
    () => _memberDirectory.manageMedia(
      room.media,
      participantId,
      RoomMediaMemberAction.stopVideo,
    ),
  );

  Future<void> setBackgroundEffect(MediaBackgroundEffect effect) => execute(
    RealtimeRoomUiAction.backgroundEffect,
    () => room.setBackgroundEffect(effect),
  );

  final RealtimeRoom room;
  RoomMembersController get _memberDirectory => room.memberDirectory;
  List<RoomManagedMember> _managedMembers = const [];
  Map<MediaParticipant, Object> _bulkMuteFailures = const {};
  Object? _memberLoadError;
  bool _membersLoading = false;
  late MediaSnapshot _snapshot;
  ChatUiController? _chatUi;
  final Set<RealtimeRoomUiAction> _pending = {};
  final Map<RealtimeRoomUiAction, Future<void>> _actionFutures = {};
  int _actionSequence = 0;
  ({int sequence, RealtimeRoomUiAction action})? _lastCompletedAction;

  /// Presentation-only acknowledgement; never grants room authority.
  ({int sequence, RealtimeRoomUiAction action})? get lastCompletedAction =>
      _lastCompletedAction;
  StreamSubscription<MediaSnapshot>? _mediaSubscription;
  StreamSubscription<RealtimeEvent>? _failureSubscription;
  MediaCameraPosition _cameraPosition;
  RealtimeException? _error;
  Object? _lastReportedError;
  bool _disposed = false;

  MediaSnapshot get snapshot => _snapshot;
  bool get membersLoading => _membersLoading;
  Map<MediaParticipant, Object> get bulkMuteFailures => _bulkMuteFailures;
  bool get canMuteAllParticipants =>
      room.isLogicalOwner &&
      room.managementCapabilities.muteParticipant.supported &&
      _snapshot.participants.any((member) => !member.isLocal);
  Object? get memberLoadError => _memberLoadError;

  /// Includes RTC-only and chat-only members, reconciled by logical user ID.
  List<RoomManagedMember> get managedMembers =>
      mergeSnapshotMembers(_managedMembers, _snapshot, localRole: room.role);

  /// Explicit refresh avoids backend polling by every independent UI widget.
  Future<void> refreshManagedMembers() async {
    if (_disposed || _membersLoading) return;
    _membersLoading = true;
    _memberLoadError = null;
    notifyListeners();
    final result = await _memberDirectory.load(
      room.media,
      chatSession: room.chat,
      chatModeration: room.chatModeration,
      isCurrent: () => !_disposed,
    );
    if (_disposed || !result.completed) return;
    _managedMembers = result.members;
    _memberLoadError = result.error;
    _membersLoading = false;
    notifyListeners();
  }

  Future<void> removeChatMember(String userId) async {
    final chat = _chatUi;
    if (chat == null ||
        !chat.isHost ||
        !chat.managementCapabilities.removeMember.supported) {
      return;
    }
    await execute(RealtimeRoomUiAction.participantManagement, () async {
      await _memberDirectory.removeChatMember(
        room.chatModeration!,
        userId,
        session: room.chat,
      );
      await chat.refreshMembers();
      await refreshManagedMembers();
    });
  }

  Future<void> changeParticipantRole(
    String participantId,
    MediaRole role,
  ) async {
    if (!room.isLogicalOwner ||
        !room.managementCapabilities.changeParticipantRole.supported) {
      return;
    }
    await execute(
      RealtimeRoomUiAction.participantManagement,
      () => role == MediaRole.host
          ? _memberDirectory.manageMedia(
              room.media,
              participantId,
              RoomMediaMemberAction.grantHost,
            )
          : room.media.changeParticipantRole(participantId, role),
    );
    await refreshManagedMembers();
  }

  List<ChatMessage> get messages => _chatUi?.messages ?? const <ChatMessage>[];
  ChatUiController? get chatUiController => _chatUi;
  void _onChatChanged() {
    if (!_disposed) notifyListeners();
  }

  final void Function(RealtimeException error)? onActionError;
  bool get isDisposed => _disposed;
  RealtimeException? get error => _error;
  void reportActionError(Object error) {
    if (identical(error, _lastReportedError)) return;
    _lastReportedError = error;
    final failure = normalizeRealtimeException(error, domain: 'room.ui');
    if (!_disposed) {
      _error = failure;
      onActionError?.call(failure);
      notifyListeners();
    } else {
      room.reportLifecycleFailure(failure);
    }
  }

  MediaCameraPosition get cameraPosition => _cameraPosition;
  bool isPending(RealtimeRoomUiAction action) => _pending.contains(action);

  bool get canUseMicrophone => room.canUseMicrophone;
  bool get canUseCamera => room.canUseCamera;
  bool get canShareScreen => room.canShareScreen;
  bool get canSelectScreenShareSource => room.canSelectScreenShareSource;

  Future<List<MediaScreenShareSource>> listScreenShareSources() =>
      room.listScreenShareSources();

  Future<void> selectScreenShareSource(MediaScreenShareSource source) =>
      room.selectScreenShareSource(source);

  bool get canSwitchCamera => room.canSwitchCamera;
  bool get canListAudioOutputs => room.canListAudioOutputs;
  bool get canSelectAudioOutput => room.canSelectAudioOutput;

  bool canListMediaDevices(MediaDeviceKind kind) =>
      room.canListMediaDevices(kind);

  bool canSelectMediaDevice(MediaDeviceKind kind) =>
      room.canSelectMediaDevice(kind);

  Future<List<MediaDevice>> listMediaDevices(MediaDeviceKind kind) async {
    if (!canListMediaDevices(kind)) return const [];
    return room.listMediaDevices(kinds: {kind});
  }

  Future<void> selectMediaDevice(MediaDevice device) async {
    if (!canSelectMediaDevice(device.kind)) return;
    await execute(
      RealtimeRoomUiAction.device,
      () => room.selectMediaDevice(device),
    );
  }

  Future<List<MediaAudioDevice>> listAudioOutputs() async {
    if (!canListAudioOutputs) return const [];
    return room.listAudioOutputs();
  }

  Future<void> selectAudioOutput(MediaAudioDevice device) async {
    if (!canSelectAudioOutput) return;
    await execute(
      RealtimeRoomUiAction.audioOutput,
      () => room.selectAudioOutput(device),
    );
  }

  /// Runs an action once. Concurrent callers await the SAME command result
  /// (including its failure), rather than receiving a false early success.
  Future<void> execute(
    RealtimeRoomUiAction action,
    Future<void> Function() command,
  ) {
    final existing = _actionFutures[action];
    if (existing != null) return existing;
    if (_disposed) {
      return Future<void>.error(
        const RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message:
              'Cannot execute an action through a closed room UI controller.',
          domain: 'room.ui',
          operation: 'execute',
        ),
      );
    }
    final pending = _executeOnce(action, command);
    _actionFutures[action] = pending;
    return pending;
  }

  Future<void> _executeOnce(
    RealtimeRoomUiAction action,
    Future<void> Function() command,
  ) async {
    _pending.add(action);
    _lastReportedError = null;
    _error = null;
    notifyListeners();
    try {
      await command();
      if (!_disposed) {
        _lastCompletedAction = (sequence: ++_actionSequence, action: action);
      }
    } catch (error, stack) {
      final failure = normalizeRealtimeException(
        error,
        domain: 'room.ui',
        stackTrace: stack,
      );
      if (!_disposed) _error = failure;
      Error.throwWithStackTrace(failure, stack);
    } finally {
      _actionFutures.removeWhere((key, _) => key == action);
      if (!_disposed) {
        _pending.remove(action);
        notifyListeners();
      }
    }
  }

  Future<void> toggleMicrophone() async {
    if (!canUseMicrophone) return;
    await execute(RealtimeRoomUiAction.microphone, () async {
      await room.toggleMicrophone();
      if (!_disposed) {
        _snapshot = room.snapshot;
        notifyListeners();
      }
    });
  }

  Future<void> toggleCamera() async {
    if (!canUseCamera) return;
    await execute(RealtimeRoomUiAction.camera, room.toggleCamera);
  }

  Future<void> toggleScreenShare({MediaScreenShareSource? source}) async {
    if (!canShareScreen) return;
    await execute(
      RealtimeRoomUiAction.screenShare,
      () => room.toggleScreenShare(source: source),
    );
  }

  Future<void> switchCamera() async {
    if (!canSwitchCamera) return;
    final next = _cameraPosition == MediaCameraPosition.front
        ? MediaCameraPosition.back
        : MediaCameraPosition.front;
    await execute(RealtimeRoomUiAction.switchCamera, () async {
      await room.switchCamera(next);
      if (!_disposed) {
        _cameraPosition = next;
        notifyListeners();
      }
    });
  }

  Future<void> sendMessage(String text) async {
    final chat = _chatUi;
    if (chat == null || text.trim().isEmpty) return;
    await execute(
      RealtimeRoomUiAction.sendMessage,
      () => chat.send(text.trim()),
    );
  }

  Future<void>? _leaveFuture;

  /// Ends the underlying room only when requested, never on UI disposal.
  /// The caller owns navigation and the optional confirmation dialog.
  /// Concurrent callers share one Future, so none can navigate before the
  /// actual leave/cleanup completes. A failure before teardown is retryable.
  Future<void> leave({bool? closeForEveryone}) {
    final pending = _leaveFuture;
    if (pending != null) return pending;
    if (_disposed) {
      return Future<void>.error(
        const RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'Cannot leave through a closed room UI controller.',
          domain: 'room.ui',
          operation: 'leave',
        ),
      );
    }
    return _leaveFuture = _leaveOnce(closeForEveryone: closeForEveryone);
  }

  Future<void> _leaveOnce({bool? closeForEveryone}) async {
    try {
      await execute(
        RealtimeRoomUiAction.leave,
        () => room.leaveRoom(
          closeForEveryone: closeForEveryone,
          beforeDispose: () async {
            // Release provider subscriptions before room teardown, but leave
            // ChangeNotifier and ChatUiController alive until the host's UI
            // unmounts. Otherwise a button rebuilding during this final frame
            // subscribes to a disposed notifier and triggers a red error screen.
            await _mediaSubscription?.cancel();
            await _failureSubscription?.cancel();
          },
        ),
      );
    } catch (_) {
      _leaveFuture = null;
      rethrow;
    }
  }

  Future<void>? _disposal;

  /// Cancels owned presentation subscriptions; the borrowed room stays open.
  Future<void> close() {
    dispose();
    return _disposal!;
  }

  @protected
  Future<void> releaseResources() async {
    // Local subscription cancellation has no external I/O or acquisition.
    final cleanup = Cleanup(timeout: null);
    final mediaRelease = cleanup.run('room.ui.media', () async {
      await _mediaSubscription?.cancel();
    });
    final chatRelease = cleanup.run('room.ui.chat', () {
      _chatUi?.removeListener(_onChatChanged);
      _chatUi?.dispose();
    });
    final failureRelease = cleanup.run('room.ui.failures', () async {
      await _failureSubscription?.cancel();
    });
    await Future.wait([mediaRelease, chatRelease, failureRelease]);
    cleanup.finish(domain: 'room.ui');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
    _disposal ??= releaseResources();
    observeDetached(
      _disposal!,
      onFailure: (error) {
        room.reportLifecycleFailure(error);
      },
    );
  }
}
