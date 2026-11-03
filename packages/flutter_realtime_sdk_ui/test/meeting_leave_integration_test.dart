import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';

import 'support/meeting_sharing_fixture.dart';

void main() {
  testWidgets(
    'owned room scope detaches listeners before disposing controller on room swap and unmount',
    (tester) async {
      final first = await MeetingSharingFixture.create(teaching: false);
      final second = await MeetingSharingFixture.create(teaching: false);
      addTearDown(first.room.dispose);
      addTearDown(second.room.dispose);
      Widget page(RealtimeRoom room) => MaterialApp(
        home: RealtimeRoomUiScope(
          room: room,
          child: const Scaffold(body: _ControllerTransitionProbe()),
        ),
      );
      await tester.pumpWidget(page(first.room));
      final former = RealtimeRoomUiScope.of(
        tester.element(find.byType(_ControllerTransitionProbe)),
      );
      await tester.pumpWidget(page(second.room));
      final current = RealtimeRoomUiScope.of(
        tester.element(find.byType(_ControllerTransitionProbe)),
      );
      expect(identical(former, current), isFalse);
      expect(former.isDisposed, isTrue);
      expect(current.isDisposed, isFalse);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(current.isDisposed, isTrue);
      expect(tester.takeException(), isNull);
      expect(first.media.changes.isClosed, isFalse);
      expect(second.media.changes.isClosed, isFalse);
    },
  );

  testWidgets(
    'ownership transfer to the same externally supplied controller keeps it alive',
    (tester) async {
      final fixture = await MeetingSharingFixture.create(teaching: false);
      addTearDown(fixture.room.dispose);
      Widget page({RealtimeRoomUiController? controller}) => MaterialApp(
        home: RealtimeRoomUiScope(
          room: fixture.room,
          controller: controller,
          child: const Scaffold(body: _ControllerTransitionProbe()),
        ),
      );
      await tester.pumpWidget(page());
      final original = RealtimeRoomUiScope.of(
        tester.element(find.byType(_ControllerTransitionProbe)),
      );
      await tester.pumpWidget(page(controller: original));
      expect(original.isDisposed, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(
        original.isDisposed,
        isFalse,
        reason: 'borrowed controller lifetime belongs to the host',
      );
      await tester.runAsync(original.close);
      expect(original.isDisposed, isTrue);
    },
  );

  testWidgets(
    'room shell keeps the stage visible when a mobile header becomes extremely tall',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const stageKey = ValueKey('room-stage');
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RealtimeRoomShell(
              compact: true,
              header: SizedBox(height: 100000, child: Text('Long diagnostic')),
              tabletRail: SizedBox(height: 44, child: Text('Tools')),
              stage: ColoredBox(
                key: stageKey,
                color: Colors.black,
                child: SizedBox.expand(),
              ),
              dock: SizedBox(height: 68, child: Text('Dock')),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(stageKey)).height, greaterThan(100));
      expect(find.text('Dock'), findsOneWidget);
      expect(
        tester.getSize(find.byType(RealtimeRoomShell)).height,
        closeTo(720, 1),
      );
    },
  );

  testWidgets('confirmed leave does not dispose a room after button unmount', (
    tester,
  ) async {
    final fixture = await MeetingSharingFixture.create(teaching: false);
    addTearDown(fixture.room.dispose);
    final controller = RealtimeRoomUiController(fixture.room);
    addTearDown(controller.close);
    final confirm = Completer<bool>();
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeRoomUiScope(
          room: fixture.room,
          controller: controller,
          child: Scaffold(
            body: RealtimeLeaveButton(onConfirm: (_) => confirm.future),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.call_end_rounded));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    confirm.complete(true);
    await tester.pump();
    expect(fixture.media.changes.isClosed, isFalse);
    expect(tester.takeException(), isNull);
    await tester.runAsync(controller.close);
    await tester.runAsync(fixture.room.dispose);
  });

  testWidgets('meeting mobile drawer reuses the page room controller', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await MeetingSharingFixture.create(teaching: false);
    addTearDown(fixture.room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: RealtimeMeetingPage(room: fixture.room, showClassroom: false),
      ),
    );
    await tester.pumpAndSettle();
    final pageController = RealtimeRoomUiScope.of(
      tester.element(find.byType(RealtimeRoomShell)),
    );
    await tester.tap(find.byTooltip('Participants').first);
    await tester.pumpAndSettle();
    final drawerController = RealtimeRoomUiScope.of(
      tester.element(find.byType(RealtimeManagedParticipantList)),
    );
    expect(identical(pageController, drawerController), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(fixture.room.dispose);
  });

  testWidgets('SDK overlays preserve a borrowed controller across Navigator', (
    tester,
  ) async {
    final fixture = await MeetingSharingFixture.create(teaching: false);
    addTearDown(fixture.room.dispose);
    final controller = RealtimeRoomUiController(fixture.room);
    addTearDown(controller.close);
    RealtimeRoomUiController? sheetController;
    RealtimeRoomUiController? dialogController;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (hostContext) => RealtimeRoomUiScope(
              room: fixture.room,
              controller: controller,
              child: Column(
                children: [
                  TextButton(
                    onPressed: () => showRealtimeRoomUiBottomSheet<void>(
                      hostContext,
                      controller: controller,
                      builder: (sheetContext) {
                        sheetController = RealtimeRoomUiScope.of(sheetContext);
                        return TextButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          child: const Text('Dismiss sheet'),
                        );
                      },
                    ),
                    child: const Text('Open sheet'),
                  ),
                  TextButton(
                    onPressed: () => showRealtimeRoomUiDialog<void>(
                      hostContext,
                      controller: controller,
                      builder: (dialogContext) {
                        dialogController = RealtimeRoomUiScope.of(
                          dialogContext,
                        );
                        return AlertDialog(
                          content: TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: const Text('Dismiss dialog'),
                          ),
                        );
                      },
                    ),
                    child: const Text('Open dialog'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open sheet'));
    await tester.pumpAndSettle();
    expect(identical(sheetController, controller), isTrue);
    await tester.tap(find.text('Dismiss sheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open dialog'));
    await tester.pumpAndSettle();
    expect(identical(dialogController, controller), isTrue);
    await tester.tap(find.text('Dismiss dialog'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(controller.close);
    await tester.runAsync(fixture.room.dispose);
  });

  testWidgets(
    'RTC data send failure reports to room UI without missing scope',
    (tester) async {
      final fixture = await MeetingSharingFixture.create(teaching: false);
      addTearDown(fixture.room.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: RealtimeUiTheme.light(),
          home: RealtimeMeetingPage(
            room: fixture.room,
            showClassroom: false,
            showRtcDataMessages: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final panel = tester.widget<RoomRtcDataPanel>(
        find.byType(RoomRtcDataPanel),
      );
      panel.onError('simulated RTC failure');
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.room.dispose);
    },
  );

  testWidgets('embedded room closes and returns to the host route', (
    tester,
  ) async {
    final fixture = await MeetingSharingFixture.create(teaching: false);
    addTearDown(fixture.room.dispose);
    var left = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: Builder(
          builder: (hostContext) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(hostContext).push(
                  MaterialPageRoute<void>(
                    builder: (pageContext) => RealtimeRoomView(
                      room: fixture.room,
                      showClassroom: false,
                      onLeave: () {
                        left++;
                        Navigator.of(pageContext).pop();
                      },
                    ),
                  ),
                ),
                child: const Text('Open meeting'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open meeting'));
    await tester.pumpAndSettle();
    expect(find.byType(RealtimeRoomView), findsOneWidget);
    await tester.tap(find.byIcon(Icons.call_end_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('Leave room?'), findsOneWidget);
    await tester.tap(find.text('Leave').last);
    // Room disposal includes actual async cleanup, not only widget frames.
    await tester.runAsync(fixture.room.dispose);
    await tester.pumpAndSettle();

    expect(left, 1);
    expect(find.text('Open meeting'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// Simulates a descendant that is subscribed to the old room controller
/// while an inherited scope switches to another room. The old controller
/// must not be disposed until this element has processed the new dependency
/// (or finished unmounting).
class _ControllerTransitionProbe extends StatefulWidget {
  const _ControllerTransitionProbe();

  @override
  State<_ControllerTransitionProbe> createState() =>
      _ControllerTransitionProbeState();
}

class _ControllerTransitionProbeState
    extends State<_ControllerTransitionProbe> {
  RealtimeRoomUiController? _previous;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = RealtimeRoomUiScope.of(context);
    final old = _previous;
    if (old != null && !identical(old, next)) {
      expect(
        old.isDisposed,
        isFalse,
        reason: 'Children must detach before their notifier is disposed',
      );
    }
    _previous = next;
  }

  @override
  void dispose() {
    expect(
      _previous?.isDisposed,
      isFalse,
      reason: 'Descendants must finish unmounting before scope disposal',
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Column(
    children: [
      RealtimeDockMicrophoneButton(),
      RealtimeDockSharedContentButton(),
    ],
  );
}
