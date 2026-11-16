import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'duplicate Pre-Join enters and forced route removal do not create late navigation',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final gate = Completer<void>();
      final preview = _FakeLocalPreview();
      Route<dynamic>? preJoinRoute;
      var connectionAttempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => _showPreJoin(
                  context,
                  runCheck: _readyResult,
                  openPreview: (_, _) async => preview,
                  permissionRequester: const _TestPermissionRequester(),
                  onEnter: (pageContext, _) async {
                    connectionAttempts++;
                    preJoinRoute = ModalRoute.of(pageContext);
                    await gate.future;
                    if (!pageContext.mounted) return;
                    Navigator.of(
                      pageContext,
                    ).pushReplacement<void, MediaLocalPreviewSettings>(
                      MaterialPageRoute(
                        builder: (_) => const Scaffold(body: Text('Late room')),
                      ),
                    );
                  },
                ),
                child: const Text('Prepare'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Prepare'));
      await tester.pumpAndSettle();
      final join = find.text('Join meeting');
      await tester.tap(join);
      await tester.pump();
      expect(connectionAttempts, 1);
      expect(preview.disposeCalls, 1);
      expect(
        find.descendant(
          of: find.byWidgetPredicate(
            (widget) => widget is AbsorbPointer && widget.child is ColoredBox,
          ),
          matching: find.text('Entering room…'),
        ),
        findsOneWidget,
      );
      // The in-flight join disables the button and cannot be scheduled again.
      expect(find.byType(RealtimePreJoinPage), findsOneWidget);
      navigatorKey.currentState!.removeRoute(preJoinRoute!);
      await tester.pumpAndSettle();
      gate.complete();
      await tester.pumpAndSettle();
      expect(connectionAttempts, 1);
      expect(preview.disposeCalls, 1);
      expect(find.text('Prepare'), findsOneWidget);
      expect(find.text('Late room'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('room entry stays on Pre-Join until the room is connected', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    final preview = _FakeLocalPreview();
    final connectionReady = Completer<void>();
    var joinCalls = 0;
    MediaLocalPreviewSettings? joiningSettings;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => _showPreJoin(
                  context,
                  runCheck: _readyResult,
                  openPreview: (_, _) async => preview,
                  permissionRequester: const _TestPermissionRequester(),
                  onEnter: (preJoinContext, settings) async {
                    joinCalls++;
                    joiningSettings = settings;
                    await connectionReady.future;
                    if (!preJoinContext.mounted) return;
                    await Navigator.of(
                      preJoinContext,
                    ).pushReplacement<void, MediaLocalPreviewSettings>(
                      MaterialPageRoute(
                        builder: (_) => Scaffold(
                          appBar: AppBar(title: const Text('Connected room')),
                          body: const Text('Live media room'),
                        ),
                      ),
                    );
                  },
                ),
                child: const Text('Open preparation'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open preparation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Join meeting'));
    await tester.pump();
    expect(joinCalls, 1);
    expect(
      find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget is AbsorbPointer && widget.child is ColoredBox,
        ),
        matching: find.text('Entering room…'),
      ),
      findsOneWidget,
    );
    expect(find.byType(RealtimePreJoinPage), findsOneWidget);
    expect(find.text('Connected room'), findsNothing);
    expect(joiningSettings, isNotNull);
    expect(preview.disposeCalls, 1);
    for (final size in <Size>[
      const Size(320, 640),
      const Size(390, 844),
      const Size(1024, 768),
    ]) {
      tester.view.physicalSize = size;
      await tester.pump();
      expect(
        find.descendant(
          of: find.byWidgetPredicate(
            (widget) => widget is AbsorbPointer && widget.child is ColoredBox,
          ),
          matching: find.text('Entering room…'),
        ),
        findsOneWidget,
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'Joining overlay overflow at $size',
      );
    }

    connectionReady.complete();
    await tester.pumpAndSettle();
    expect(find.text('Connected room'), findsOneWidget);
    expect(find.text('Entering room…'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Open preparation'), findsOneWidget);
    expect(preview.disposeCalls, 1);
  });

  testWidgets('failed room entry displays error on Pre-Join and allows retry', (
    tester,
  ) async {
    final previews = <_FakeLocalPreview>[];
    var joinCalls = 0;
    final submittedSettings = <MediaLocalPreviewSettings>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => _showPreJoin(
                  context,
                  runCheck: _readyResult,
                  openPreview: (_, _) async {
                    final preview = _FakeLocalPreview();
                    previews.add(preview);
                    return preview;
                  },
                  permissionRequester: const _TestPermissionRequester(),
                  onEnter: (pageContext, settings) async {
                    submittedSettings.add(settings);
                    joinCalls++;
                    if (joinCalls == 1) throw StateError('Token expired');
                    if (pageContext.mounted) {
                      Navigator.of(pageContext).pop(settings);
                    }
                  },
                ),
                child: const Text('Open preparation'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open preparation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Join meeting'));
    await tester.pumpAndSettle();
    // Raw host exceptions are normalized; native/token payloads stay out of UI.
    expect(find.textContaining('Token expired'), findsNothing);
    final controller = RealtimePreJoinScope.of(
      tester.element(find.byType(RealtimePreJoinJoinButton)),
    );
    expect(controller.joinError?.code, RealtimeErrorCode.invalidState);
    expect(find.textContaining(controller.joinError!.message), findsOneWidget);
    expect(find.text('Join meeting'), findsOneWidget);
    expect(find.text('Open preparation'), findsNothing);
    expect(previews.first.disposeCalls, 1);
    expect(previews.length, 2, reason: 'Restore local preview after failure');

    await tester.tap(find.text('Join meeting'));
    await tester.pumpAndSettle();
    expect(joinCalls, 2);
    expect(submittedSettings, hasLength(2));
    expect(find.text('Open preparation'), findsOneWidget);
    expect(previews.last.disposeCalls, 1);
  });

  testWidgets('pre-join page releases local capture when canceled', (
    tester,
  ) async {
    final preview = _FakeLocalPreview();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => _showPreJoin(
                  context,
                  runCheck: _readyResult,
                  openPreview: (_, _) async => preview,
                  permissionRequester: const _TestPermissionRequester(),
                  displayName: 'Morgan',
                ),
                child: const Text('Open preparation'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open preparation'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Morgan'), findsOneWidget);
    expect(preview.settings.microphoneEnabled, isFalse);
    expect(preview.settings.cameraEnabled, isFalse);
    expect(
      tester.widget<MediaTrackView>(find.byType(MediaTrackView)).track,
      isNull,
    );

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(preview.disposeCalls, 1);
    expect(find.text('Open preparation'), findsOneWidget);
  });

  testWidgets(
    'pre-join microphone button requests iOS permission before capture',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final preview = _FakeLocalPreview();
      final permissions = _MicrophonePermissionRequester();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => _showPreJoin(
                  context,
                  runCheck: _readyResult,
                  openPreview: (_, _) async => preview,
                  permissionRequester: permissions,
                ),
                child: const Text('Open preparation'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open preparation'));
      await tester.pumpAndSettle();
      expect(preview.settings.microphoneEnabled, isFalse);
      await tester.ensureVisible(find.byTooltip('Turn on microphone'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Turn on microphone'));
      await tester.pumpAndSettle();
      expect(permissions.microphoneRequests, 1);
      expect(preview.settings.microphoneEnabled, isTrue);
      await tester.tap(find.byTooltip('Turn off microphone'));
      await tester.pumpAndSettle();
      expect(preview.settings.microphoneEnabled, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pre-join blur selection is returned and applied to preview', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preview = _FakeLocalPreview();
    MediaLocalPreviewSettings? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  chosen = await _showPreJoin(
                    context,
                    runCheck: _blurReadyResult,
                    openPreview: (_, _) async => preview,
                    permissionRequester: const _TestPermissionRequester(),
                  );
                },
                child: const Text('Open preparation'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open preparation'));
    await tester.pumpAndSettle();
    // Devices and effects live behind the preview gear by default.
    await tester.tap(find.byTooltip('Device settings'));
    await tester.pumpAndSettle();
    expect(find.text('Background blur'), findsOneWidget);

    await tester.ensureVisible(find.text('Background blur'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Background blur'));
    await tester.pumpAndSettle();
    expect(preview.backgroundCalls, [const MediaBackgroundEffect.blur()]);

    await tester.tap(find.text('Join meeting'));
    await tester.pumpAndSettle();
    expect(chosen?.backgroundEffect, const MediaBackgroundEffect.blur());
  });

  testWidgets('pre-join page preserves selected devices and media state', (
    tester,
  ) async {
    final preview = _FakeLocalPreview();
    MediaLocalPreviewSettings? chosen;
    addTearDown(() => tester.view.resetPhysicalSize());
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  chosen = await _showPreJoin(
                    context,
                    runCheck: _readyResult,
                    openPreview: (_, _) async => preview,
                    permissionRequester: const _TestPermissionRequester(),
                  );
                },
                child: const Text('Open preparation'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open preparation'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Device settings'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byType(CupertinoSwitch).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CupertinoSwitch).first);
    await tester.pump();
    expect(preview.settings.microphoneEnabled, isTrue);
    final microphonePicker = find.byWidgetPredicate(
      (widget) => widget is DropdownButton<MediaDevice>,
    );
    // Device fields follow the reference order: camera, microphone, speakers.
    await tester.ensureVisible(microphonePicker.at(1));
    await tester.pumpAndSettle();
    await tester.tap(microphonePicker.at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('USB microphone').last);
    await tester.pumpAndSettle();
    expect(preview.settings.microphone?.id, 'mic-2');

    await tester.tap(find.text('Join meeting'));
    await tester.pumpAndSettle();
    expect(chosen?.microphoneEnabled, isTrue);
    expect(chosen?.microphone?.id, 'mic-2');
    expect(preview.disposeCalls, 1);
  });

  testWidgets(
    'unsupported local preview still lets a ready attendee continue',
    (tester) async {
      MediaLocalPreviewSettings? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    chosen = await _showPreJoin(
                      context,
                      runCheck: _readyResult,
                      openPreview: (_, _) async => null,
                      permissionRequester: const _TestPermissionRequester(),
                    );
                  },
                  child: const Text('Open preparation'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open preparation'));
      await tester.pumpAndSettle();

      // If preview creation is unsupported/failed, entry controls must not
      // disappear along with the camera renderer.
      expect(find.byTooltip('Turn on microphone'), findsOneWidget);
      expect(find.byTooltip('Turn on camera'), findsOneWidget);
      expect(find.byTooltip('Device settings'), findsOneWidget);
      await tester.tap(find.byTooltip('Device settings'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('prejoin-preview-recovery-card')),
        findsOneWidget,
      );

      await tester.tap(find.text('Join meeting'));
      await tester.pumpAndSettle();
      expect(chosen, isNotNull);
      expect(chosen!.cameraEnabled, isFalse);
    },
  );

  testWidgets('missing initial preview can be recovered by camera control', (
    tester,
  ) async {
    final recovered = _FakeLocalPreview();
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => _showPreJoin(
                context,
                runCheck: _readyResult,
                openPreview: (_, _) async {
                  attempts++;
                  return attempts == 1 ? null : recovered;
                },
                permissionRequester: const _TestPermissionRequester(),
              ),
              child: const Text('Open preparation'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open preparation'));
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(find.byTooltip('Turn on camera'), findsOneWidget);

    await tester.tap(find.byTooltip('Turn on camera'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(recovered.settings.cameraEnabled, isTrue);
    expect(find.byTooltip('Turn off camera'), findsOneWidget);

    await tester.tap(find.byTooltip('Turn on microphone'));
    await tester.pumpAndSettle();
    expect(recovered.settings.microphoneEnabled, isTrue);
    expect(find.byTooltip('Turn off microphone'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<MediaPreJoinResult> _readyResult() async => const MediaPreJoinResult(
  role: MediaRole.participant,
  providerId: 'fake',
  checks: [
    MediaPreJoinCheck(
      type: MediaPreJoinCheckType.backend,
      status: MediaPreJoinStatus.passed,
      severity: MediaPreJoinSeverity.blocking,
      message: 'Backend reachable.',
    ),
  ],
);

Future<MediaPreJoinResult> _blurReadyResult() async => const MediaPreJoinResult(
  role: MediaRole.participant,
  providerId: 'fake',
  backgroundCapabilities: MediaBackgroundCapabilities(canBlur: true),
  checks: [
    MediaPreJoinCheck(
      type: MediaPreJoinCheckType.backend,
      status: MediaPreJoinStatus.passed,
      severity: MediaPreJoinSeverity.blocking,
      message: 'Backend reachable.',
    ),
  ],
);

class _FakeLocalPreview
    implements MediaLocalPreviewSession, MediaBackgroundEffectsController {
  int disposeCalls = 0;
  final List<MediaBackgroundEffect> backgroundCalls = [];
  MediaLocalPreviewSettings _settings = const MediaLocalPreviewSettings();
  final _track = const _TestVideoTrack();

  @override
  String get providerId => 'fake';
  @override
  MediaRole get role => MediaRole.participant;
  @override
  MediaCapabilities get capabilities => const MediaCapabilities(
    canPublishAudio: true,
    canPublishVideo: true,
    canBlurBackground: true,
    canEnumerateAudioDevices: true,
    canEnumerateMicrophones: true,
    canEnumerateCameras: true,
    canSelectMicrophone: true,
    canSelectCamera: true,
    canSelectAudioOutput: true,
  );
  @override
  MediaVideoTrack? get cameraTrack => _settings.cameraEnabled ? _track : null;
  @override
  MediaTrackRenderer get renderer => const _TestTrackRenderer();
  @override
  MediaLocalPreviewSettings get settings => _settings;

  @override
  MediaBackgroundCapabilities get backgroundCapabilities =>
      const MediaBackgroundCapabilities(canBlur: true);

  @override
  MediaBackgroundEffect get backgroundEffect => _settings.backgroundEffect;

  @override
  Future<void> setBackgroundEffect(MediaBackgroundEffect effect) async {
    backgroundCalls.add(effect);
    _settings = _settings.copyWith(backgroundEffect: effect);
  }

  @override
  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async => const [
    MediaDevice(
      id: 'mic-1',
      label: 'Built-in microphone',
      kind: MediaDeviceKind.microphone,
    ),
    MediaDevice(
      id: 'mic-2',
      label: 'USB microphone',
      kind: MediaDeviceKind.microphone,
    ),
    MediaDevice(
      id: 'camera-1',
      label: 'Built-in camera',
      kind: MediaDeviceKind.camera,
    ),
    MediaDevice(
      id: 'speaker-1',
      label: 'Built-in speaker',
      kind: MediaDeviceKind.audioOutput,
    ),
  ];

  @override
  Future<void> selectMediaDevice(MediaDevice device) async {
    _settings = _settings.copyWith(
      microphone: device.kind == MediaDeviceKind.microphone
          ? device
          : _settings.microphone,
      camera: device.kind == MediaDeviceKind.camera ? device : _settings.camera,
      audioOutput: device.kind == MediaDeviceKind.audioOutput
          ? device
          : _settings.audioOutput,
    );
  }

  @override
  Future<void> setMicrophoneEnabled(bool enabled) async {
    _settings = _settings.copyWith(microphoneEnabled: enabled);
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    _settings = _settings.copyWith(cameraEnabled: enabled);
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

class _TestVideoTrack implements MediaVideoTrack {
  const _TestVideoTrack();
  @override
  String get id => 'preview-track';
  @override
  String get participantId => 'local-preview';
  @override
  bool get isLocal => true;
  @override
  bool get isScreenShare => false;
  @override
  int get width => 1280;
  @override
  int get height => 720;
  @override
  double get aspectRatio => 16 / 9;
}

class _TestTrackRenderer extends MediaTrackRenderer {
  const _TestTrackRenderer();
  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      const ColoredBox(color: Colors.blueGrey);
}

class _TestPermissionRequester implements MediaPermissionRequester {
  const _TestPermissionRequester();

  @override
  bool get canOpenAppSettings => false;

  @override
  Future<bool> openAppSettings() async => false;

  @override
  Future<MediaPermissionState> request(MediaPermissionKind kind) async =>
      MediaPermissionState.granted;

  @override
  Future<MediaPermissionState> status(MediaPermissionKind kind) async =>
      MediaPermissionState.granted;
}

class _MicrophonePermissionRequester implements MediaPermissionRequester {
  int microphoneRequests = 0;

  @override
  bool get canOpenAppSettings => true;

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<MediaPermissionState> status(MediaPermissionKind kind) async =>
      kind == MediaPermissionKind.microphone && microphoneRequests == 0
      ? MediaPermissionState.denied
      : MediaPermissionState.granted;

  @override
  Future<MediaPermissionState> request(MediaPermissionKind kind) async {
    if (kind == MediaPermissionKind.microphone) microphoneRequests++;
    return MediaPermissionState.granted;
  }
}

Future<MediaLocalPreviewSettings?> _showPreJoin(
  BuildContext context, {
  required RealtimePreJoinCheck runCheck,
  required RealtimePreJoinOpenPreview openPreview,
  required MediaPermissionRequester permissionRequester,
  RealtimePreJoinEnter? onEnter,
  String displayName = '',
}) => Navigator.of(context).push<MediaLocalPreviewSettings>(
  MaterialPageRoute(
    builder: (_) => RealtimePreJoinPage(
      runCheck: runCheck,
      openPreview: openPreview,
      permissionRequester: permissionRequester,
      roomLabel: 'room-test',
      displayName: displayName,
      onEnter:
          onEnter ??
          (pageContext, settings) async {
            Navigator.of(pageContext).pop(settings);
          },
    ),
  ),
);
