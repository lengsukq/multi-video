import 'dart:async';

import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_classroom_preset/flutter_realtime_classroom_preset.dart';
import 'package:flutter_realtime_shared_content_preset/flutter_realtime_shared_content_preset.dart';

/// Bounds preparation and invalidates late continuations after a timeout.
Future<void> prepareRoomPageWithDeadline(
  RealtimeRoom room,
  MediaLocalPreviewSettings? settings, {
  required bool Function() isCurrent,
  bool startSharedContent = false,
  Duration timeout = const Duration(seconds: 15),
}) async {
  var active = true;
  bool current() => active && isCurrent();
  var stage = 'prepareMedia';
  try {
    await prepareRoomPage(room, settings, isCurrent: current).timeout(timeout);
    if (!current() || !startSharedContent) return;
    final shared = room.sharedContent;
    if (shared == null) return;
    stage = 'prepareSharedContent';
    await shared.start().timeout(timeout);
    if (!current()) return;
    final error = shared.status.error;
    if (error != null) throw error;
  } catch (error, stack) {
    active = false;
    final failure = error is TimeoutException
        ? RealtimeException(
            code: RealtimeErrorCode.timeout,
            message: 'roomPage.$stage',
            domain: 'roomPage',
            operation: stage,
            providerId: room.providerId,
            recoverable: true,
            suggestedAction: 'retry',
            cause: error,
            stackTrace: stack,
          )
        : normalizeRealtimeException(
            error,
            domain: 'roomPage',
            operation: stage,
            providerId: room.providerId,
            stackTrace: stack,
          );
    room.reportLifecycleFailure(failure);
    Error.throwWithStackTrace(failure, stack);
  }
}

/// Applies the same Pre-Join choices for both built-in room pages.
Future<void> prepareRoomPage(
  RealtimeRoom room,
  MediaLocalPreviewSettings? settings, {
  required bool Function() isCurrent,
}) async {
  if (settings == null || room.media.role == MediaRole.viewer) return;
  // Preparation must not publish on its own: a timed-out operation can still
  // finish later. Only the current settings application may enable the camera.
  try {
    await room.prepareVideoEffects(settings.copyWith(cameraEnabled: false));
  } catch (error, stack) {
    Error.throwWithStackTrace(
      normalizeRealtimeException(
        error,
        domain: 'roomPage',
        operation: 'prepareVideoEffects',
        providerId: room.providerId,
        stackTrace: stack,
      ),
      stack,
    );
  }
  if (!isCurrent()) return;
  await InitialMediaSettingsController().apply(
    session: room.media.session,
    effects: room,
    setCameraEnabled: (enabled) async {
      if (room.media.snapshot.localVideoEnabled != enabled) {
        await room.setCameraEnabled(enabled);
      }
    },
    settings: settings,
    backgroundAlreadyPrepared: true,
    isCurrent: isCurrent,
    canEnableMicrophone: () {
      final classroom = room.classroom;
      if (classroom == null) return true;
      final state = classroom.state;
      if (state?.isTeacher == true || room.media.roomOwnerCredential != null) {
        return true;
      }
      return state?.students.any(
            (student) => student.userId == state.selfUserId && student.canSpeak,
          ) ??
          false;
    },
    onError: (error) => throw error,
  );
}
