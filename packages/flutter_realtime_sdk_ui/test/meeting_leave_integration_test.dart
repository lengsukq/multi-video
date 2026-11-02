import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';

import 'support/meeting_sharing_fixture.dart';

void main() {
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
