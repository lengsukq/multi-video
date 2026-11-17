import 'package:flutter/material.dart';
import 'package:multi_video/demo_join_screen.dart';
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/design_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeDesignCapture);
  testWidgets(
    'all home destinations remain usable with large text and a keyboard',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.view.resetViewPadding);
      tester.view.devicePixelRatio = 1;
      final realtime = _PreviewRealtime();
      for (final size in [
        const Size(320, 640),
        const Size(390, 844),
        const Size(768, 960),
        const Size(1024, 800),
        const Size(1280, 900),
        const Size(1440, 900),
      ]) {
        tester.view.physicalSize = size;
        for (final scale in [1.0, 2.0]) {
          await tester.pumpWidget(
            designCaptureApp(
              MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: designTestTheme(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: JoinScreen(
                  onLocaleChanged: (_) {},
                  realtimeFactory: (_) => realtime,
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(
            tester.takeException(),
            isNull,
            reason: 'Home $size at $scale',
          );
          if (scale == 1 && [390.0, 1440.0].contains(size.width)) {
            await captureDesign(tester, 'home-${size.width.toInt()}');
          }
          await tester.tap(
            (find
                    .byKey(const ValueKey('realtime-destination-2'))
                    .evaluate()
                    .isNotEmpty
                ? find.byKey(const ValueKey('realtime-destination-2'))
                : find.text('Settings').last),
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text('Demo identity'), findsOneWidget);
          expect(
            tester.takeException(),
            isNull,
            reason: 'Settings $size at $scale',
          );
          if (scale == 1 && [390.0, 1440.0].contains(size.width)) {
            await captureDesign(tester, 'settings-${size.width.toInt()}');
          }
          if (scale == 1 && size.width == 1440) {
            final badge = find.text('Default: LiveKit');
            expect(badge, findsOneWidget);
            final card = find
                .ancestor(of: badge, matching: find.byType(RealtimeCardSurface))
                .first;
            expect(
              tester.getRect(card).right - tester.getRect(badge).right,
              lessThan(42),
              reason: 'Backend status should hug the trailing edge of its card',
            );
          }
          await tester.tap(
            (find
                    .byKey(const ValueKey('realtime-destination-1'))
                    .evaluate()
                    .isNotEmpty
                ? find.byKey(const ValueKey('realtime-destination-1'))
                : find.text('Chat').last),
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(
            tester.takeException(),
            isNull,
            reason: 'Chat $size at $scale',
          );
          if (scale == 1 && size.width == 1440) {
            await captureDesign(tester, 'chat-entry-1440');
            final chatBadge = find.text('Chat online');
            expect(chatBadge, findsOneWidget);
            final card = find
                .ancestor(
                  of: chatBadge,
                  matching: find.byType(RealtimeCardSurface),
                )
                .first;
            expect(
              tester.getRect(card).right - tester.getRect(chatBadge).right,
              lessThan(42),
              reason: 'Chat status should be aligned to the profile card right',
            );
          }
          await tester.tap(
            (find
                    .byKey(const ValueKey('realtime-destination-0'))
                    .evaluate()
                    .isNotEmpty
                ? find.byKey(const ValueKey('realtime-destination-0'))
                : find.text('Home').last),
          );
          await tester.pump(const Duration(milliseconds: 400));
        }
      }
      tester.view.physicalSize = const Size(390, 844);
      tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 34);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      await tester.ensureVisible(find.widgetWithText(TextField, 'Room code'));
      await tester.enterText(
        find.widgetWithText(TextField, 'Room code'),
        'studio-104',
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Chinese action cards do not overflow near 260px CanvasKit wrap boundary',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      final realtime = _PreviewRealtime();
      for (final size in [
        const Size(640, 820),
        const Size(1080, 820),
        const Size(1160, 820),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          designCaptureApp(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              locale: const Locale('zh', 'CN'),
              supportedLocales: RealtimeStrings.supportedLocales,
              localizationsDelegates: RealtimeStrings.localizationsDelegates,
              theme: designTestTheme(),
              home: JoinScreen(
                onLocaleChanged: (_) {},
                realtimeFactory: (_) => realtime,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          tester.takeException(),
          isNull,
          reason: 'Chinese JoinScreen $size must not overflow',
        );
      }
    },
  );
}

class _PreviewRealtime extends Fake implements Realtime {
  @override
  Future<List<MediaRoomSummary>> listRooms() async => const [
    MediaRoomSummary(
      roomCode: 'studio-104',
      providerId: 'livekit',
      roomMode: MediaRoomMode.meeting,
      attendeeCount: 3,
    ),
    MediaRoomSummary(
      roomCode: 'live-205',
      providerId: 'livekit',
      roomMode: MediaRoomMode.broadcast,
      attendeeCount: 12,
    ),
  ];

  @override
  Future<List<ChatRoomSummary>> listChatRooms() async => const [];

  @override
  Future<MediaDoctorReport> diagnoseBackend() async => const MediaDoctorReport(
    [
      MediaDoctorCheck(
        id: 'backend',
        status: MediaDoctorStatus.pass,
        message: 'Ready',
      ),
    ],
    backendReachable: true,
    activeProvider: 'livekit',
  );
}
