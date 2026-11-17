import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_realtime_room_ui/flutter_realtime_room_ui.dart'
    as room_ui;
import 'package:flutter_realtime_room_ui/flutter_realtime_room_ui.dart'
    show RealtimeRoomUiAction;
import 'package:flutter_realtime_live_preset/flutter_realtime_live_preset.dart';
import 'package:flutter_realtime_classroom_preset/flutter_realtime_classroom_preset.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart'
    show Cleanup, MediaRole, RealtimeRoomControls;

class RealtimeRoomUiController extends room_ui.RealtimeRoomUiController {
  RealtimeRoomUiController(
    super.room, {
    super.initialCameraPosition,
    super.onActionError,
  }) {
    _classroomSubscription = room.classroom?.states
        .map<Object?>((_) => null)
        .listen((_) {
          if (!isDisposed) notifyListeners();
        });
    _classroomErrors = room.classroom?.errors.listen(reportActionError);
    _liveErrors = room.liveInteractions?.errors.listen(reportActionError);
    _liveState = room.liveInteractions?.state;
    _liveSubscription = room.liveInteractions?.states.listen((state) {
      if (isDisposed) return;
      _liveState = state;
      _syncCohostMediaRole(state);
      notifyListeners();
    });
    if (_liveState != null) {
      _syncCohostMediaRole(_liveState!);
    }
    _likeSubscription = room.liveInteractions?.likes.listen((event) {
      if (isDisposed) return;
      _receivedLikeCount += event.quantity;
      notifyListeners();
    });
  }

  Future<void> publishClassroomActivity({
    required ClassroomActivityKind kind,
    required String title,
    required List<String> options,
    int? correctOption,
  }) async {
    final classroom = room.classroom;
    if (classroom == null ||
        classroomState?.capabilities.canPublishTools != true) {
      return;
    }
    await execute(
      RealtimeRoomUiAction.classroom,
      () => classroom.publishActivity(
        kind: kind,
        title: title,
        options: options,
        correctOption: correctOption,
      ),
    );
  }

  StreamSubscription<Object?>? _classroomSubscription;
  StreamSubscription<Object>? _classroomErrors, _liveErrors;
  StreamSubscription<LiveInteractionState>? _liveSubscription;
  StreamSubscription<LiveLikeEvent>? _likeSubscription;
  LiveInteractionState? _liveState;
  int _receivedLikeCount = 0;
  bool _syncingCohostRole = false;
  LiveInteractionState? get liveState => _liveState;
  int get receivedLikeCount => _receivedLikeCount;
  bool get canRequestCohost =>
      _liveState?.cohostSupported == true &&
      room.media.role != MediaRole.host &&
      _liveState?.selfUserId != _liveState?.recipientId;
  LiveCohostStatus get selfCohostStatus =>
      _liveState?.selfCohostStatus ?? LiveCohostStatus.none;

  void _syncCohostMediaRole(LiveInteractionState state) {
    if (_syncingCohostRole || isDisposed || !room.canSwitchMediaRole) return;
    if (room.media.role == MediaRole.host) return;
    final target =
        (state.selfCohostStatus == LiveCohostStatus.approved ||
            state.selfCohostStatus == LiveCohostStatus.active)
        ? MediaRole.participant
        : MediaRole.viewer;
    if (room.media.role == target) return;
    _syncingCohostRole = true;
    unawaited(_applyCohostMediaRole(target));
  }

  Future<void> _applyCohostMediaRole(MediaRole target) async {
    try {
      await room.switchMediaRole(target);
      if (!isDisposed) {
        notifyListeners();
      }
    } catch (error) {
      reportActionError(error);
    } finally {
      _syncingCohostRole = false;
      final latest = _liveState;
      if (!isDisposed && latest != null) {
        _syncCohostMediaRole(latest);
      }
    }
  }
  @override
  bool get canUseMicrophone => super.canUseMicrophone && _canSpeak;
  bool get _canSpeak {
    final classroom = room.classroom;
    if (classroom == null || !snapshot.localMuted) return true;
    final state = classroom.state;
    if (state?.isTeacher == true || room.hasOwnerCredential) {
      return true;
    }
    if (state == null) return false;
    return state.students.any(
      (student) => student.userId == state.selfUserId && student.canSpeak,
    );
  }

  Future<void> answerClassroomActivity(String activityId, int option) async {
    final classroom = room.classroom;
    if (classroom == null || classroomState?.capabilities.canUseTools != true) {
      return;
    }
    await execute(
      RealtimeRoomUiAction.classroom,
      () => classroom.answerActivity(activityId, option),
    );
  }

  Future<void> closeClassroomActivity(String activityId) async {
    final classroom = room.classroom;
    if (classroom == null ||
        classroomState?.capabilities.canPublishTools != true) {
      return;
    }
    await execute(
      RealtimeRoomUiAction.classroom,
      () => classroom.closeActivity(activityId),
    );
  }

  ClassroomState? get classroomState => room.classroom?.state;
  bool get canRaiseHand => classroomState?.capabilities.canRaiseHand == true;
  bool get canManageQuestions =>
      classroomState?.capabilities.canManageQuestions == true;
  bool get canAskQuestion =>
      classroomState?.capabilities.canAskQuestion == true;
  bool get canGrantSpeak => classroomState?.capabilities.canGrantSpeak == true;
  bool get canViewClassroomRoster =>
      classroomState?.capabilities.canViewRoster == true;
  bool get canManageClassroomNotes =>
      classroomState?.isTeacher == true && classroomState?.notes != null;

  Future<void> addClassroomNote(String text, {bool chapter = false}) async {
    if (!canManageClassroomNotes) return;
    await execute(
      RealtimeRoomUiAction.classroom,
      () => room.classroom!.addNote(text, chapter: chapter),
    );
  }

  Future<void> updateClassroomNote(String id, String text) async {
    if (!canManageClassroomNotes) return;
    await execute(
      RealtimeRoomUiAction.classroom,
      () => room.classroom!.updateNote(id, text),
    );
  }

  Future<void> deleteClassroomNote(String id) async {
    if (!canManageClassroomNotes) return;
    await execute(
      RealtimeRoomUiAction.classroom,
      () => room.classroom!.deleteNote(id),
    );
  }

  Future<void> setHandRaised(bool raised) async {
    final classroom = room.classroom;
    if (classroom == null || !canRaiseHand) return;
    await execute(
      RealtimeRoomUiAction.classroom,
      () => raised ? classroom.raiseHand() : classroom.lowerHand(),
    );
  }

  Future<void> setStudentCanSpeak(
    String userId, {
    required bool canSpeak,
  }) async {
    final classroom = room.classroom;
    if (classroom == null || !canGrantSpeak) return;
    await execute(
      RealtimeRoomUiAction.classroom,
      () => canSpeak
          ? classroom.grantSpeak(userId)
          : classroom.revokeSpeak(userId),
    );
  }

  Future<void> askClassroomQuestion(String question) async {
    final classroom = room.classroom;
    if (classroom == null || !canAskQuestion || question.trim().isEmpty) return;
    await execute(
      RealtimeRoomUiAction.classroom,
      () => classroom.askQuestion(question.trim()),
    );
  }

  Future<void> answerClassroomQuestion(String id, String answer) async {
    final classroom = room.classroom;
    if (classroom == null || !canManageQuestions || answer.trim().isEmpty) {
      return;
    }
    await execute(
      RealtimeRoomUiAction.classroom,
      () => classroom.answerQuestion(id, answer.trim()),
    );
  }

  Future<void> resolveClassroomQuestion(String id) async {
    final classroom = room.classroom;
    if (classroom == null || !canManageQuestions) return;
    await execute(
      RealtimeRoomUiAction.classroom,
      () => classroom.resolveQuestion(id),
    );
  }

  Future<void> sendClassroomFeedback(ClassroomFeedbackKind kind) async {
    final classroom = room.classroom;
    if (classroom == null ||
        classroomState?.capabilities.canSendFeedback != true) {
      return;
    }
    await execute(
      RealtimeRoomUiAction.classroom,
      () => classroom.sendFeedback(kind),
    );
  }

  Future<void> sendLiveLike() async {
    final live = room.liveInteractions;
    if (live == null) return;
    await execute(RealtimeRoomUiAction.liveLike, live.sendLike);
  }

  Future<void> requestCohost() async {
    final live = room.liveInteractions;
    if (live == null || !canRequestCohost) return;
    await execute(RealtimeRoomUiAction.liveCohost, live.requestCohost);
  }

  Future<void> cancelCohost() async {
    final live = room.liveInteractions;
    if (live == null || !canRequestCohost) return;
    await execute(RealtimeRoomUiAction.liveCohost, live.cancelCohost);
  }

  Future<void> respondCohost(String userId, String action) async {
    final live = room.liveInteractions;
    if (live == null || room.media.role != MediaRole.host) return;
    await execute(
      RealtimeRoomUiAction.liveCohost,
      () => live.respondCohost(userId, action),
    );
  }

  @override
  Future<void> releaseResources() async {
    // Local subscription cancellation has no external I/O or acquisition.
    final cleanup = Cleanup(timeout: null);
    final classroomRelease = cleanup.run('room.ui.classroom', () async {
      await _classroomSubscription?.cancel();
      await _classroomErrors?.cancel();
      await _liveErrors?.cancel();
    });
    final liveRelease = cleanup.run('room.ui.live', () async {
      await _liveSubscription?.cancel();
    });
    final likeRelease = cleanup.run('room.ui.likes', () async {
      await _likeSubscription?.cancel();
    });
    final baseRelease = cleanup.run('room.ui.base', super.releaseResources);
    await Future.wait([
      classroomRelease,
      liveRelease,
      likeRelease,
      baseRelease,
    ]);
    cleanup.finish(domain: 'room.ui');
  }
}

/// Full-UI scope adds only the explicitly selected business presentation.
class RealtimeRoomUiScope extends room_ui.RealtimeRoomUiScope {
  RealtimeRoomUiScope({
    super.key,
    required super.room,
    required super.child,
    RealtimeRoomUiController? controller,
    super.onActionError,
  }) : super(
         controller: controller,
         controllerFactory: (room) =>
             RealtimeRoomUiController(room, onActionError: onActionError),
       );
  static RealtimeRoomUiController of(BuildContext context) =>
      room_ui.RealtimeRoomUiScope.of(context) as RealtimeRoomUiController;
  static RealtimeRoomUiController? maybeOf(BuildContext context) =>
      room_ui.RealtimeRoomUiScope.maybeOf(context) as RealtimeRoomUiController?;
}
