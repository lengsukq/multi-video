import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// Host slots and classroom workspace layout introduced by the Tandem pass.
void main() {
  Future<MediaPreJoinResult> readyResult() async => const MediaPreJoinResult(
    role: MediaRole.participant,
    providerId: 'fake',
    checks: [
      MediaPreJoinCheck(
        type: MediaPreJoinCheckType.backend,
        status: MediaPreJoinStatus.passed,
        severity: MediaPreJoinSeverity.blocking,
        message: 'Ready',
      ),
    ],
  );

  testWidgets(
    'desktop live host keeps Start Live CTA visible after right diagnostics scroll',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // Mirrors the user's 1280x720 Windows display after its title bar is
      // subtracted (150% DPI scaling); verify real usable viewport height.
      const viewport = Size(1280, 649);
      await tester.binding.setSurfaceSize(viewport);
      await tester.pumpWidget(
        MaterialApp(
          theme: RealtimeUiTheme.light(),
          locale: const Locale('zh', 'CN'),
          supportedLocales: RealtimeStrings.supportedLocales,
          localizationsDelegates: RealtimeStrings.localizationsDelegates,
          home: RealtimePreJoinPage(
            permissionRequester: const _Permissions(),
            roomLabel: 'live-host-room',
            displayName: 'Host',
            runCheck: () async => const MediaPreJoinResult(
              role: MediaRole.host,
              providerId: 'ivs',
              checks: [
                MediaPreJoinCheck(
                  type: MediaPreJoinCheckType.providerNetwork,
                  status: MediaPreJoinStatus.unsupported,
                  severity: MediaPreJoinSeverity.warning,
                  message: 'Cannot pre-probe an IVS Stage without a token.',
                ),
              ],
            ),
            openPreview: (_, _) async => null,
            onEnter: (_, _) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final join = find.byType(RealtimePreJoinJoinButton);
      expect(join, findsOneWidget);
      final darkCard = find.byKey(const ValueKey('prejoin-session-card'));
      expect(
        find.descendant(of: darkCard, matching: join),
        findsOneWidget,
      );
      expect(
        find.descendant(of: join, matching: find.text('开始直播')),
        findsOneWidget,
      );
      expect(
        tester.widget<FilledButton>(
          find.descendant(of: join, matching: find.byType(FilledButton)),
        ).onPressed,
        isNotNull,
      );
      // The diagnostics column scrolls independently on desktop. Its scroll
      // position must not be able to remove the primary button from view.
      await tester.drag(
        find.byKey(const ValueKey('prejoin-wide-diagnostics-scroll')),
        const Offset(0, -550),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: darkCard, matching: join),
        findsOneWidget,
      );
      final bounds = tester.getRect(join);
      expect(bounds.top, greaterThanOrEqualTo(0));
      expect(bounds.bottom, lessThanOrEqualTo(viewport.height));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wide Pre-Join intro spans the page and aligns both cards', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final viewport in const [
      Size(1440, 900),
      Size(1280, 700),
      Size(1280, 649),
      Size(390, 844),
    ]) {
      await tester.binding.setSurfaceSize(viewport);
      await tester.pumpWidget(
        MaterialApp(
          theme: RealtimeUiTheme.light(),
          locale: const Locale('zh', 'CN'),
          supportedLocales: RealtimeStrings.supportedLocales,
          localizationsDelegates: RealtimeStrings.localizationsDelegates,
          home: RealtimePreJoinPage(
            permissionRequester: const _Permissions(),
            roomLabel: '735606',
            displayName: 'Teacher',
            runCheck: readyResult,
            openPreview: (_, _) async => null,
            onEnter: (_, _) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final intro = tester.getRect(
        find.byKey(const ValueKey('prejoin-intro-header')),
      );
      final preview = tester.getRect(
        find.byKey(const ValueKey('prejoin-preview-card')),
      );
      final session = tester.getRect(
        find.byKey(const ValueKey('prejoin-session-card')),
      );
      expect(find.text('加入前检查设备'), findsOneWidget);
      expect(intro.bottom, lessThan(preview.top));
      if (viewport.width >= 1000) {
        expect(preview.top, closeTo(session.top, 1));
        expect(intro.left, closeTo(preview.left, 1));
        expect(intro.right, closeTo(session.right, 1));
      } else {
        expect(preview.bottom, lessThan(session.top));
      }
      expect(tester.takeException(), isNull, reason: '$viewport');
    }
  });

  testWidgets(
    'live viewer always has one reachable join CTA when provider probe is unsupported',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Future<MediaPreJoinResult> liveViewer() async =>
          const MediaPreJoinResult(
            role: MediaRole.viewer,
            providerId: 'aws',
            checks: [
              MediaPreJoinCheck(
                type: MediaPreJoinCheckType.providerNetwork,
                status: MediaPreJoinStatus.unsupported,
                severity: MediaPreJoinSeverity.warning,
                message: 'IVS needs a participant token to test connectivity.',
              ),
            ],
          );

      // At 1100x500 the outer page meets the desktop height threshold,
      // but the content area below the header does not. Previously that
      // hid both the session-card CTA and the sticky bottom-bar CTA.
      for (final viewport in const [
        Size(1100, 500),
        Size(1100, 600),
        Size(1280, 800),
        Size(390, 700),
      ]) {
        await tester.binding.setSurfaceSize(viewport);
        await tester.pumpWidget(
          MaterialApp(
            theme: RealtimeUiTheme.light(),
            locale: const Locale('zh', 'CN'),
            supportedLocales: RealtimeStrings.supportedLocales,
            localizationsDelegates: RealtimeStrings.localizationsDelegates,
            home: RealtimePreJoinPage(
              permissionRequester: const _Permissions(),
              roomLabel: 'live-room',
              displayName: 'Viewer',
              runCheck: liveViewer,
              openPreview: (_, _) async => null,
              onEnter: (_, _) async {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        final join = find.byType(RealtimePreJoinJoinButton);
        expect(join, findsOneWidget, reason: '$viewport');
        final controller = RealtimePreJoinScope.of(tester.element(join));
        expect(controller.canEnter, isTrue, reason: '$viewport');
        final button = find.descendant(
          of: join,
          matching: find.byType(FilledButton),
        );
        expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
        final rect = tester.getRect(join);
        expect(rect.top, greaterThanOrEqualTo(0), reason: '$viewport');
        expect(rect.bottom, lessThanOrEqualTo(viewport.height),
            reason: '$viewport');
        expect(tester.takeException(), isNull, reason: '$viewport');
      }
    },
  );

  testWidgets('pre-join renders host waiting room, agenda and materials', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var admitted = 0;
    RealtimePreJoinSessionInfo? entered;
    RealtimePreJoinJoinIntent? intent;
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: RealtimePreJoinPage(
          permissionRequester: const _Permissions(),
          roomLabel: 'room-1',
          displayName: 'Teacher',
          brand: const Text('Tandem'),
          sessionInfo: RealtimePreJoinSessionInfo(
            title: 'Quadratics: finding the roots',
            subject: 'Algebra II',
            scheduleLabel: 'Today',
            timeRangeLabel: '4:00 – 5:00 PM',
            startsAt: DateTime.now().add(const Duration(minutes: 4)),
            enrolledCount: 6,
          ),
          waitingGuests: const [
            RealtimePreJoinWaitingGuest(id: 'a', name: 'Ava K.'),
            RealtimePreJoinWaitingGuest(id: 'b', name: 'Jonah M.'),
          ],
          onAdmitGuest: (_) => admitted++,
          agenda: const [
            RealtimePreJoinAgendaItem(
              title: 'Warm-up: factor pairs',
              durationLabel: '5 min',
            ),
          ],
          materials: const [
            RealtimePreJoinMaterial(id: 'm', title: 'Slides.pdf'),
          ],
          runCheck: readyResult,
          openPreview: (_, _) async => null,
          onEnter: (_, _) async {},
          onEnterWithIntent: (_, _, value) async => intent = value,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Tandem'), findsOneWidget);
    expect(find.text('Quadratics: finding the roots'), findsOneWidget);
    expect(find.text('Algebra II'), findsOneWidget);
    expect(find.text('Waiting room (2)'), findsOneWidget);
    expect(find.text('Lesson plan'), findsOneWidget);
    expect(find.text('Class materials'), findsOneWidget);
    expect(find.text('Audio only'), findsOneWidget);

    await tester.ensureVisible(find.text('Admit').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Admit').first);
    await tester.pump();
    expect(admitted, 1);
    // Only a subsequent host snapshot may confirm admission.
    expect(find.text('Admitted'), findsNothing);
    expect(find.text('Waiting room (2)'), findsOneWidget);

    await tester.ensureVisible(find.text('Audio only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Audio only'));
    await tester.pumpAndSettle();
    expect(intent, RealtimePreJoinJoinIntent.audioOnly);
    expect(entered, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pre-join reveals device settings from the preview gear and shows mic meter inline',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: RealtimeUiTheme.light(),
          locale: const Locale('zh', 'CN'),
          supportedLocales: RealtimeStrings.supportedLocales,
          localizationsDelegates: RealtimeStrings.localizationsDelegates,
          home: RealtimePreJoinPage(
            permissionRequester: const _Permissions(),
            roomLabel: 'room-3',
            displayName: 'Guest',
            runCheck: readyResult,
            openPreview: (_, _) async => _DevicesPreview(),
            onEnter: (_, _) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Devices are a secondary surface: the preview owns the gear that
      // reveals them, and the join column owns the readiness summary.
      expect(find.byType(RealtimePreJoinDevicePicker), findsNothing);
      expect(find.byType(RealtimePreJoinMediaControls), findsNothing);
      expect(find.byType(RealtimePreJoinReadinessCard), findsOneWidget);
      expect(find.byTooltip('设备设置'), findsOneWidget);
      expect(find.byTooltip('打开麦克风'), findsOneWidget);
      expect(find.byTooltip('打开摄像头'), findsOneWidget);
      expect(find.byTooltip('虚化背景'), findsOneWidget);
      expect(find.text('Play test sound'), findsNothing);

      // Settings must be the fourth control in the centered preview group,
      // not a detached floating button at the bottom-right of the preview.
      final mic = tester.getCenter(find.byTooltip('打开麦克风'));
      final camera = tester.getCenter(find.byTooltip('打开摄像头'));
      final blur = tester.getCenter(find.byTooltip('虚化背景'));
      final settings = tester.getCenter(find.byTooltip('设备设置'));
      expect(mic.dx, lessThan(camera.dx));
      expect(camera.dx, lessThan(blur.dx));
      expect(blur.dx, lessThan(settings.dx));
      expect(settings.dy, closeTo(blur.dy, 1));
      expect(settings.dx - blur.dx, closeTo(blur.dx - camera.dx, 1));

      await tester.tap(find.byTooltip('设备设置'));
      await tester.pumpAndSettle();

      expect(find.byType(RealtimePreJoinDevicePicker), findsNWidgets(3));
      expect(find.byType(RealtimePreJoinMediaControls), findsOneWidget);
      // A muted microphone has no level control: the meter only appears once
      // the switch (or the preview control) turns capture on.
      expect(find.byType(RealtimeMicrophoneLevelMeter), findsNothing);
      final controller = RealtimePreJoinScope.of(
        tester.element(find.byType(RealtimePreJoinMediaControls)),
      );
      await controller.setMicrophoneEnabled(true);
      await tester.pump();
      expect(find.byType(RealtimeMicrophoneLevelMeter), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(RealtimePreJoinMediaControls),
          matching: find.byType(RealtimeMicrophoneLevelMeter),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(RealtimePreJoinDevicePicker),
          matching: find.byType(RealtimeMicrophoneLevelMeter),
        ),
        findsNothing,
      );
      for (final label in const ['环境降噪', '虚化背景', '自动录制', '实时字幕']) {
        expect(find.text(label), findsNothing);
      }
      expect(find.byTooltip('收起设备设置'), findsOneWidget);

      await tester.tap(find.byTooltip('收起设备设置'));
      await tester.pumpAndSettle();
      expect(find.byType(RealtimePreJoinDevicePicker), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pre-join hides host sections when no slot data is supplied', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var joinCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: RealtimePreJoinPage(
          permissionRequester: const _Permissions(),
          roomLabel: 'room-2',
          displayName: 'Guest',
          runCheck: readyResult,
          openPreview: (_, _) async => null,
          onEnter: (_, _) async => joinCalls++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Waiting room (0)'), findsNothing);
    expect(find.text('Lesson plan'), findsNothing);
    expect(find.text('Class materials'), findsNothing);
    // No session info keeps the original generic CTA.
    expect(find.text('Join meeting'), findsOneWidget);
    await tester.tap(find.text('Join meeting'));
    await tester.pumpAndSettle();
    expect(joinCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'lobby confirms admission from host state and submits a batch once',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var guest = const RealtimePreJoinWaitingGuest(id: 'a', name: 'Ava');
      var singleRequests = 0;
      var batchRequests = 0;
      late StateSetter updateHost;
      await tester.pumpWidget(
        MaterialApp(
          theme: RealtimeUiTheme.light(),
          home: StatefulBuilder(
            builder: (context, setState) {
              updateHost = setState;
              return RealtimePreJoinPage(
                permissionRequester: const _Permissions(),
                roomLabel: 'lobby',
                displayName: 'Host',
                waitingGuests: [guest],
                onAdmitGuest: (_) => singleRequests++,
                onAdmitAll: () => batchRequests++,
                runCheck: readyResult,
                openPreview: (_, _) async => null,
                onEnter: (_, _) async {},
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Admit all'));
      await tester.tap(find.text('Admit all'));
      await tester.pump();
      expect(batchRequests, 1);
      expect(singleRequests, 0);
      expect(find.text('Admitted'), findsNothing);
      await tester.tap(find.text('Admit'));
      expect(singleRequests, 1);
      updateHost(() => guest = guest.copyWith(admitted: true));
      await tester.pump();
      expect(find.text('Admitted'), findsOneWidget);
      expect(find.text('Waiting room (0)'), findsOneWidget);
    },
  );

  testWidgets('audio-only intent forces microphone on and camera off', (
    tester,
  ) async {
    final settings = const MediaLocalPreviewSettings(
      microphoneEnabled: false,
      cameraEnabled: true,
    );
    final applied = RealtimePreJoinJoinIntent.audioOnly.applyTo(settings);
    expect(applied.microphoneEnabled, isTrue);
    expect(applied.cameraEnabled, isFalse);
    final standard = RealtimePreJoinJoinIntent.standard.applyTo(settings);
    expect(standard, same(settings));
    final share = RealtimePreJoinJoinIntent.screenShare.applyTo(settings);
    expect(share, same(settings));
  });

  testWidgets('meeting header uses host session info and invite action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: Scaffold(
          body: RealtimeMeetingTopBar(
            brand: const Text('Tandem'),
            title: 'Quadratics: finding the roots',
            subtitle: 'Algebra II · session 7 of 12',
            inviteAction: () {},
            audienceNames: const ['Ava', 'Jonah'],
            audienceCount: 2,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Tandem'), findsOneWidget);
    expect(find.text('Quadratics: finding the roots'), findsOneWidget);
    expect(find.text('Algebra II · session 7 of 12'), findsOneWidget);
    expect(find.text('Invite'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _DevicesPreview extends Fake implements MediaLocalPreviewSession {
  MediaLocalPreviewSettings _settings = const MediaLocalPreviewSettings();
  @override
  MediaTrackRenderer get renderer => const _NullRenderer();
  @override
  String get providerId => 'fake';
  @override
  MediaRole get role => MediaRole.participant;
  @override
  MediaCapabilities get capabilities => const MediaCapabilities.meeting();
  @override
  MediaLocalPreviewSettings get settings => _settings;
  @override
  MediaVideoTrack? get cameraTrack => null;
  @override
  Future<void> setMicrophoneEnabled(bool enabled) async {
    _settings = _settings.copyWith(microphoneEnabled: enabled);
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    _settings = _settings.copyWith(cameraEnabled: enabled);
  }

  @override
  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async => const [];
  @override
  Future<void> dispose() async {}
}

class _NullRenderer extends MediaTrackRenderer {
  const _NullRenderer();

  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      const SizedBox.shrink();
}

class _Permissions implements MediaPermissionRequester {
  const _Permissions();
  @override
  Future<MediaPermissionState> request(MediaPermissionKind kind) async =>
      MediaPermissionState.granted;
  @override
  Future<MediaPermissionState> status(MediaPermissionKind kind) async =>
      MediaPermissionState.granted;
  @override
  bool get canOpenAppSettings => true;
  @override
  Future<bool> openAppSettings() async => true;
}
