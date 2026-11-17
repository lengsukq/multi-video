import 'package:flutter/material.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/meeting_sharing_fixture.dart';

void main() {
  testWidgets('meeting share options open beside the dock instead of a sheet', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await MeetingSharingFixture.create(
      mode: SharedContentMode.whiteboard,
      localShare: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: RealtimeStrings.supportedLocales,
        localizationsDelegates: RealtimeStrings.localizationsDelegates,
        home: RealtimeRoomUiScope(
          room: fixture.room,
          child: const Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: RealtimeDockSharedContentButton(showLabel: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(RealtimeDockSharedContentButton));
    await tester.pumpAndSettle();

    expect(find.byType(MenuItemButton), findsNWidgets(3));
    expect(find.byType(BottomSheet), findsNothing);
    final actions = find.byType(MenuItemButton);
    expect(
      find.descendant(of: actions, matching: find.text('白板演示')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: actions, matching: find.text('屏幕共享')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: actions, matching: find.text('停止共享')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    expect(find.byType(RealtimeDockSharedContentButton), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(fixture.room.dispose);
  });

  testWidgets(
    'live host secondary choices use small menu with real callbacks',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(340, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = await MeetingSharingFixture.create(role: MediaRole.host);
      var hostTools = 0;
      var fitChanges = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: RealtimeRoomUiScope(
            room: fixture.room,
            child: Scaffold(
              body: RealtimeLiveMobileOverlay(
                showChat: false,
                showLiveInteractions: false,
                onOpenHostTools: () => hostTools++,
                onToggleVideoFit: () => fitChanges++,
                onToggleCleanScreen: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Display options'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(MenuItemButton), findsNWidgets(3));
      await tester.tap(find.text('Host tools'));
      await tester.pumpAndSettle();
      expect(hostTools, 1);
      expect(find.byType(MenuItemButton), findsNothing);

      await tester.tap(find.byTooltip('Display options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show full video'));
      await tester.pumpAndSettle();
      expect(fitChanges, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.room.dispose);
    },
  );

  testWidgets('live viewer quick menu never exposes host management', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(340, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await MeetingSharingFixture.create(role: MediaRole.viewer);
    var fitChanges = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeRoomUiScope(
          room: fixture.room,
          child: Scaffold(
            body: RealtimeLiveMobileOverlay(
              showChat: false,
              showLiveInteractions: false,
              onToggleVideoFit: () => fitChanges++,
              onToggleCleanScreen: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Display options'));
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNWidgets(2));
    expect(find.text('Host tools'), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.tap(find.text('Show full video'));
    await tester.pumpAndSettle();
    expect(fitChanges, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(fixture.room.dispose);
  });

  testWidgets(
    'share menu stays clickable without UI restrictions and reports errors cleanly',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 780));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = await MeetingSharingFixture.create(
        mode: SharedContentMode.members,
        localShare: false,
      );
      fixture.repository!.whiteboard = WhiteboardState(
        revision: 1,
        maxPages: 20,
        canEdit: false,
        activePageId: 'page-1',
        pages: [WhiteboardPage(id: 'page-1', title: 'Page 1')],
        canvas: AnnotationCanvas(canvasId: 'c-1', sourceKey: 'page-1'),
      );
      await fixture.room.sharedContent!.whiteboard.refresh();
      final reportedErrors = <RealtimeException>[];

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: RealtimeStrings.supportedLocales,
          localizationsDelegates: RealtimeStrings.localizationsDelegates,
          home: RealtimeRoomUiScope(
            room: fixture.room,
            onActionError: reportedErrors.add,
            child: const Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: RealtimeDockSharedContentButton(showLabel: true),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(RealtimeDockSharedContentButton));
      await tester.pumpAndSettle();

      await tester.tap(find.text('白板演示'));
      await tester.pumpAndSettle();
      expect(reportedErrors, hasLength(1));
      expect(find.byType(MenuItemButton), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.room.dispose);
    },
  );
}
