import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';

import 'support/meeting_sharing_fixture.dart';

/// Layout contract for the rebuilt meeting workspace.
///
/// Phones: header + stage + floating dock, panels open as a right drawer.
/// Tablets: same shell plus a horizontal tool rail.
/// Desktop: vertical rail, stage bar and a 340 pt persistent side panel.
void main() {
  testWidgets(
    'live sidebar hides an unavailable chat tab and its empty panel',
    (tester) async {
      final chatEnabled = ValueNotifier<bool>(true);
      addTearDown(chatEnabled.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 340,
              child: ValueListenableBuilder<bool>(
                valueListenable: chatEnabled,
                builder: (context, enabled, _) => RealtimeMeetingSidebar(
                  members: const [],
                  showChat: enabled,
                  chatWidget: const Text('Chat content'),
                  membersWidget: const Text('Member content'),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Chat'), findsOneWidget);
      chatEnabled.value = false;
      await tester.pumpAndSettle();
      expect(find.text('Chat'), findsNothing);
      expect(find.text('Participants'), findsOneWidget);
      expect(find.text('Chat content'), findsNothing);
      expect(find.text('Member content'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  Future<void> pumpPage(
    WidgetTester tester,
    MeetingSharingFixture fixture,
    Size size, {
    double textScale = 1,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: RealtimeMeetingPage(room: fixture.room, showClassroom: false),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('desktop shows the tool rail and a 340 pt panel', (tester) async {
    final fixture = await MeetingSharingFixture.create(withTrack: false);
    addTearDown(fixture.room.dispose);
    await pumpPage(tester, fixture, const Size(1280, 820));

    expect(find.byType(RealtimeMeetingRail), findsOneWidget);
    expect(find.byType(RealtimeMeetingTopBar), findsOneWidget);
    expect(find.byType(RealtimeMeetingDock), findsOneWidget);
    expect(find.byType(RealtimeMeetingSidePanel), findsNothing);

    // Header is a persistent 56 pt bar, not an overlay card.
    final header = tester.getRect(find.byType(RealtimeMeetingTopBar));
    expect(header.height, inInclusiveRange(56, 90));
    expect(header.top, lessThan(2));

    // The rail is a narrow column to the left of the stage, and the stage
    // starts right below the header: no layout bar reserves a row of its own.
    final rail = tester.getRect(find.byType(RealtimeMeetingRail));
    expect(rail.width, 60);
    final stage = tester.getRect(find.byType(RealtimeMeetingStage));
    expect(stage.left, greaterThanOrEqualTo(rail.right));
    expect(stage.top, closeTo(header.bottom, 1));
    // Camera layout is a single rail toggle, not a labelled tab row: it names
    // the view the tap switches to.
    expect(
      find.descendant(
        of: find.byType(RealtimeMeetingRail),
        matching: find.byTooltip('Grid view'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(RealtimeMeetingRail),
        matching: find.byTooltip('Speaker view'),
      ),
      findsNothing,
    );

    // Opening a panel from the rail adds a fixed-width trailing column.
    await tester.tap(
      find.descendant(
        of: find.byType(RealtimeMeetingRail),
        matching: find.byTooltip('Participants'),
      ),
    );
    await tester.pumpAndSettle();
    final panel = tester.getRect(find.byType(RealtimeMeetingSidePanel));
    expect(panel.width, 340);
    expect(panel.right, closeTo(1280, 1));
    // The old boxed Chat/People segmented control is replaced by the flat
    // underline tabs, and the participant tab remains functional.
    final sidebar = find.byType(RealtimeClassroomSidePanel);
    expect(sidebar, findsOneWidget);
    expect(
      find.descendant(
        of: sidebar,
        matching: find.byType(RealtimeSegmentedTabs<int>),
      ),
      findsNothing,
    );
    // Chat is capability-driven: the fixture has no ChatSession, so the tab
    // must not appear unless the room actually supplies chat.
    expect(
      find.descendant(of: sidebar, matching: find.text('Chat')),
      fixture.room.chat == null ? findsNothing : findsOneWidget,
    );
    expect(
      find.descendant(of: sidebar, matching: find.text('People')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('meeting keeps core actions below and settings in the rail', (
    tester,
  ) async {
    for (final size in const [Size(390, 844), Size(1280, 820)]) {
      final fixture = await MeetingSharingFixture.create(withTrack: false);
      await pumpPage(tester, fixture, size);
      final dock = find.byType(RealtimeMeetingDock);
      final rail = find.byType(RealtimeMeetingRail);
      expect(find.byType(RealtimeDockMoreButton), findsNothing);
      expect(
        find.descendant(
          of: dock,
          matching: find.byType(RealtimeDockMicrophoneButton),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dock,
          matching: find.byType(RealtimeDockCameraButton),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dock,
          matching: find.byType(RealtimeDockSharedContentButton),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dock, matching: find.byTooltip('Flip')),
        findsNothing,
      );
      expect(
        find.descendant(of: rail, matching: find.byTooltip('Flip')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: rail,
          matching: find.byTooltip('Virtual background'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull, reason: 'at $size');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.room.dispose);
    }
  });

  testWidgets('phone keeps one dock and opens panels as a drawer', (
    tester,
  ) async {
    final fixture = await MeetingSharingFixture.create(withTrack: false);
    addTearDown(fixture.room.dispose);
    await pumpPage(tester, fixture, const Size(390, 844));

    expect(find.byType(RealtimeMeetingTopBar), findsOneWidget);
    expect(find.byType(RealtimeMeetingRail), findsOneWidget);
    expect(
      tester
          .widget<RealtimeMeetingRail>(find.byType(RealtimeMeetingRail))
          .horizontal,
      isTrue,
    );
    expect(find.byType(RealtimeMeetingDock), findsOneWidget);
    expect(find.byType(RealtimeMeetingSidePanel), findsNothing);

    // The dock sits below the stage so nothing overlaps the thumbnails.
    final stage = tester.getRect(find.byType(RealtimeMeetingStage));
    final dock = tester.getRect(find.byType(RealtimeMeetingDock));
    expect(stage.bottom, lessThanOrEqualTo(dock.top + 1));

    // No bottom sheet: the participants panel is a right-hand drawer.
    final participants = find.descendant(
      of: find.byType(RealtimeMeetingRail),
      matching: find.byTooltip('Participants'),
    );
    await tester.ensureVisible(participants);
    await tester.pumpAndSettle();
    await tester.tap(participants);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    final drawer = tester.getRect(find.byType(RealtimeManagedParticipantList));
    expect(drawer.width, lessThanOrEqualTo(390));
    expect(drawer.width, greaterThan(200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet renders the horizontal tool rail without a side panel', (
    tester,
  ) async {
    final fixture = await MeetingSharingFixture.create(withTrack: false);
    addTearDown(fixture.room.dispose);
    await pumpPage(tester, fixture, const Size(720, 900));

    final rail = find.byType(RealtimeMeetingRail);
    expect(rail, findsOneWidget);
    expect(tester.widget<RealtimeMeetingRail>(rail).horizontal, isTrue);
    expect(find.byType(RealtimeMeetingSidePanel), findsNothing);
    // The tablet toolbar is a full-width continuation of the session header,
    // not a disconnected, centered rectangle over the stage.
    final headerRect = tester.getRect(find.byType(RealtimeMeetingTopBar));
    final railRect = tester.getRect(rail);
    expect(railRect.left, closeTo(0, 1));
    expect(railRect.right, closeTo(720, 1));
    expect(railRect.top, closeTo(headerRect.bottom, 1));
    expect(
      find.descendant(of: rail, matching: find.text('Participants')),
      findsOneWidget,
    );

    // Tablet panels reuse the drawer, never the desktop column.
    await tester.tap(
      find.descendant(
        of: find.byType(RealtimeMeetingRail),
        matching: find.byTooltip('Participants'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RealtimeMeetingSidePanel), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow meeting rail arrows are aligned and never cover tools', (
    tester,
  ) async {
    final fixture = await MeetingSharingFixture.create(withTrack: false);
    addTearDown(fixture.room.dispose);
    await pumpPage(tester, fixture, const Size(390, 844));

    final rail = find.byType(RealtimeMeetingRail);
    final strip = find.descendant(
      of: rail,
      matching: find.byKey(const ValueKey('room-secondary-tools-scroll')),
    );
    final scrollView = find.descendant(
      of: strip,
      matching: find.byType(SingleChildScrollView),
    );
    final rightArrow = find.descendant(
      of: strip,
      matching: find.byTooltip('Scroll dock right'),
    );
    expect(rightArrow, findsOneWidget);
    final railRect = tester.getRect(rail);
    final viewport = tester.getRect(scrollView);
    final right = tester.getRect(rightArrow);
    expect(right.left, greaterThanOrEqualTo(viewport.right));
    expect(right.center.dy, closeTo(railRect.center.dy, 1));

    await tester.tap(rightArrow);
    await tester.pumpAndSettle();
    final leftArrow = find.descendant(
      of: strip,
      matching: find.byTooltip('Scroll dock left'),
    );
    expect(leftArrow, findsOneWidget);
    final left = tester.getRect(leftArrow);
    expect(left.right, lessThanOrEqualTo(tester.getRect(scrollView).left));
    expect(left.center.dy, closeTo(railRect.center.dy, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('local camera appears only in the participant strip', (
    tester,
  ) async {
    for (final sharing in [false, true]) {
      final fixture = await MeetingSharingFixture.create(
        mode: sharing ? SharedContentMode.screen : SharedContentMode.members,
        withTrack: sharing,
      );
      await pumpPage(tester, fixture, const Size(1280, 820));
      expect(find.byType(RealtimeSelfView), findsNothing);
      expect(find.byKey(const ValueKey('render-camera-self')), findsOneWidget);
      expect(find.byType(RealtimeMeetingParticipantStrip), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.room.dispose);
    }
  });

  testWidgets('one layout toggle switches speaker and grid at every width', (
    tester,
  ) async {
    for (final size in const [
      Size(320, 640),
      Size(768, 900),
      Size(1440, 900),
      Size(740, 390),
    ]) {
      final fixture = await MeetingSharingFixture.create(withTrack: false);
      await pumpPage(
        tester,
        fixture,
        size,
        textScale: size.width == 320 ? 2 : 1,
      );

      // The toggle advertises the other view, so only one control exists.
      final railToggle = find.byTooltip('Grid view');
      final dockToggle = find.descendant(
        of: find.byType(RealtimeMeetingDock),
        matching: find.byTooltip('Grid view'),
      );
      expect(
        railToggle.evaluate().isNotEmpty || dockToggle.evaluate().isNotEmpty,
        isTrue,
        reason: 'layout toggle missing at $size',
      );
      final toggle = railToggle.evaluate().isNotEmpty
          ? railToggle.first
          : dockToggle.first;
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.byType(RealtimeVideoGrid), findsOneWidget);

      final back = find.byTooltip('Speaker view');
      expect(back, findsOneWidget);
      await tester.ensureVisible(back.first);
      await tester.pumpAndSettle();
      await tester.tap(back.first);
      await tester.pumpAndSettle();
      expect(find.byType(RealtimeMeetingFilmstripStage), findsOneWidget);

      expect(tester.takeException(), isNull, reason: 'at $size');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.room.dispose);
    }
  });
}
