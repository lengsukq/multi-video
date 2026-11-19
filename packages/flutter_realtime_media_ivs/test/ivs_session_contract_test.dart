import 'dart:async';
import 'dart:convert';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_diagnostics.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_webview2_runtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_media_ivs/flutter_realtime_media_ivs.dart';
import 'package:flutter_realtime_media_ivs/src/ivs_windows_webview2.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeIvsEngine implements IvsEngine {
  Future<void>? pendingJoin;
  IvsEngineEvents events = const IvsEngineEvents();
  final List<String> calls = [];
  IvsJoinInfo? joinedInfo;
  String? exchangedToken;
  MediaRole? exchangedRole;
  List<MediaAudioDevice> audioDevices = [
    MediaAudioDevice.fromLabel('Speaker', id: 'speaker'),
    MediaAudioDevice.fromLabel('Bluetooth Headset', id: 'bt-1'),
  ];
  MediaAudioDevice? selectedAudioDevice;

  @override
  Future<void> join(IvsJoinInfo info, IvsEngineEvents events) async {
    joinedInfo = info;
    this.events = events;
    calls.add('join');
    if (pendingJoin != null) await pendingJoin;
  }

  @override
  Future<void> exchangeToken(
    String token, {
    MediaRole? role,
    List<String>? capabilities,
  }) async {
    exchangedToken = token;
    exchangedRole = role;
    calls.add('exchangeToken');
  }

  @override
  Future<void> leave() async => calls.add('leave');

  @override
  Future<void> setMuted(bool muted) async => calls.add('muted:$muted');

  @override
  Future<void> setVideoEnabled(bool enabled) async =>
      calls.add('video:$enabled');

  @override
  Future<void> switchCamera(MediaCameraPosition position) async =>
      calls.add('camera:${position.name}');

  @override
  Future<List<MediaAudioDevice>> listAudioDevices() async {
    calls.add('listAudioDevices');
    return audioDevices;
  }

  @override
  Future<void> selectAudioDevice(MediaAudioDevice device) async {
    selectedAudioDevice = device;
    calls.add('selectAudioDevice:${device.id ?? device.label}');
  }

  @override
  Future<void> requestStats() async => calls.add('stats');

  @override
  Future<void> dispose() async => calls.add('dispose');
}

Map<String, dynamic> _joinJson({
  MediaRole role = MediaRole.participant,
  String token = 'token-1',
  String tokenParticipantId = 'aws-participant-1',
  int? expiresAtMs,
}) => {
  'provider': 'ivs',
  'roomCode': '123456',
  'participantId': 'user-1',
  'displayName': 'User One',
  'role': role.wireName,
  'ivs': {
    'stageArn': 'arn:aws:ivs:us-west-2:123456789012:stage/demo',
    'token': token,
    'tokenParticipantId': tokenParticipantId,
    'capabilities': role == MediaRole.viewer
        ? ['SUBSCRIBE']
        : ['PUBLISH', 'SUBSCRIBE'],
    'expiresAtMs':
        expiresAtMs ??
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    'region': 'us-west-2',
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Windows IVS defaults on but rejects unavailable WebView2 runtime',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(
        const bool.fromEnvironment(
          'AWS_IVS_WINDOWS_WEBVIEW2_EXPERIMENTAL',
          defaultValue: true,
        ),
        isTrue,
      );
      const channel = MethodChannel(
        'com.oneplusdream.flutter_realtime_media_ivs/methods',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect(await probeNativeIvsAvailability(), isFalse);
      await expectLater(
        createNativeIvsEngine(),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.unsupportedPlatform,
          ),
        ),
      );
      var enumerated = false;
      final factory = IvsSessionFactory(
        availabilityProbe: () async => false,
        deviceProbe: () async {
          enumerated = true;
          return const IvsDeviceCounts(microphones: 1, cameras: 1);
        },
      );
      final report = await factory.runPreJoinProbe(
        const MediaPreJoinProbeRequest(
          providerId: 'ivs',
          role: MediaRole.participant,
          requirements: MediaPreJoinRequirements(
            microphone: MediaPreJoinRequirement.required,
            camera: MediaPreJoinRequirement.required,
          ),
        ),
      );
      expect(report.checks.single.isBlocking, isTrue);
      expect(report.checks.single.type, MediaPreJoinCheckType.provider);
      expect(enumerated, isFalse);
      messenger.setMockMethodCallHandler(channel, (call) async => true);
      // MethodChannel mocks cannot satisfy the real WebView2 browser probe;
      // the experiment is enabled by default but unavailable without a runtime.
      expect(await probeNativeIvsAvailability(), isFalse);
    },
  );

  test('Windows IVS reports browser API compatibility distinctly', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final report =
        await IvsSessionFactory(
          availabilityProbe: () async => false,
          windowsDiagnosticProbe: () =>
              AwsWindowsRuntimeDiagnostic.webRtcApiUnavailable,
        ).runPreJoinProbe(
          const MediaPreJoinProbeRequest(
            providerId: 'ivs',
            role: MediaRole.viewer,
            requirements: MediaPreJoinRequirements(),
          ),
        );
    final check = report.checks.single;
    expect(check.status, MediaPreJoinStatus.unsupported);
    expect(check.message, contains('WebRTC APIs are unavailable'));
    expect(check.details, {'diagnosticCode': 'webRtcApiUnavailable'});
  });
  test(
    'Windows IVS native channel alone does not enable WebView2 Stage',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel(
        'com.oneplusdream.flutter_realtime_media_ivs/methods',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect(await probeNativeIvsAvailability(), isFalse);
      await expectLater(
        createNativeIvsEngine(),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.unsupportedPlatform,
          ),
        ),
      );
      var enumerated = false;
      final factory = IvsSessionFactory(
        availabilityProbe: () async => false,
        deviceProbe: () async {
          enumerated = true;
          return const IvsDeviceCounts(microphones: 1, cameras: 1);
        },
      );
      final report = await factory.runPreJoinProbe(
        const MediaPreJoinProbeRequest(
          providerId: 'ivs',
          role: MediaRole.participant,
          requirements: MediaPreJoinRequirements(
            microphone: MediaPreJoinRequirement.required,
            camera: MediaPreJoinRequirement.required,
          ),
        ),
      );
      expect(report.checks.single.isBlocking, isTrue);
      expect(report.checks.single.type, MediaPreJoinCheckType.provider);
      expect(enumerated, isFalse);
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'isAvailable');
        return true;
      });
      // The old native channel mock does not initialize the WebView2 runtime.
      expect(await probeNativeIvsAvailability(), isFalse);
    },
  );
  test(
    'IVS iOS screen capture replaces its single video stream and restores camera',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const capture = MethodChannel(
        'flutter_realtime_processed_video/ios_system_screen_capture',
      );
      const ivsChannel = MethodChannel(
        'com.oneplusdream.flutter_realtime_media_ivs/methods',
      );
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(capture, (call) async {
        calls.add(call.method);
        if (call.method == 'iosScreenCaptureKitAvailable') return true;
        if (call.method == 'iosScreenCaptureKitStart') {
          return {
            'id': 'ivs-screen',
            'kind': 'nativeFrameHub',
            'platform': 'ios',
            'width': 1170,
            'height': 2532,
            'frameRate': 30.0,
          };
        }
        return null;
      });
      messenger.setMockMethodCallHandler(ivsChannel, (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(capture, null);
        messenger.setMockMethodCallHandler(ivsChannel, null);
      });
      final info = IvsJoinInfo.fromJson(_joinJson());
      final session =
          IvsSessionFactory(
                engineFactory: () async => _FakeIvsEngine(),
              ).createSession(info)
              as InteractiveMediaSession;
      await session.join(info);
      expect(session.capabilities.canScreenShare, isTrue);
      await session.setScreenShareEnabled(true);
      expect(session.snapshot.localScreenShareEnabled, isTrue);
      expect(calls, contains('attachIosScreenCaptureKitSource'));
      await session.setScreenShareEnabled(false);
      expect(session.snapshot.localScreenShareEnabled, isFalse);
      expect(calls, contains('detachIosScreenCaptureKitSource'));
      await session.dispose();
    },
  );

  test(
    'IVS macOS supports desktop screen source selection and sharing',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const ivsChannel = MethodChannel(
        'com.oneplusdream.flutter_realtime_media_ivs/methods',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(ivsChannel, (call) async {
        calls.add(call.method);
        if (call.method == 'listScreenShareSources') {
          return const [
            {'id': 'display:1', 'name': 'Main Display', 'kind': 'display'},
            {'id': 'window:9', 'name': 'Slides', 'kind': 'window'},
          ];
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(ivsChannel, null));
      final info = IvsJoinInfo.fromJson(_joinJson());
      final session =
          IvsSessionFactory(
                engineFactory: () async => _FakeIvsEngine(),
              ).createSession(info)
              as InteractiveMediaSession;
      await session.join(info);
      expect(session.capabilities.canScreenShare, isTrue);
      final selector = session as MediaScreenShareSourceSelector;
      final sources = await selector.listScreenShareSources();
      expect(sources, hasLength(2));
      await selector.selectScreenShareSource(sources.last);
      await session.setScreenShareEnabled(true);
      expect(session.snapshot.localScreenShareEnabled, isTrue);
      await session.setScreenShareEnabled(false);
      expect(session.snapshot.localScreenShareEnabled, isFalse);
      expect(
        calls,
        containsAll([
          'listScreenShareSources',
          'selectScreenShareSource',
          'setScreenShareEnabled',
        ]),
      );
      await session.dispose();
    },
  );

  for (final disposing in [false, true]) {
    test(
      'late IVS refresh preserves the next active owner after $disposing',
      () async {
        final engine = _FakeIvsEngine();
        final factory = IvsSessionFactory(engineFactory: () async => engine);
        final initial = IvsJoinInfo.fromJson(
          _joinJson(expiresAtMs: DateTime.now().millisecondsSinceEpoch + 10),
        );
        final session = factory.createSession(initial);
        addTearDown(session.dispose);

        final pending = Completer<MediaJoinInfo>();
        final started = Completer<void>();
        (session as MediaCredentialRefreshable).setCredentialRefreshCallback((
          current,
        ) {
          started.complete();
          return pending.future;
        });
        await session.join(initial);
        await started.future;
        if (disposing) {
          await session.dispose();
        } else {
          await session.leave();
        }
        final oldJoins = engine.calls.length;
        final calls = List<String>.of(engine.calls);
        final nextFactory = IvsSessionFactory(
          engineFactory: () async => _FakeIvsEngine(),
        );
        final nextInfo = IvsJoinInfo.fromJson(_joinJson());
        final next = nextFactory.createSession(nextInfo);
        addTearDown(next.dispose);
        await next.join(nextInfo);
        engine.events.onParticipantJoined!('stale', 'Stale');
        pending.complete(IvsJoinInfo.fromJson(_joinJson()));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(engine.calls.length, oldJoins);
        expect(engine.calls, calls);
        expect(
          session.state,
          disposing ? MediaSessionState.disposed : MediaSessionState.ended,
        );
        expect(
          session.snapshot.participants.any((p) => p.id == 'stale'),
          isFalse,
        );
        expect(next.state, MediaSessionState.connected);
        final contender = nextFactory.createSession(nextInfo);
        await expectLater(
          contender.join(nextInfo),
          throwsA(
            isA<RealtimeException>().having(
              (error) => error.code,
              'active owner',
              RealtimeErrorCode.invalidState,
            ),
          ),
        );
        await contender.dispose();
      },
    );
  }

  test('IVS native error payload stays out of public messages', () async {
    final engine = _FakeIvsEngine();
    final factory = IvsSessionFactory(engineFactory: () async => engine);
    final info = factory.parseJoinInfo(_joinJson());
    final session = factory.createSession(info);
    addTearDown(session.dispose);
    await session.join(info);
    engine.events.onError!(-99, 'native secret');
    expect(session.snapshot.lastError!.code, RealtimeErrorCode.providerError);
    expect(
      session.snapshot.lastError!.message,
      isNot(contains('native secret')),
    );
  });
  test(
    'IVS rollback preserves join error and attempts disposal after leave fails',
    () async {
      final engine = _FaultIvsEngine();
      final factory = IvsSessionFactory(engineFactory: () async => engine);
      final info = factory.parseJoinInfo(_joinJson());
      final session = factory.createSession(info);
      await expectLater(
        session.join(info),
        throwsA(
          isA<RealtimeException>()
              .having(
                (error) => error.code,
                'primary code',
                RealtimeErrorCode.invalidCredential,
              )
              .having(
                (error) => error.message,
                'safe message',
                isNot(contains('native secret')),
              )
              .having((error) => error.details, 'secondary cleanup', isNotNull),
        ),
      );
      expect(engine.calls, contains('dispose'));
      final nextFactory = IvsSessionFactory(
        engineFactory: () async => _FakeIvsEngine(),
      );
      final next = nextFactory.createSession(info);
      await next.join(info);
      await next.dispose();
      await session.dispose();
    },
  );

  test('IVS late join cannot revive a room after leave', () async {
    final pending = Completer<void>();
    final engine = _FakeIvsEngine()..pendingJoin = pending.future;
    final factory = IvsSessionFactory(engineFactory: () async => engine);
    final info = factory.parseJoinInfo(_joinJson());
    final session = factory.createSession(info);
    final joining = session.join(info);
    final cancelled = expectLater(
      joining,
      throwsA(
        isA<RealtimeException>().having(
          (error) => error.code,
          'code',
          RealtimeErrorCode.cancelled,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await session.leave().timeout(const Duration(seconds: 2));
    expect(session.state, MediaSessionState.ended);
    pending.complete();
    await cancelled;
    expect(session.state, MediaSessionState.ended);
    await session.dispose();
    expect(engine.calls, contains('dispose'));
  });

  test(
    'processed source owns camera control and detaches before leave',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final commands = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final channels = {
        const MethodChannel(
          'com.oneplusdream.flutter_realtime_media_ivs/methods',
        ),
        const MethodChannel('flutter_realtime_processed_video/sources'),
      };
      for (final channel in channels) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          commands.add(call);
          if (call.method == 'listCameras') {
            return [
              {'id': 'front', 'label': 'Front'},
              {'id': 'back', 'label': 'Back'},
            ];
          }
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      }
      final engine = _FakeIvsEngine();
      final factory = IvsSessionFactory(engineFactory: () async => engine);
      final info = factory.parseJoinInfo(_joinJson());
      final session = factory.createSession(info);
      await session.join(info);
      final sink = session as ProcessedVideoSink;
      const source = ProcessedVideoSource(
        id: 'shared-processed-frame-source',
        platform: ProcessedVideoPlatform.android,
        kind: ProcessedVideoSourceKind.nativeFrameHub,
        width: 1280,
        height: 720,
        frameRate: 24,
      );
      expect(session.capabilities.canBlurBackground, isTrue);
      expect(session.capabilities.canReplaceBackgroundImage, isTrue);
      expect(session.snapshot.capabilities.canBlurBackground, isTrue);
      expect(sink.supportsProcessedVideoSource(source), isTrue);
      await sink.attachProcessedVideoSource(source);
      final publisher = session as InteractiveMediaSession;
      await publisher.setVideoEnabled(true);
      await publisher.switchCamera(MediaCameraPosition.back);
      expect(engine.calls, isNot(contains('camera:back')));
      final controller = session as MediaDeviceController;
      final cameras = await controller.listMediaDevices(
        kinds: {MediaDeviceKind.camera},
      );
      expect(cameras.map((c) => c.id), ['front', 'back']);
      await controller.selectMediaDevice(cameras.first);
      await publisher.setVideoEnabled(false);
      expect(
        commands
            .where((c) => c.method == 'selectCamera')
            .map((c) => (c.arguments as Map)['deviceId']),
        ['back', 'front'],
      );
      expect(
        commands
            .where((c) => c.method == 'setEnabled')
            .map((c) => (c.arguments as Map)['enabled']),
        [true, false],
      );
      expect(
        (commands
                .firstWhere((c) => c.method == 'attachProcessedVideoSource')
                .arguments
            as Map)['sourceId'],
        source.id,
      );
      await session.leave();
      expect(
        commands.where((c) => c.method == 'detachProcessedVideoSource'),
        hasLength(1),
      );
      await session.dispose();
      expect(
        commands.where((c) => c.method == 'detachProcessedVideoSource'),
        hasLength(1),
      );
    },
  );

  test('join info rejects a viewer token that can publish', () {
    final json = _joinJson(role: MediaRole.viewer);
    (json['ivs'] as Map<String, dynamic>)['capabilities'] = [
      'PUBLISH',
      'SUBSCRIBE',
    ];

    expect(
      () => IvsJoinInfo.fromJson(json),
      throwsA(
        isA<RealtimeException>().having(
          (error) => error.code,
          'code',
          RealtimeErrorCode.invalidArgument,
        ),
      ),
    );
  });

  test(
    'viewer is subscribe-only and IVS media does not masquerade as chat',
    () async {
      final engine = _FakeIvsEngine();
      final factory = IvsSessionFactory(engineFactory: () async => engine);
      final joinInfo = factory.parseJoinInfo(_joinJson(role: MediaRole.viewer));
      final session = factory.createSession(joinInfo);

      expect(session, isA<BroadcastViewerSession>());
      expect(session.capabilities.canPublishAudio, isFalse);
      expect(session.capabilities.canPublishVideo, isFalse);
      expect(session.capabilities.canSubscribeVideo, isTrue);
      expect(session.capabilities.canSendData, isFalse);

      await session.join(joinInfo);
      await expectLater(
        (session as BroadcastViewerSession).sendMessage('hello'),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.unsupportedFeature,
          ),
        ),
      );
      await session.dispose();
    },
  );

  test(
    'remote participants and camera tracks map into Core snapshots',
    () async {
      final engine = _FakeIvsEngine();
      final factory = IvsSessionFactory(engineFactory: () async => engine);
      final joinInfo = factory.parseJoinInfo(_joinJson());
      final session = factory.createSession(joinInfo);
      await session.join(joinInfo);

      engine.events.onParticipantJoined?.call('remote-1', 'Remote One');
      engine.events.onRemoteVideoChanged?.call('remote-1', true);

      final remote = session.snapshot.participants.singleWhere(
        (participant) => participant.id == 'remote-1',
      );
      expect(remote.displayName, 'Remote One');
      expect(remote.isVideoEnabled, isTrue);
      expect(remote.videoTrack, isA<IvsMediaVideoTrack>());

      engine.events.onRemoteVideoChanged?.call('remote-1', false);
      expect(
        session.snapshot.participants
            .singleWhere((participant) => participant.id == 'remote-1')
            .videoTrack,
        isNull,
      );
      await session.dispose();
    },
  );

  test('credential refresh exchanges token without leave and rejoin', () async {
    final engine = _FakeIvsEngine();
    final factory = IvsSessionFactory(engineFactory: () async => engine);
    final initial = factory.parseJoinInfo(
      _joinJson(
        expiresAtMs: DateTime.now()
            .add(const Duration(milliseconds: 20))
            .millisecondsSinceEpoch,
      ),
    );
    final session = factory.createSession(initial);
    final refreshable = session as MediaCredentialRefreshable;
    refreshable.setCredentialRefreshCallback((current) async {
      return IvsJoinInfo.fromJson(
        _joinJson(token: 'token-2', tokenParticipantId: 'aws-participant-2'),
      );
    });

    await session.join(initial);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(engine.exchangedToken, 'token-2');
    expect(engine.calls.where((call) => call == 'join'), hasLength(1));
    expect(engine.calls.where((call) => call == 'leave'), isEmpty);

    await session.dispose();
  });

  test(
    'pre-join preserves required device severity and skips viewer media',
    () async {
      final factory = IvsSessionFactory(
        engineFactory: () async => _FakeIvsEngine(),
        deviceProbe: () async =>
            const IvsDeviceCounts(microphones: 0, cameras: 1),
      );
      final probe = factory as MediaPreJoinProbe;

      final publisher = await probe.runPreJoinProbe(
        const MediaPreJoinProbeRequest(
          providerId: 'ivs',
          role: MediaRole.participant,
          requirements: MediaPreJoinRequirements(
            microphone: MediaPreJoinRequirement.required,
            camera: MediaPreJoinRequirement.recommended,
            network: MediaPreJoinRequirement.recommended,
          ),
        ),
      );
      final microphone = publisher.checks.singleWhere(
        (check) => check.type == MediaPreJoinCheckType.microphoneDevice,
      );
      expect(microphone.status, MediaPreJoinStatus.failed);
      expect(microphone.isBlocking, isTrue);

      final viewer = await probe.runPreJoinProbe(
        const MediaPreJoinProbeRequest(
          providerId: 'ivs',
          role: MediaRole.viewer,
          requirements: MediaPreJoinRequirements.viewer(),
        ),
      );
      expect(
        viewer.checks.where(
          (check) =>
              check.type == MediaPreJoinCheckType.microphoneDevice ||
              check.type == MediaPreJoinCheckType.cameraDevice,
        ),
        isEmpty,
      );
    },
  );

  test(
    'IVS iOS advertises virtual background support and attaches processed source',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const ivsChannel = MethodChannel(
        'com.oneplusdream.flutter_realtime_media_ivs/methods',
      );
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(ivsChannel, (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(ivsChannel, null));
      final info = IvsJoinInfo.fromJson(_joinJson());
      final session =
          IvsSessionFactory(
                engineFactory: () async => _FakeIvsEngine(),
              ).createSession(info)
              as InteractiveMediaSession;
      addTearDown(session.dispose);
      await session.join(info);
      expect(session.capabilities.canBlurBackground, isTrue);
      expect(session.capabilities.canReplaceBackgroundImage, isTrue);
      const source = ProcessedVideoSource(
        id: 'ivs-ios-effects',
        kind: ProcessedVideoSourceKind.nativeFrameHub,
        platform: ProcessedVideoPlatform.ios,
        width: 1280,
        height: 720,
        frameRate: 24,
      );
      final sink = session as ProcessedVideoSink;
      expect(sink.supportsProcessedVideoSource(source), isTrue);
      await sink.attachProcessedVideoSource(source);
      expect(calls, contains('attachProcessedVideoSource'));
    },
  );

  test(
    'IVS Android screen capture attaches MediaProjection source and restores camera',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const capture = MethodChannel(
        'flutter_realtime_processed_video/android_system_screen_capture',
      );
      const ivsChannel = MethodChannel(
        'com.oneplusdream.flutter_realtime_media_ivs/methods',
      );
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(capture, (call) async {
        calls.add(call.method);
        if (call.method == 'androidScreenCaptureAvailable') return true;
        if (call.method == 'androidScreenCaptureStart') {
          return {
            'id': 'ivs-android-screen',
            'kind': 'nativeFrameHub',
            'platform': 'android',
            'width': 720,
            'height': 1280,
            'frameRate': 15.0,
          };
        }
        return null;
      });
      messenger.setMockMethodCallHandler(ivsChannel, (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(capture, null);
        messenger.setMockMethodCallHandler(ivsChannel, null);
      });
      final info = IvsJoinInfo.fromJson(_joinJson());
      final session =
          IvsSessionFactory(
                engineFactory: () async => _FakeIvsEngine(),
              ).createSession(info)
              as InteractiveMediaSession;
      await session.join(info);
      expect(session.capabilities.canScreenShare, isTrue);
      await session.setScreenShareEnabled(true);
      expect(session.snapshot.localScreenShareEnabled, isTrue);
      expect(calls, contains('attachAndroidScreenCaptureSource'));
      await session.setScreenShareEnabled(false);
      expect(session.snapshot.localScreenShareEnabled, isFalse);
      expect(calls, contains('detachAndroidScreenCaptureSource'));
      await session.dispose();
    },
  );

  test(
    'viewer promotes cleanly to co-host and demotes back without rejoining',
    () async {
      final engine = _FakeIvsEngine();
      final factory = IvsSessionFactory(engineFactory: () async => engine);
      final viewerInfo = IvsJoinInfo.fromJson(
        _joinJson(role: MediaRole.viewer),
      );
      final viewerSession =
          factory.createSession(viewerInfo) as BroadcastViewerSession;
      (viewerSession as MediaRoleSwitchable).setRoleChangeCallback((target) {
        return Future.value(
          IvsJoinInfo.fromJson(
            _joinJson(
              role: target,
              token: target == MediaRole.participant
                  ? 'cohost-tok'
                  : 'viewer-tok',
            ),
          ),
        );
      });
      await viewerSession.join(viewerInfo);

      final promoted = await (viewerSession as MediaRoleSwitchable).switchRole(
        MediaRole.participant,
      );
      expect(promoted, isA<InteractiveMediaSession>());
      expect(promoted.role, MediaRole.participant);
      expect(promoted.capabilities.canPublishAudio, isTrue);
      expect(engine.exchangedToken, 'cohost-tok');
      expect(engine.exchangedRole, MediaRole.participant);

      // Events from the original engine forward to the adopted session.
      engine.events.onRemoteScreenShareChanged?.call(
        'host-1',
        'host-1#content',
        true,
      );
      final contentTrack = promoted.snapshot.contentShareTrack;
      expect(contentTrack, isNotNull);
      expect(contentTrack!.isScreenShare, isTrue);
      expect(
        (contentTrack as MediaContentOwnerTrack).contentOwnerParticipantId,
        'host-1',
      );

      final demoted = await (promoted as MediaRoleSwitchable).switchRole(
        MediaRole.viewer,
      );
      expect(demoted, isA<BroadcastViewerSession>());
      expect(demoted.role, MediaRole.viewer);
      expect(demoted.capabilities.canPublishAudio, isFalse);

      // Disposing the adopted-out previous sessions never leaves the Stage.
      await viewerSession.dispose();
      await promoted.dispose();
      expect(engine.calls, isNot(contains('leave')));
      await demoted.dispose();
      expect(engine.calls, contains('leave'));
    },
  );

  test(
    'IVS enumerates and selects audio output devices on all platforms',
    () async {
      final engine = _FakeIvsEngine();
      final factory = IvsSessionFactory(engineFactory: () async => engine);
      final info = IvsJoinInfo.fromJson(_joinJson(role: MediaRole.participant));
      final session = factory.createSession(info) as InteractiveMediaSession;
      await session.join(info);
      expect(session.capabilities.canEnumerateAudioDevices, isTrue);
      expect(session.capabilities.canSelectAudioOutput, isTrue);
      final devices = await session.listAudioDevices();
      expect(devices.map((d) => d.id), ['speaker', 'bt-1']);
      await session.selectAudioDevice(devices.last);
      expect(engine.selectedAudioDevice?.id, 'bt-1');
      await session.dispose();
    },
  );

  test(
    'Windows IVS enumerates screen sources, publishes screen share, maps remote #content, and cleans up on window close',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      addTearDown(AwsWindowsWebView2Runtime.debugResetWindowsChannelHandler);

      const windowsChannel = MethodChannel(
        'com.oneplusdream.flutter_realtime_media_aws_desktop/windows',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final nativeCalls = <MethodCall>[];
      final webCalls = <Map<String, dynamic>>[];

      late final AwsWindowsWebView2Runtime runtime;
      runtime = AwsWindowsWebView2Runtime.forTesting(
        'ivs',
        probeOverride: () async => true,
        postWebMessageOverride: (encoded) async {
          final decoded = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
          webCalls.add(decoded);
          if (decoded['id'] != null) {
            runtime.debugHandleWebMessage({
              'channel': 'aws-windows-ivs-v1',
              'kind': 'result',
              'id': decoded['id'],
              'success': true,
              'value': true,
            });
          }
        },
      );
      addTearDown(runtime.dispose);

      messenger.setMockMethodCallHandler(windowsChannel, (call) async {
        nativeCalls.add(call);
        if (call.method == 'probeProcessedVideoInput') return true;
        if (call.method == 'listScreenShareSources') {
          return [
            {'id': 'display:1', 'name': 'Primary Monitor', 'kind': 'display'},
            {'id': 'window:0x2048', 'name': 'Slides Deck', 'kind': 'window'},
          ];
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(windowsChannel, null),
      );

      final engine = WindowsIvsWebView2Engine(runtime: runtime);
      final factory = IvsSessionFactory(engineFactory: () async => engine);
      final info = IvsJoinInfo.fromJson(_joinJson(role: MediaRole.participant));
      final session = factory.createSession(info) as IvsParticipantSession;
      final emittedEvents = <MediaEvent>[];
      final sub = session.events.listen(emittedEvents.add);
      addTearDown(sub.cancel);

      await session.join(info);
      expect(session.capabilities.canScreenShare, isTrue);

      final sources = await session.listScreenShareSources();
      expect(sources.map((s) => s.id), ['display:1', 'window:0x2048']);
      expect(sources.last.kind, MediaScreenShareSourceKind.window);
      await session.selectScreenShareSource(sources.last);

      await session.setScreenShareEnabled(true);
      expect(session.snapshot.localScreenShareEnabled, isTrue);
      expect(session.snapshot.contentShareTrack?.isLocal, isTrue);
      expect(session.snapshot.contentShareTrack?.isScreenShare, isTrue);

      final startCall = nativeCalls.singleWhere(
        (c) => c.method == 'startScreenCapture',
      );
      expect((startCall.arguments as Map)['targetId'], 'window:0x2048');
      final sourceId = (startCall.arguments as Map)['sourceId'] as String;
      expect(
        webCalls.any(
          (m) =>
              m['operation'] == 'startScreenCaptureSource' &&
              (m['payload'] as Map?)?['sourceId'] == sourceId,
        ),
        isTrue,
      );

      // Simulate native window closing unexpectedly during active screen share.
      await messenger.handlePlatformMessage(
        windowsChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('onScreenCaptureStopped', {
            'sourceId': sourceId,
            'reason': 'windowClosed',
          }),
        ),
        (_) {},
      );
      await pumpEventQueue();
      expect(session.snapshot.localScreenShareEnabled, isFalse);
      expect(session.snapshot.contentShareTrack, isNull);
      expect(
        emittedEvents.whereType<MediaTrackUnpublished>().any(
          (e) => e.wasScreenShare,
        ),
        isTrue,
      );

      // Simulate remote participant screen share via auxiliary #content Stage.
      runtime.debugHandleWebMessage({
        'channel': 'aws-windows-ivs-v1',
        'kind': 'event',
        'sessionId': 'aws-desktop-ivs',
        'event': {
          'type': 'snapshot',
          'participants': [
            {
              'id': 'host-2',
              'displayName': 'Host Two',
              'isLocal': false,
              'isMuted': false,
            },
          ],
          'tracks': [
            {
              'id': 'ivs:track:scr-2',
              'participantId': 'host-2#content',
              'isLocal': false,
              'isScreenShare': true,
            },
          ],
          'contentShareTrack': {
            'id': 'ivs:track:scr-2',
            'participantId': 'host-2#content',
            'isLocal': false,
            'isScreenShare': true,
          },
        },
      });
      await pumpEventQueue();
      final remoteScreen = session.snapshot.contentShareTrack;
      expect(remoteScreen, isNotNull);
      expect(remoteScreen!.isLocal, isFalse);
      expect(remoteScreen.participantId, 'host-2#content');
      expect(
        (remoteScreen as MediaContentOwnerTrack).contentOwnerParticipantId,
        'host-2',
      );

      await session.dispose();
    },
  );
}

class _FaultIvsEngine extends _FakeIvsEngine {
  @override
  Future<void> join(IvsJoinInfo info, IvsEngineEvents events) async {
    throw const RealtimeException(
      code: RealtimeErrorCode.invalidCredential,
      message: 'native secret',
    );
  }

  @override
  Future<void> leave() async {
    throw StateError('failed leave');
  }
}
