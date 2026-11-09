import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';
import 'package:flutter_realtime_sdk_ui/src/prepare_room_page.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/meeting_sharing_fixture.dart';

void main() {
  test('room entry prepares the selected effect only once', () async {
    final room = _Room();
    addTearDown(room.dispose);
    await prepareRoomPage(
      room,
      const MediaLocalPreviewSettings(cameraEnabled: false),
      isCurrent: () => true,
    );
    expect(room.preparedCameraChoices, [false]);
    expect(
      room.effectSelections,
      0,
      reason: 'room.prepareVideoEffects already applied the background, '
          'so native/RTC source update must not run twice on entry',
    );
  });

  test('room entry identifies native effect preparation errors', () async {
    final room = _Room()
      ..pending = Future<void>.error(StateError('The update failed.'));
    addTearDown(room.dispose);
    await expectLater(
      prepareRoomPage(
        room,
        const MediaLocalPreviewSettings(cameraEnabled: false),
        isCurrent: () => true,
      ),
      throwsA(
        isA<RealtimeException>()
            .having((error) => error.operation, 'operation',
                'prepareVideoEffects'),
      ),
    );
  });

  for (final live in [false, true]) {
    testWidgets(
      '${live ? 'live' : 'meeting'} preparation times out visibly and retry succeeds without late camera enable',
      (tester) async {
        final gate = Completer<void>();
        final room = _Room()..pending = gate.future;
        addTearDown(room.dispose);
        const settings = MediaLocalPreviewSettings(cameraEnabled: true);
        await tester.pumpWidget(
          MaterialApp(
            home: live
                ? RealtimeLivePage(room: room, initialSettings: settings)
                : RealtimeMeetingPage(room: room, initialSettings: settings),
          ),
        );
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        await tester.pump(const Duration(seconds: 16));
        await tester.pump();
        expect(
          find.textContaining('preparing the room timed out'),
          findsOneWidget,
        );
        expect(room.diagnostics.last.code, RealtimeErrorCode.timeout);
        expect(room.preparedCameraChoices, [false]);
        room.pending = null;
        await tester.tap(find.text(const RealtimeStrings.en().runAgain));
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        final effects = room.effectSelections;
        gate.complete();
        await tester.pumpAndSettle();
        expect(
          room.effectSelections,
          effects,
          reason:
              'the expired preparation must stop before applying later settings',
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('shared content cannot keep meeting entry loading indefinitely', (
    tester,
  ) async {
    final shared = _Shared();
    final room = _Room(plugins: [_SharedPlugin(shared)]);
    addTearDown(room.dispose);
    await room.initialize();
    await tester.pumpWidget(MaterialApp(home: RealtimeMeetingPage(room: room)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    await tester.pump();
    expect(find.textContaining('preparing the room timed out'), findsOneWidget);
    expect(room.diagnostics.last.operation, 'prepareSharedContent');
    shared.gate.complete();
    await tester.tap(find.text(const RealtimeStrings.en().runAgain));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'a completed shared-content failure is surfaced with its stage and cause',
    () async {
      final shared = _Shared()..failure = StateError('backend unavailable');
      shared.gate.complete();
      final room = _Room(plugins: [_SharedPlugin(shared)]);
      addTearDown(room.dispose);
      await room.initialize();
      await expectLater(
        prepareRoomPageWithDeadline(
          room,
          null,
          isCurrent: () => true,
          startSharedContent: true,
        ),
        throwsA(
          isA<RealtimeException>()
              .having((e) => e.operation, 'operation', 'prepareSharedContent')
              .having((e) => e.cause, 'cause', shared.failure),
        ),
      );
    },
  );
}

class _Room extends RealtimeRoom {
  _Room({List<RealtimeFeaturePlugin<Object>> plugins = const []})
    : super(
        media: MediaRoomSession.direct(
          roomCode: 'one',
          participantId: 'self',
          session: SharingMedia(),
        ),
        renderer: const SharingRenderer(),
        disposeClients: () {},
        featurePlugins: plugins,
      );
  Future<void>? pending;
  int effectSelections = 0;
  final preparedCameraChoices = <bool>[];
  @override
  Future<void> prepareVideoEffects(MediaLocalPreviewSettings settings) async {
    preparedCameraChoices.add(settings.cameraEnabled);
    await pending;
  }

  @override
  Future<void> setBackgroundEffect(MediaBackgroundEffect effect) async {
    effectSelections++;
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {}
}

class _Shared extends Fake implements SharedContentController {
  final gate = Completer<void>();
  Object? failure;
  @override
  SharedContentState? get content => null;
  @override
  Stream<Object?> get stageUpdates => const Stream.empty();
  @override
  Stream<SharedContentStatus> get statuses => const Stream.empty();
  @override
  bool get supported => false;
  @override
  Future<void> start() => gate.future;
  @override
  SharedContentStatus get status => SharedContentStatus(
    content: null,
    busy: false,
    captureActive: false,
    error: failure,
  );
  @override
  Future<void> dispose() async {}
}

class _Feature extends Fake implements SharedContentRoomFeature {
  _Feature(this.sharedContent);
  @override
  final SharedContentController sharedContent;
}

class _SharedPlugin extends RealtimeFeaturePlugin<SharedContentRoomFeature> {
  _SharedPlugin(this.shared);
  final SharedContentController shared;
  @override
  RealtimeFeatureKey<SharedContentRoomFeature> get key =>
      SharedContentPreset.featureKey;
  @override
  SharedContentRoomFeature attach(RealtimeFeatureContext context) =>
      _Feature(shared);
  @override
  Future<void> detach(SharedContentRoomFeature feature) async {}
}
