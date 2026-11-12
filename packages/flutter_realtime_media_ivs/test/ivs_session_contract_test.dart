import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_media_ivs/flutter_realtime_media_ivs.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeIvsEngine implements IvsEngine {
  Future<void>? pendingJoin;
  IvsEngineEvents events = const IvsEngineEvents();
  final List<String> calls = [];
  IvsJoinInfo? joinedInfo;
  String? exchangedToken;

  @override
  Future<void> join(IvsJoinInfo info, IvsEngineEvents events) async {
    joinedInfo = info;
    this.events = events;
    calls.add('join');
    if (pendingJoin != null) await pendingJoin;
  }

  @override
  Future<void> exchangeToken(String token) async {
    exchangedToken = token;
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
    'Windows IVS Stage rejects missing native bridge before joining',
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
      expect(await probeNativeIvsAvailability(), isTrue);
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
