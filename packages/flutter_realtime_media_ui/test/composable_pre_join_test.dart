import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('denied Android/iOS device permissions are not passed to RTC startup',
      () async {
    final preview = _Preview();
    final controller = RealtimePreJoinController(
      runCheck: () async => _check(role: MediaRole.participant),
      openPreview: (_, _) async => preview,
      permissionRequester: const _DenyingPermissionRequester(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.canEnter, isTrue,
        reason: 'Listeners may join with their camera and microphone off');
    // A permission may have been revoked after capture was selected, or a
    // retry may carry stale media-on settings from a previous attempt.
    await controller.setMicrophoneEnabled(true);
    await controller.setCameraEnabled(true);
    await controller.enter((settings) async {
      expect(settings.microphoneEnabled, isFalse);
      expect(settings.cameraEnabled, isFalse);
    });
  });

  testWidgets('denied device permissions have visible actions without preview',
      (tester) async {
    final controller = RealtimePreJoinController(
      runCheck: () async => _check(role: MediaRole.participant),
      openPreview: (_, _) async => null,
      permissionRequester: const _DenyingPermissionRequester(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(MaterialApp(
      home: RealtimePreJoinScope(
        controller: controller,
        child: const Scaffold(body: RealtimePreJoinPermissionNotice()),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('prejoin-permission-notice')),
        findsOneWidget);
    expect(find.textContaining('Microphone'), findsWidgets);
    expect(find.textContaining('Camera'), findsWidgets);
    expect(find.byType(TextButton), findsNWidgets(2));
  });

  test('camera toggle recovers an initially missing pre-join preview', () async {
    var attempts = 0;
    final recovered = _Preview();
    final controller = RealtimePreJoinController(
      runCheck: () async => _check(role: MediaRole.participant),
      openPreview: (_, _) async {
        attempts++;
        return attempts == 1 ? null : recovered;
      },
      permissionRequester: const _PermissionRequester(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.preview, isNull);
    await controller.requestPermissionAndEnable(MediaPermissionKind.camera);
    expect(attempts, 2);
    expect(controller.preview, same(recovered));
    expect(recovered.settings.cameraEnabled, isTrue);
  });

  test('missing local preview reports a recoverable error, not silent no-op',
      () async {
    final controller = RealtimePreJoinController(
      runCheck: () async => _check(role: MediaRole.participant),
      openPreview: (_, _) async => null,
      permissionRequester: const _PermissionRequester(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.requestPermissionAndEnable(MediaPermissionKind.microphone);
    expect(controller.preview, isNull);
    expect(controller.previewError, isNotNull);
    expect(controller.canEnter, isTrue,
        reason: 'A missing preview does not block joining with media off');
  });

  test(
    'unknown iOS permission result still lets native microphone capture decide',
    () async {
      final preview = _Preview();
      final controller = RealtimePreJoinController(
        runCheck: () async => _check(role: MediaRole.participant),
        openPreview: (_, _) async => preview,
        permissionRequester: const _UnknownPermissionRequester(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.requestPermissionAndEnable(
        MediaPermissionKind.microphone,
      );
      expect(preview.settings.microphoneEnabled, isTrue);
    },
  );

  testWidgets('portrait Pre-Join renderer owns decoded aspect ratio on iOS', (
    tester,
  ) async {
    final preview = _FitAwarePreview();
    final controller = RealtimePreJoinController(
      runCheck: () async => _check(role: MediaRole.participant),
      openPreview: (_, _) async => preview,
      permissionRequester: const _PermissionRequester(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.setCameraEnabled(true);
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimePreJoinScope(
          controller: controller,
          child: const Scaffold(
            body: SizedBox(
              width: 300,
              height: 470,
              child: RealtimePreJoinPreview(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MediaTrackView>(find.byType(MediaTrackView))
          .rendererManagesFit,
      isTrue,
    );
    expect(find.byType(FittedBox), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'permission refresh preserves the authoritative meeting policy',
    () async {
      final controller = RealtimePreJoinController(
        runCheck: () async => const MediaPreJoinResult(
          role: MediaRole.participant,
          meetingMode: MediaMeetingMode.standard,
          checks: [],
        ),
        openPreview: (_, _) async => null,
        permissionRequester: const _PermissionRequester(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.result?.meetingMode, MediaMeetingMode.standard);
      await controller.refreshPermissions();
      expect(controller.result?.meetingMode, MediaMeetingMode.standard);
    },
  );

  test('restarted checks ignore the older result', () async {
    final earlier = Completer<MediaPreJoinResult>();
    var calls = 0;
    var previewCalls = 0;
    final controller = RealtimePreJoinController(
      runCheck: () => ++calls == 1 ? earlier.future : Future.value(_check()),
      openPreview: (_, _) async {
        previewCalls++;
        return null;
      },
      permissionRequester: const _PermissionRequester(),
    );
    final one = controller.initialize();
    // Allow the first request to enter the check runner before restarting.
    await Future<void>.delayed(Duration.zero);
    final two = controller.initialize();
    earlier.complete(_check(providerId: 'stale'));
    await Future.wait([one, two]);
    expect(controller.result?.providerId, 'fake');
    expect(previewCalls, 0, reason: 'viewers do not open local capture');
    expect(controller.canEnter, isTrue);
    controller.dispose();
  });

  test(
    'failed entry returns to Pre-Join with retry settings and preview',
    () async {
      final previews = <_Preview>[];
      final controller = RealtimePreJoinController(
        runCheck: () async => _check(role: MediaRole.participant),
        openPreview: (_, _) async {
          final session = _Preview();
          previews.add(session);
          return session;
        },
        permissionRequester: const _PermissionRequester(),
      );
      await controller.initialize();
      expect(previews, hasLength(1));
      await controller.setCameraEnabled(true);
      expect(controller.preview?.settings.cameraEnabled, isTrue);
      var calls = 0;
      await controller.enter((settings) async {
        calls++;
        expect(settings.cameraEnabled, isTrue);
        expect(previews.first.disposeCount, 1);
        throw StateError('join failed');
      });
      expect(
        controller.joinError,
        isA<RealtimeException>().having(
          (e) => e.code,
          'code',
          RealtimeErrorCode.invalidState,
        ),
      );
      expect(controller.joining, isFalse);
      expect(previews, hasLength(2), reason: 'failure reopens the preview');
      await controller.enter((settings) async {
        calls++;
        expect(settings.cameraEnabled, isTrue);
      });
      expect(calls, 2);
      expect(previews.last.disposeCount, 1);
      controller.dispose();
    },
  );

  testWidgets('preview, permissions and checks are independently placeable', (
    tester,
  ) async {
    final controller = RealtimePreJoinController(
      runCheck: () async => _check(),
      openPreview: (_, _) async => null,
      permissionRequester: const _PermissionRequester(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    for (final width in [390.0, 768.0, 1280.0]) {
      await tester.binding.setSurfaceSize(Size(width, 780));
      await tester.pumpWidget(
        MaterialApp(
          home: RealtimePreJoinScope(
            controller: controller,
            child: Scaffold(
              body: Column(
                children: [
                  const SizedBox(height: 120, child: RealtimePreJoinPreview()),
                  const Expanded(
                    child: SingleChildScrollView(
                      child: RealtimePreJoinCheckList(),
                    ),
                  ),
                  RealtimePreJoinJoinButton(onEnter: (_) async {}),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(RealtimePreJoinJoinButton), findsOneWidget);
      expect(find.byType(RealtimePreJoinPreview), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('pre-join controls compose responsively inside a host layout', (
    tester,
  ) async {
    final controller = RealtimePreJoinController(
      runCheck: () async => _check(),
      openPreview: (_, _) async => null,
      permissionRequester: const _PermissionRequester(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    for (final width in [390.0, 768.0, 1280.0]) {
      await tester.binding.setSurfaceSize(Size(width, 780));
      await tester.pumpWidget(
        MaterialApp(
          home: RealtimePreJoinScope(
            controller: controller,
            child: Scaffold(
              body: ListView(
                children: [
                  const RealtimePreJoinPreview(),
                  const RealtimePreJoinCheckList(),
                  RealtimePreJoinJoinButton(onEnter: (_) async {}),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(RealtimePreJoinPreview), findsOneWidget);
      expect(find.byType(RealtimePreJoinCheckList), findsOneWidget);
      expect(find.byType(RealtimePreJoinJoinButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
    'media controls show checkmark beside switches when permissions are granted',
    (tester) async {
      final controller = RealtimePreJoinController(
        runCheck: () async => _check(role: MediaRole.participant),
        openPreview: (_, _) async => _Preview(),
        permissionRequester: const _PermissionRequester(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await tester.pumpWidget(
        MaterialApp(
          home: RealtimePreJoinScope(
            controller: controller,
            child: const Scaffold(body: RealtimePreJoinMediaControls()),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
      expect(find.byIcon(Icons.close_rounded), findsNothing);
    },
  );

  testWidgets(
    'media controls show cross beside switches and trigger request when permission denied',
    (tester) async {
      var requestedMic = false;
      final controller = RealtimePreJoinController(
        runCheck: () async => _check(role: MediaRole.participant),
        openPreview: (_, _) async => _Preview(),
        permissionRequester: _DenyingPermissionRequester(
          onRequestMic: () => requestedMic = true,
        ),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await tester.pumpWidget(
        MaterialApp(
          home: RealtimePreJoinScope(
            controller: controller,
            child: const Scaffold(body: RealtimePreJoinMediaControls()),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.close_rounded), findsNWidgets(2));

      await tester.tap(find.byIcon(Icons.close_rounded).first);
      await tester.pump();
      expect(requestedMic, isTrue);
    },
  );

  testWidgets(
    'pending macOS-style permission is requested on switch tap and track enabled',
    (tester) async {
      final requester = _GrantOnRequest();
      final controller = RealtimePreJoinController(
        runCheck: () async => _check(role: MediaRole.participant),
        openPreview: (_, _) async => _Preview(),
        permissionRequester: requester,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: RealtimePreJoinScope(
            controller: controller,
            child: const Scaffold(body: RealtimePreJoinMediaControls()),
          ),
        ),
      );
      await tester.pump();
      expect(find.byIcon(Icons.help_outline_rounded), findsNWidgets(2));
      await tester.tap(find.byType(CupertinoSwitch).first);
      await tester.pumpAndSettle();
      expect(
        controller.permissions[MediaPermissionKind.microphone],
        MediaPermissionState.granted,
      );
      expect(controller.preview!.settings.microphoneEnabled, isTrue);
      await tester.tap(find.byType(CupertinoSwitch).last);
      await tester.pumpAndSettle();
      expect(
        controller.permissions[MediaPermissionKind.camera],
        MediaPermissionState.granted,
      );
      expect(controller.preview!.settings.cameraEnabled, isTrue);
      expect(find.byIcon(Icons.help_outline_rounded), findsNothing);
    },
  );

  testWidgets(
    'microphone meter stays silent with no real provider audio levels',
    (tester) async {
      final controller = RealtimePreJoinController(
        runCheck: () async => _check(role: MediaRole.participant),
        openPreview: (_, _) async => _Preview(),
        permissionRequester: const _PermissionRequester(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await tester.pumpWidget(
        MaterialApp(
          home: RealtimePreJoinScope(
            controller: controller,
            child: const Scaffold(
              body: Column(
                children: [
                  RealtimeMicrophoneLevelMeter(),
                  RealtimeSpeakingBars(),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.bySemanticsLabel('Microphone level'), findsOneWidget);
      final meterSemantics = tester.getSemantics(
        find.byType(RealtimeMicrophoneLevelMeter),
      );
      expect(meterSemantics.value, '0 of 9');

      await controller.setMicrophoneEnabled(true);
      await tester.pump(const Duration(milliseconds: 200));

      final activeMeterSemantics = tester.getSemantics(
        find.byType(RealtimeMicrophoneLevelMeter),
      );
      expect(activeMeterSemantics.value, '0 of 9');

      await controller.setMicrophoneEnabled(false);
      await tester.pump();
      final offMeterSemantics = tester.getSemantics(
        find.byType(RealtimeMicrophoneLevelMeter),
      );
      expect(offMeterSemantics.value, '0 of 9');
    },
  );

  testWidgets('meter follows actual samples and clears on mute', (
    tester,
  ) async {
    final preview = _PreviewWithLevels();
    final controller = RealtimePreJoinController(
      runCheck: () async => _check(role: MediaRole.participant),
      openPreview: (_, _) async => preview,
      permissionRequester: const _PermissionRequester(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimePreJoinScope(
          controller: controller,
          child: const Scaffold(body: RealtimeMicrophoneLevelMeter()),
        ),
      ),
    );
    await controller.setMicrophoneEnabled(true);
    await tester.pump();
    expect(
      tester.getSemantics(find.byType(RealtimeMicrophoneLevelMeter)).value,
      '0 of 9',
    );

    preview.emitLevel(0.20);
    await tester.pump();
    expect(
      tester.getSemantics(find.byType(RealtimeMicrophoneLevelMeter)).value,
      isNot('0 of 9'),
    );
    // Without more capture samples, the visualizer expires the stale peak.
    await tester.pump(const Duration(milliseconds: 700));
    expect(
      tester.getSemantics(find.byType(RealtimeMicrophoneLevelMeter)).value,
      '0 of 9',
    );
    preview.emitLevel(0.20);
    await tester.pump();
    expect(
      tester.getSemantics(find.byType(RealtimeMicrophoneLevelMeter)).value,
      isNot('0 of 9'),
    );
    preview.emitLevel(0);
    await tester.pump();
    expect(
      tester.getSemantics(find.byType(RealtimeMicrophoneLevelMeter)).value,
      '0 of 9',
    );

    preview.emitLevel(0.20);
    await tester.pump();
    await controller.setMicrophoneEnabled(false);
    await tester.pump();
    expect(
      tester.getSemantics(find.byType(RealtimeMicrophoneLevelMeter)).value,
      '0 of 9',
    );
    await preview.closeLevels();
  });

  testWidgets('enabled microphone keeps the compact inline waveform', (
    tester,
  ) async {
    final preview = _PreviewWithLevels();
    final controller = RealtimePreJoinController(
      runCheck: () async => _check(role: MediaRole.participant),
      openPreview: (_, _) async => preview,
      permissionRequester: const _PermissionRequester(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimePreJoinScope(
          controller: controller,
          child: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 440,
                child: RealtimePreJoinMediaControls(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RealtimeMicrophoneLevelMeter), findsNothing);

    await controller.setMicrophoneEnabled(true);
    await tester.pumpAndSettle();
    final meter = find.byType(RealtimeMicrophoneLevelMeter);
    expect(meter, findsOneWidget);
    expect(tester.getSize(meter).height, 22);
    expect(tester.getSize(meter).width, closeTo(84, 1));
    final microphoneLabel = find.text('Microphone');
    expect(microphoneLabel, findsOneWidget);
    expect(
      tester.getRect(meter).left,
      greaterThan(tester.getRect(microphoneLabel).right),
    );
    expect(
      tester.getCenter(meter).dy,
      closeTo(tester.getCenter(microphoneLabel).dy, 4),
    );
    expect(tester.getSemantics(meter).value, '0 of 9');

    preview.emitLevel(0.25);
    await tester.pump();
    expect(tester.getSemantics(meter).value, isNot('0 of 9'));
    preview.emitLevel(0);
    await tester.pump();
    expect(tester.getSemantics(meter).value, '0 of 9');

    await controller.setMicrophoneEnabled(false);
    await tester.pumpAndSettle();
    expect(meter, findsNothing);
    await preview.closeLevels();
    expect(tester.takeException(), isNull);
  });
}

class _UnknownPermissionRequester implements MediaPermissionRequester {
  const _UnknownPermissionRequester();

  @override
  bool get canOpenAppSettings => false;
  @override
  Future<bool> openAppSettings() async => false;
  @override
  Future<MediaPermissionState> request(MediaPermissionKind kind) async =>
      MediaPermissionState.unknown;
  @override
  Future<MediaPermissionState> status(MediaPermissionKind kind) async =>
      MediaPermissionState.unknown;
}

class _FitAwarePreview extends _Preview {
  @override
  MediaVideoTrack? get cameraTrack =>
      settings.cameraEnabled ? const _PortraitPreviewTrack() : null;

  @override
  MediaTrackRenderer get renderer => const _FitAwareRenderer();
}

class _PortraitPreviewTrack extends MediaVideoTrack {
  const _PortraitPreviewTrack();
  @override
  String get id => 'portrait-preview';
  @override
  String get participantId => 'self';
  @override
  bool get isLocal => true;
  @override
  bool get isScreenShare => false;
  @override
  int get width => 640;
  @override
  int get height => 360;
}

class _FitAwareRenderer extends MediaTrackRenderer {
  const _FitAwareRenderer();
  @override
  bool handlesVideoFit(MediaVideoTrack track) => true;
  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) => const Center(
    child: AspectRatio(
      aspectRatio: 9 / 16,
      child: ColoredBox(color: Colors.black),
    ),
  );
}

class _PreviewWithLevels extends _Preview
    implements MediaLocalPreviewAudioLevels {
  final _samples = StreamController<double>.broadcast(sync: true);

  @override
  Stream<double> get microphoneLevels => _samples.stream;

  void emitLevel(double value) => _samples.add(value);
  Future<void> closeLevels() => _samples.close();
}

class _GrantOnRequest implements MediaPermissionRequester {
  final _granted = <MediaPermissionKind>{};

  @override
  bool get canOpenAppSettings => true;
  @override
  Future<bool> openAppSettings() async => true;
  @override
  Future<MediaPermissionState> status(MediaPermissionKind kind) async =>
      _granted.contains(kind)
      ? MediaPermissionState.granted
      : MediaPermissionState.unknown;
  @override
  Future<MediaPermissionState> request(MediaPermissionKind kind) async {
    _granted.add(kind);
    return MediaPermissionState.granted;
  }
}

class _DenyingPermissionRequester implements MediaPermissionRequester {
  const _DenyingPermissionRequester({this.onRequestMic});
  final VoidCallback? onRequestMic;

  @override
  bool get canOpenAppSettings => true;
  @override
  Future<bool> openAppSettings() async => true;
  @override
  Future<MediaPermissionState> status(MediaPermissionKind kind) async =>
      MediaPermissionState.denied;
  @override
  Future<MediaPermissionState> request(MediaPermissionKind kind) async {
    if (kind == MediaPermissionKind.microphone) {
      onRequestMic?.call();
    }
    return MediaPermissionState.denied;
  }
}

MediaPreJoinResult _check({
  MediaRole role = MediaRole.viewer,
  String providerId = 'fake',
}) => MediaPreJoinResult(
  role: role,
  providerId: providerId,
  checks: const [
    MediaPreJoinCheck(
      type: MediaPreJoinCheckType.backend,
      status: MediaPreJoinStatus.passed,
      severity: MediaPreJoinSeverity.blocking,
      message: 'Backend ready',
    ),
  ],
);

class _PermissionRequester implements MediaPermissionRequester {
  const _PermissionRequester();

  @override
  bool get canOpenAppSettings => false;
  @override
  Future<bool> openAppSettings() async => false;
  @override
  Future<MediaPermissionState> status(MediaPermissionKind kind) async =>
      MediaPermissionState.granted;
  @override
  Future<MediaPermissionState> request(MediaPermissionKind kind) async =>
      MediaPermissionState.granted;
}

class _Renderer extends MediaTrackRenderer {
  const _Renderer();
  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      const SizedBox.shrink();
}

class _Preview extends Fake implements MediaLocalPreviewSession {
  MediaLocalPreviewSettings _settings = const MediaLocalPreviewSettings();
  int disposeCount = 0;

  @override
  MediaLocalPreviewSettings get settings => _settings;
  @override
  MediaVideoTrack? get cameraTrack => null;
  @override
  MediaTrackRenderer get renderer => const _Renderer();
  @override
  String get providerId => 'fake';
  @override
  MediaRole get role => MediaRole.participant;
  @override
  MediaCapabilities get capabilities => const MediaCapabilities.meeting();
  @override
  Future<void> setMicrophoneEnabled(bool enabled) async =>
      _settings = _settings.copyWith(microphoneEnabled: enabled);
  @override
  Future<void> setCameraEnabled(bool enabled) async =>
      _settings = _settings.copyWith(cameraEnabled: enabled);
  @override
  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async => const [];
  @override
  Future<void> selectMediaDevice(MediaDevice device) async {}
  @override
  Future<void> dispose() async => disposeCount++;
}
