import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_room_ui/flutter_realtime_room_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'meeting owner exit closes the room even with participant media role',
    () async {
      for (final role in [MediaRole.participant, MediaRole.host]) {
        final media = _FakeMediaSession(role: role);
        final management = _FakeRoomManagement();
        final presence = _FakeRoomPresence();
        final room = RealtimeRoom(
          media: MediaRoomSession.attach(
            roomCode: 'meeting-room',
            participantId: 'creator',
            roomOwnerCredential: role == MediaRole.participant
                ? 'owner-key'
                : null,
            session: media,
            management: management,
            presence: presence,
            heartbeatInterval: Duration.zero,
            backendMetadata: const {
              'roomMode': 'meeting',
              'meetingMode': 'standard',
            },
          ),
          renderer: const _FakeRenderer(),
          disposeClients: () {},
        );
        final controller = RealtimeRoomUiController(room);
        await controller.leave();
        expect(
          management.closeCalls,
          1,
          reason: 'meeting owner must end the room',
        );
        expect(
          presence.leaveCalls,
          0,
          reason: 'no redundant leave after closing',
        );
        expect(media.disposeCalls, 1);
        await controller.close();
      }
    },
  );

  test('ordinary participant exit never closes the meeting room', () async {
    final media = _FakeMediaSession(role: MediaRole.participant);
    final management = _FakeRoomManagement();
    final presence = _FakeRoomPresence();
    final room = RealtimeRoom(
      media: MediaRoomSession.attach(
        roomCode: 'meeting-room',
        participantId: 'viewer',
        session: media,
        management: management,
        presence: presence,
        heartbeatInterval: Duration.zero,
        backendMetadata: const {
          'roomMode': 'meeting',
          'meetingMode': 'standard',
        },
      ),
      renderer: const _FakeRenderer(),
      disposeClients: () {},
    );
    final controller = RealtimeRoomUiController(room);
    await controller.leave();
    expect(management.closeCalls, 0);
    expect(presence.leaveCalls, 1);
    expect(media.disposeCalls, 1);
    await controller.close();
  });

  test(
    'owner cannot silently self-leave when room closure is unavailable',
    () async {
      final media = _FakeMediaSession(role: MediaRole.host);
      final room = RealtimeRoom(
        media: MediaRoomSession.direct(
          roomCode: 'room',
          participantId: 'host',
          session: media,
        ),
        renderer: const _FakeRenderer(),
        disposeClients: () {},
      );
      final controller = RealtimeRoomUiController(room);
      await expectLater(
        controller.leave(),
        throwsA(
          isA<RealtimeException>().having(
            (e) => e.code,
            'code',
            RealtimeErrorCode.unsupportedFeature,
          ),
        ),
      );
      expect(media.disposeCalls, 0);
      await controller.close();
      await room.dispose();
    },
  );

  test(
    'closed UI controller rejects new actions instead of false success',
    () async {
      final media = _FakeMediaSession(role: MediaRole.participant);
      final room = RealtimeRoom(
        media: MediaRoomSession.direct(
          roomCode: 'room',
          participantId: 'self',
          session: media,
        ),
        renderer: const _FakeRenderer(),
        disposeClients: () {},
      );
      await room.initialize();
      final controller = RealtimeRoomUiController(room);
      await controller.close();
      var invoked = false;
      await expectLater(
        controller.execute(RealtimeRoomUiAction.camera, () async {
          invoked = true;
        }),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.invalidState,
          ),
        ),
      );
      expect(invoked, isFalse);
      await room.dispose();
    },
  );

  test(
    'duplicate SDK UI command awaits the first operation and its failure',
    () async {
      final media = _FakeMediaSession(role: MediaRole.participant);
      final room = RealtimeRoom(
        media: MediaRoomSession.direct(
          roomCode: 'room',
          participantId: 'self',
          session: media,
        ),
        renderer: const _FakeRenderer(),
        disposeClients: () {},
      );
      await room.initialize();
      final controller = RealtimeRoomUiController(room);
      final gate = Completer<void>();
      var commands = 0;
      Future<void> task() async {
        commands++;
        await gate.future;
        throw StateError('provider failed');
      }

      final first = controller.execute(RealtimeRoomUiAction.microphone, task);
      final second = controller.execute(RealtimeRoomUiAction.microphone, task);
      Object? secondFailure;
      var secondCompleted = false;
      unawaited(
        second.then(
          (_) => secondCompleted = true,
          onError: (Object error) {
            secondFailure = error;
            secondCompleted = true;
          },
        ),
      );
      await pumpEventQueue();
      expect(commands, 1, reason: 'duplicate actions should coalesce');
      expect(
        secondCompleted,
        isFalse,
        reason: 'the second caller must await the provider operation',
      );
      gate.complete();
      await expectLater(first, throwsA(isA<RealtimeException>()));
      await pumpEventQueue();
      expect(
        secondFailure,
        isA<RealtimeException>(),
        reason: 'all callers must observe the same failure',
      );
      await controller.close();
      await room.dispose();
    },
  );

  test(
    'leave on previously closed UI cannot silently claim room disposal',
    () async {
      final media = _FakeMediaSession(role: MediaRole.participant);
      final room = RealtimeRoom(
        media: MediaRoomSession.direct(
          roomCode: 'room',
          participantId: 'self',
          session: media,
        ),
        renderer: const _FakeRenderer(),
        disposeClients: () {},
      );
      await room.initialize();
      final controller = RealtimeRoomUiController(room);
      await controller.close();
      await expectLater(
        controller.leave(closeForEveryone: false),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.invalidState,
          ),
        ),
      );
      expect(
        media.disposeCalls,
        0,
        reason: 'closing only UI must not dispose the underlying room',
      );
      await room.dispose();
    },
  );

  test('concurrent leave callers await the same room disposal', () async {
    final media = _FakeMediaSession(role: MediaRole.participant);
    final gate = Completer<void>();
    media.disposeGate = gate;
    final room = RealtimeRoom(
      media: MediaRoomSession.direct(
        roomCode: 'room',
        participantId: 'self',
        session: media,
      ),
      renderer: const _FakeRenderer(),
      disposeClients: () {},
    );
    await room.initialize();
    final controller = RealtimeRoomUiController(room);
    final first = controller.leave(closeForEveryone: false);
    final second = controller.leave(closeForEveryone: false);
    var secondCompleted = false;
    unawaited(second.then((_) => secondCompleted = true));
    await pumpEventQueue();
    expect(
      secondCompleted,
      isFalse,
      reason: 'a duplicate leave must not report success before cleanup',
    );
    gate.complete();
    await Future.wait([first, second]);
    expect(media.disposeCalls, 1);
    // The host still owns the UI until it navigates away. Completing
    // leave() may not dispose a notifier while its widgets are mounted.
    expect(controller.isDisposed, isFalse);
    await controller.leave(closeForEveryone: false);
    expect(media.disposeCalls, 1);
    await controller.close();
    expect(controller.isDisposed, isTrue);
  });

  test(
    'the same failure reaches the host once and only successful commands emit completion',
    () async {
      final media = _FakeMediaSession(role: MediaRole.participant);
      final room = RealtimeRoom(
        media: MediaRoomSession.direct(
          roomCode: 'room',
          participantId: 'self',
          session: media,
        ),
        renderer: const _FakeRenderer(),
        disposeClients: () {},
      );
      await room.initialize();
      final failures = <RealtimeException>[];
      final controller = RealtimeRoomUiController(
        room,
        onActionError: failures.add,
      );
      const failure = RealtimeException(
        code: RealtimeErrorCode.network,
        message: 'test.failure',
      );
      controller.reportActionError(failure);
      controller.reportActionError(failure);
      expect(failures, hasLength(1));
      final completions = <RealtimeRoomUiAction>[];
      var sequence = 0;
      void onCompleted() {
        final value = controller.lastCompletedAction;
        if (value != null && value.sequence > sequence) {
          sequence = value.sequence;
          completions.add(value.action);
        }
      }

      controller.addListener(onCompleted);
      await controller.execute(
        RealtimeRoomUiAction.participantManagement,
        () async {},
      );
      await expectLater(
        controller.execute(
          RealtimeRoomUiAction.microphone,
          () async => throw failure,
        ),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.network,
          ),
        ),
      );
      await pumpEventQueue();
      expect(completions, [RealtimeRoomUiAction.participantManagement]);
      controller.removeListener(onCompleted);
      await controller.close();
      await room.dispose();
    },
  );

  testWidgets('remounting a borrowed controller never closes its room', (
    tester,
  ) async {
    final media = _FakeMediaSession(role: MediaRole.participant);
    final room = RealtimeRoom(
      media: MediaRoomSession.direct(
        roomCode: 'room',
        participantId: 'self',
        session: media,
      ),
      renderer: const _FakeRenderer(),
      disposeClients: () {},
    );
    await tester.runAsync(room.initialize);
    final controller = RealtimeRoomUiController(room);
    for (var mount = 0; mount < 2; mount++) {
      await tester.pumpWidget(
        MaterialApp(
          home: RealtimeRoomUiScope(
            room: room,
            controller: controller,
            child: const SizedBox(),
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox());
      expect(controller.isDisposed, isFalse);
      expect(media.disposeCalls, 0);
    }
    final closing = controller.close();
    expect(identical(closing, controller.close()), isTrue);
    await tester.runAsync(() => closing);
    expect(media.disposeCalls, 0);
    await tester.runAsync(room.dispose);
    expect(media.disposeCalls, 1);
  });
  testWidgets('the host receives action failure without a forced error popup', (
    tester,
  ) async {
    final media = _FakeMediaSession(role: MediaRole.participant);
    final room = RealtimeRoom(
      media: MediaRoomSession.direct(
        roomCode: 'room',
        participantId: 'self',
        session: media,
      ),
      renderer: const _FakeRenderer(),
      disposeClients: () {},
    );
    await tester.runAsync(room.initialize);
    final failures = <RealtimeException>[];
    final controller = RealtimeRoomUiController(
      room,
      onActionError: failures.add,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeRoomUiScope(
          room: room,
          controller: controller,
          child: const Scaffold(
            body: RealtimeMediaActionButton(
              action: RealtimeRoomUiAction.microphone,
              label: 'Microphone',
              icon: Icons.mic,
            ),
          ),
        ),
      ),
    );
    media.failMute = true;
    await tester.tap(find.text('Microphone'));
    await tester.pump();
    expect(failures, hasLength(1));
    expect(find.byType(SnackBar), findsNothing);
    expect(controller.isPending(RealtimeRoomUiAction.microphone), isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(controller.close);
    await tester.runAsync(room.dispose);
  });
  test(
    'runtime and media failures reach the host once and stop after UI disposal',
    () async {
      final media = _FakeMediaSession(role: MediaRole.participant);
      final room = RealtimeRoom(
        media: MediaRoomSession.direct(
          roomCode: 'one',
          participantId: 'self',
          session: media,
        ),
        renderer: const _FakeRenderer(),
        disposeClients: () {},
      );
      final failures = <RealtimeException>[];
      final controller = RealtimeRoomUiController(
        room,
        onActionError: failures.add,
      );
      const network = RealtimeException(
        code: RealtimeErrorCode.network,
        message: 'media.web.join',
        cause: 'test-private-cause',
      );
      const timeout = RealtimeException(
        code: RealtimeErrorCode.timeout,
        message: 'videoEffects.processFrame',
      );
      media._events.add(const MediaFailureEvent(network));
      room.reportLifecycleFailure(timeout);
      await pumpEventQueue();
      expect(failures.map((e) => e.code), [
        RealtimeErrorCode.timeout,
        RealtimeErrorCode.network,
      ]);
      expect(failures.last.cause, 'test-private-cause');
      expect(controller.error?.code, RealtimeErrorCode.network);
      await controller.close();
      room.reportLifecycleFailure(timeout);
      await pumpEventQueue();
      expect(failures, hasLength(2));
      expect(media.disposeCalls, 0);
      await room.dispose();
    },
  );
}

class _FakeRoomPresence implements MediaRoomPresence {
  int leaveCalls = 0;
  @override
  Future<void> heartbeat(String roomCode, {String? participantId}) async {}
  @override
  Future<void> leave(String roomCode, {String? participantId}) async {
    leaveCalls++;
  }
}

class _FakeRoomManagement implements MediaRoomManagement {
  int closeCalls = 0;
  @override
  Future<void> closeRoomManaged(
    String roomCode, {
    required String requesterParticipantId,
    String? participantCredential,
    String? roomOwnerCredential,
  }) async {
    closeCalls++;
  }

  @override
  Future<List<MediaRoomParticipantSummary>> listParticipants(
    String roomCode, {
    required String requesterParticipantId,
    String? participantCredential,
    String? roomOwnerCredential,
  }) async => const [];
  @override
  Future<void> removeParticipant(
    String roomCode, {
    required String requesterParticipantId,
    required String targetParticipantId,
    String? participantCredential,
    String? roomOwnerCredential,
  }) async {}
}

class _FakeRenderer extends MediaTrackRenderer {
  const _FakeRenderer();
  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      const SizedBox.expand();
}

class _FakeMediaSession extends InteractiveMediaSession {
  _FakeMediaSession({required this.role});
  @override
  final MediaRole role;
  final _snapshots = StreamController<MediaSnapshot>.broadcast();
  final _states = StreamController<MediaSessionState>.broadcast();
  final _events = StreamController<MediaEvent>.broadcast();
  MediaSnapshot _snapshot = MediaSnapshot(
    state: MediaSessionState.connected,
    localMuted: true,
    capabilities: const MediaCapabilities.meeting(),
    participants: const [
      MediaParticipant(id: 'self', displayName: 'Local', isLocal: true),
    ],
  );
  bool failMute = false;
  int muteCalls = 0;
  int cameraCalls = 0;
  final cameraPositions = <MediaCameraPosition>[];
  int disposeCalls = 0;
  Completer<void>? disposeGate;

  @override
  String get providerId => 'fake';
  @override
  MediaCapabilities get capabilities => snapshot.capabilities;
  @override
  MediaSessionState get state => snapshot.state;
  @override
  MediaSnapshot get snapshot => _snapshot;
  @override
  Stream<MediaSessionState> get states => _states.stream;
  @override
  Stream<MediaSnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<MediaEvent> get events => _events.stream;

  void _emit(MediaSnapshot snapshot) {
    _snapshot = snapshot;
    _snapshots.add(snapshot);
    _states.add(snapshot.state);
  }

  @override
  Future<void> join(MediaJoinInfo joinInfo) async {}
  @override
  Future<void> leave() async {}
  @override
  Future<void> dispose() async {
    disposeCalls++;
    await disposeGate?.future;
    await _snapshots.close();
    await _states.close();
    await _events.close();
  }

  @override
  Future<void> setMuted(bool muted) async {
    muteCalls++;
    if (failMute) throw StateError('test.failure');
    _emit(snapshot.copyWith(localMuted: muted));
  }

  @override
  Future<void> toggleMute() => setMuted(!snapshot.localMuted);
  @override
  Future<void> setVideoEnabled(bool enabled) async {
    cameraCalls++;
    _emit(snapshot.copyWith(localVideoEnabled: enabled));
  }

  @override
  Future<void> setScreenShareEnabled(bool enabled) async {
    _emit(snapshot.copyWith(localScreenShareEnabled: enabled));
  }

  @override
  Future<void> switchCamera(MediaCameraPosition position) async =>
      cameraPositions.add(position);
  @override
  Future<List<MediaAudioDevice>> listAudioDevices() async => const [
    MediaAudioDevice(label: 'Speaker', type: MediaAudioDeviceType.speaker),
  ];
  @override
  Future<void> selectAudioDevice(MediaAudioDevice device) async {}
  @override
  Future<void> sendMessage(String message, {String topic = 'chat'}) async {}
}
