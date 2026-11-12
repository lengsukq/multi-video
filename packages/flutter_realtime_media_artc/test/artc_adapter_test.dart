import 'dart:async';
import 'package:flutter/services.dart';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_realtime_media_artc/flutter_realtime_media_artc.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_test/flutter_test.dart';

ArtcJoinInfo joinInfo({MediaRole role = MediaRole.participant}) => ArtcJoinInfo(
  roomCode: '482913',
  participantId: 'u-person1',
  role: role,
  displayName: 'Person 1',
  appId: 'demo-app',
  channelId: 'media-482913',
  userId: 'u-person1',
  authInfo: 'short-lived-base64-auth-info',
  expiresAtMs: DateTime.now().millisecondsSinceEpoch + 600000,
);

Map<String, Object?> response({MediaRole role = MediaRole.participant}) => {
  'provider': 'artc',
  'roomCode': '482913',
  'participantId': 'u-person1',
  'role': role.wireName,
  'displayName': 'Person 1',
  'artc': {
    'appId': 'demo-app',
    'channelId': 'media-482913',
    'userId': 'u-person1',
    'authInfo': 'short-lived-base64-auth-info',
    'expiresAtMs': DateTime.now().millisecondsSinceEpoch + 600000,
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Windows ARTC exposes native screen share, not unimplemented camera switching', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final engine = _FakeArtcEngine();
    final session = ArtcSessionFactory(engineFactory: () async => engine)
        .createSession(joinInfo());
    addTearDown(session.dispose);
    await session.join(joinInfo());
    expect(session.capabilities.canScreenShare, isTrue);
    expect(session.capabilities.canSwitchCamera, isFalse);
    final interactive = session as InteractiveMediaSession;
    await interactive.setScreenShareEnabled(true);
    expect(engine.calls, contains('screen:true'));
    expect(session.snapshot.localScreenShareEnabled, isTrue);
    await expectLater(
      interactive.switchCamera(MediaCameraPosition.back),
      throwsA(isA<RealtimeException>().having(
        (error) => error.code,
        'error code',
        RealtimeErrorCode.unsupportedFeature,
      )),
    );
    expect(engine.calls, isNot(contains('camera:back')));
    await interactive.setScreenShareEnabled(false);
    expect(engine.calls, contains('screen:false'));
    expect(session.snapshot.localScreenShareEnabled, isFalse);
  });
  test('Windows ARTC pre-join blocks without a real native bridge', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final factory = ArtcSessionFactory(
      availabilityProbe: () async => false,
    );
    final result = await factory.runPreJoinProbe(
      const MediaPreJoinProbeRequest(
        providerId: 'artc',
        role: MediaRole.participant,
        requirements: MediaPreJoinRequirements(),
      ),
    );
    final provider = result.checks.singleWhere(
      (check) => check.type == MediaPreJoinCheckType.provider,
    );
    expect(provider.isBlocking, isTrue);
    expect(provider.status, MediaPreJoinStatus.unsupported);
    expect(provider.message, contains('Windows native engine'));
  });

  test('Windows ARTC probe rejects missing plugin and accepts ready bridge', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const methods = MethodChannel(
      'com.oneplusdream.flutter_realtime_media_artc/methods',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(methods, null));
    expect(await probeNativeArtcAvailability(), isFalse);
    await expectLater(
      createNativeArtcEngine(),
      throwsA(isA<RealtimeException>().having(
        (error) => error.code,
        'code',
        RealtimeErrorCode.unsupportedPlatform,
      )),
    );
    messenger.setMockMethodCallHandler(methods, (call) async {
      expect(call.method, 'isAvailable');
      return true;
    });
    expect(await probeNativeArtcAvailability(), isTrue);
  });
  for (final disposing in [false, true]) {
    test(
      'late ARTC refresh preserves the next active owner after $disposing',
      () async {
        final engine = _FakeArtcEngine();
        final factory = ArtcSessionFactory(engineFactory: () async => engine);
        final initial = joinInfo();
        final session = factory.createSession(initial);
        addTearDown(session.dispose);
        await session.join(initial);
        final pending = Completer<MediaJoinInfo>();
        final started = Completer<void>();
        (session as MediaCredentialRefreshable).setCredentialRefreshCallback((
          current,
        ) {
          started.complete();
          return pending.future;
        });
        engine.events!.onAuthWillExpire!();
        await started.future;
        if (disposing) {
          await session.dispose();
        } else {
          await session.leave();
        }
        final oldJoins = engine.joined.length;
        final calls = List<String>.of(engine.calls);
        final nextFactory = ArtcSessionFactory(
          engineFactory: () async => _FakeArtcEngine(),
        );
        final nextInfo = joinInfo();
        final next = nextFactory.createSession(nextInfo);
        addTearDown(next.dispose);
        await next.join(nextInfo);
        engine.events!.onParticipantJoined!('stale');
        pending.complete(joinInfo());
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(engine.joined.length, oldJoins);
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

  test(
    'ARTC rollback preserves join error and attempts disposal after leave fails',
    () async {
      final engine = _FaultArtcEngine();
      final session = ArtcSessionFactory(
        engineFactory: () async => engine,
      ).createSession(joinInfo());
      await expectLater(
        session.join(joinInfo()),
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
      expect(engine.disposed, isTrue);
      final next = ArtcSessionFactory(
        engineFactory: () async => _FakeArtcEngine(),
      ).createSession(joinInfo());
      await next.join(joinInfo());
      await next.dispose();
      await session.dispose();
    },
  );

  test('ARTC late join remains cancelled after leaving pending room', () async {
    final pending = Completer<void>();
    final engine = _FakeArtcEngine()..pendingJoin = pending.future;
    final session = ArtcSessionFactory(
      engineFactory: () async => engine,
    ).createSession(joinInfo());
    final joining = session.join(joinInfo());
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
    expect(engine.disposed, isTrue);
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
          'com.oneplusdream.flutter_realtime_media_artc/methods',
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
      final engine = _FakeArtcEngine();
      final session = ArtcSessionFactory(
        engineFactory: () async => engine,
      ).createSession(joinInfo());
      await session.join(joinInfo());
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

  test(
    'ARTC Android screen capture is an SDK capability, not Demo logic',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final engine = _FakeArtcEngine();
      final session = ArtcSessionFactory(
        engineFactory: () async => engine,
      ).createSession(joinInfo());
      await session.join(joinInfo());
      expect(session.capabilities.canScreenShare, isTrue);
      final publisher = session as InteractiveMediaSession;
      await publisher.setScreenShareEnabled(true);
      await publisher.setScreenShareEnabled(true);
      expect(engine.calls.where((s) => s == 'screen:true'), hasLength(1));
      expect(session.snapshot.localScreenShareEnabled, isTrue);
      expect(session.snapshot.contentShareTrack?.isScreenShare, isTrue);
      // Losing capture permission must update the SDK without a Demo command.
      engine.events!.onLocalScreenShareChanged?.call(false);
      expect(session.snapshot.localScreenShareEnabled, isFalse);
      expect(session.snapshot.contentShareTrack, isNull);
      await publisher.setScreenShareEnabled(true);
      await publisher.setScreenShareEnabled(false);
      expect(engine.calls.where((s) => s == 'screen:false'), hasLength(1));
      expect(session.snapshot.localScreenShareEnabled, isFalse);
      expect(session.snapshot.contentShareTrack, isNull);
      await session.dispose();
    },
  );

  test(
    'ARTC remote screen and camera tracks stay independently renderable',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final engine = _FakeArtcEngine();
      final session = ArtcSessionFactory(
        engineFactory: () async => engine,
      ).createSession(joinInfo());
      await session.join(joinInfo());
      engine.events!.onParticipantJoined?.call('teacher');
      engine.events!.onRemoteVideoChanged?.call('teacher', true);
      engine.events!.onRemoteScreenChanged?.call('teacher', true);
      final camera = session.snapshot.remoteParticipants.single.videoTrack!;
      final shared = session.snapshot.contentShareTrack!;
      expect(camera.isScreenShare, isFalse);
      expect(shared.isScreenShare, isTrue);
      expect(camera.id, isNot(shared.id));
      engine.events!.onRemoteVideoChanged?.call('teacher', false);
      expect(session.snapshot.contentShareTrack?.id, shared.id);
      engine.events!.onRemoteScreenChanged?.call('teacher', false);
      expect(session.snapshot.contentShareTrack, isNull);
      engine.events!.onRemoteScreenChanged?.call('teacher', true);
      engine.events!.onParticipantLeft?.call('teacher');
      expect(session.snapshot.contentShareTrack, isNull);
      await session.dispose();
    },
  );

  test(
    'ARTC iOS advertises iOS 27 ScreenCaptureKit but gates older runtimes',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final session = ArtcSessionFactory(
        engineFactory: () async => _FakeArtcEngine(),
      ).createSession(joinInfo());
      await session.join(joinInfo());
      expect(session.capabilities.canScreenShare, isTrue);
      await expectLater(
        (session as InteractiveMediaSession).setScreenShareEnabled(true),
        throwsA(
          isA<RealtimeException>().having(
            (e) => e.code,
            'code',
            RealtimeErrorCode.unsupportedFeature,
          ),
        ),
      );
      await session.dispose();
    },
  );

  test(
    'macOS Pre-Join blocks when the optional ARTC framework is absent',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final factory = ArtcSessionFactory(
        engineFactory: () async => _FakeArtcEngine(),
        availabilityProbe: () async => false,
      );

      final result = await factory.runPreJoinProbe(
        const MediaPreJoinProbeRequest(
          providerId: 'artc',
          role: MediaRole.participant,
          requirements: MediaPreJoinRequirements(),
        ),
      );

      expect(
        result.checks.any(
          (check) =>
              check.type == MediaPreJoinCheckType.provider &&
              check.status == MediaPreJoinStatus.unsupported &&
              check.severity == MediaPreJoinSeverity.blocking,
        ),
        isTrue,
      );
    },
  );

  test('parses provider credentials and maps roles to room modes', () {
    final factory = ArtcSessionFactory(
      engineFactory: () async => _FakeArtcEngine(),
    );
    final participant = factory.parseJoinInfo(response());
    final broadcast = ArtcJoinInfo.fromJson(response(role: MediaRole.host));

    expect(factory.providerId, 'artc');
    expect(factory.supportedRoles, containsAll(MediaRole.values));
    expect(participant.roomMode, ArtcRoomMode.communication);
    expect(broadcast.roomMode, ArtcRoomMode.interactiveLive);
  });

  test('rejects malformed or mismatched ARTC join information', () {
    final invalidProvider = response()..['provider'] = 'trtc';
    expect(
      () => ArtcJoinInfo.fromJson(invalidProvider),
      throwsA(
        isA<RealtimeException>().having(
          (error) => error.code,
          'code',
          RealtimeErrorCode.invalidArgument,
        ),
      ),
    );
    final wrongUser = response();
    (wrongUser['artc'] as Map<String, Object?>)['userId'] = 'different-user';
    expect(
      () => ArtcJoinInfo.fromJson(wrongUser),
      throwsA(
        isA<RealtimeException>().having(
          (error) => error.code,
          'code',
          RealtimeErrorCode.invalidArgument,
        ),
      ),
    );
    final noExpiry = response();
    (noExpiry['artc'] as Map<String, Object?>).remove('expiresAtMs');
    expect(
      () => ArtcJoinInfo.fromJson(noExpiry),
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
    'joins, controls media, maps participants, tracks, messages, and leaves',
    () async {
      final engine = _FakeArtcEngine();
      final session = ArtcSessionFactory(
        engineFactory: () async => engine,
      ).createSession(joinInfo());
      final events = <MediaEvent>[];
      final subscription = session.events.listen(events.add);

      await session.join(joinInfo());
      expect(session.state, MediaSessionState.connected);
      expect(engine.joined.single.userId, 'u-person1');
      expect(engine.joined.single.roomMode, ArtcRoomMode.communication);
      expect(session.snapshot.localParticipantId, 'u-person1');
      expect(
        session.capabilities.canScreenShare,
        defaultTargetPlatform == TargetPlatform.android,
      );
      expect(session.capabilities.canEnumerateAudioDevices, isFalse);
      final interactive = session as InteractiveMediaSession;
      await expectLater(
        interactive.sendMessage('too early'),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.invalidState,
          ),
        ),
      );

      await interactive.setMuted(false);
      await interactive.setVideoEnabled(true);
      await interactive.switchCamera(MediaCameraPosition.back);
      expect(session.snapshot.localMuted, isFalse);
      expect(session.snapshot.localVideoEnabled, isTrue);
      expect(
        engine.calls,
        containsAll(['mute:false', 'video:true', 'camera:back']),
      );
      expect(events.whereType<MediaTrackPublished>(), hasLength(1));
      if (defaultTargetPlatform == TargetPlatform.android) {
        await interactive.setScreenShareEnabled(true);
        expect(session.snapshot.localScreenShareEnabled, isTrue);
        await interactive.setScreenShareEnabled(false);
      } else {
        await expectLater(
          interactive.setScreenShareEnabled(true),
          throwsA(
            isA<RealtimeException>().having(
              (error) => error.code,
              'code',
              RealtimeErrorCode.unsupportedFeature,
            ),
          ),
        );
      }

      engine.events!.onParticipantJoined?.call('u-remote');
      engine.events!.onRemoteVideoChanged?.call('u-remote', true);
      engine.events!.onRemoteAudioChanged?.call('u-remote', false);
      await Future<void>.delayed(Duration.zero);
      final remote = session.snapshot.remoteParticipants.single;
      expect(remote.videoTrack, isA<ArtcMediaVideoTrack>());
      expect(remote.isMuted, isTrue);
      expect(events.whereType<MediaParticipantJoined>(), hasLength(1));

      engine.events!.onMessage?.call(
        'u-remote',
        jsonEncode({'topic': 'chat', 'message': 'hello'}),
      );
      await interactive.sendMessage('ack', topic: 'chat');
      expect(session.snapshot.messages.map((message) => message.message), [
        'hello',
        'ack',
      ]);
      expect(session.snapshot.messages.first.providerId, 'artc');
      expect(engine.calls, contains('message:ack:chat'));
      expect(events.whereType<MediaMessageReceived>(), hasLength(1));

      engine.events!.onParticipantLeft?.call('u-remote');
      expect(session.snapshot.remoteParticipants, isEmpty);
      engine.events!.onReconnecting?.call();
      expect(session.state, MediaSessionState.reconnecting);
      engine.events!.onRecovered?.call();
      expect(session.state, MediaSessionState.connected);

      await session.leave();
      expect(session.state, MediaSessionState.ended);
      expect(engine.leaveCount, 1);
      await subscription.cancel();
      await session.dispose();
      expect(session.state, MediaSessionState.disposed);
      expect(engine.disposed, isTrue);
    },
  );

  test(
    'host advertises backend room management but not native removal',
    () async {
      final session = ArtcSessionFactory(
        engineFactory: () async => _FakeArtcEngine(),
      ).createSession(joinInfo(role: MediaRole.host));
      await session.join(joinInfo(role: MediaRole.host));

      expect(session.capabilities.canListParticipants, isTrue);
      expect(session.capabilities.canCloseRoom, isTrue);
      expect(session.capabilities.canRemoveParticipants, isFalse);
      expect(session.capabilities.maxDataMessageBytes, 1024);
      await session.dispose();
    },
  );

  test(
    'viewer surface is subscribe-only and receives but cannot send data',
    () async {
      final engine = _FakeArtcEngine();
      final session = ArtcSessionFactory(
        engineFactory: () async => engine,
      ).createSession(joinInfo(role: MediaRole.viewer));
      await session.join(joinInfo(role: MediaRole.viewer));

      expect(session, isA<BroadcastViewerSession>());
      expect(session, isNot(isA<InteractiveMediaSession>()));
      expect(session.capabilities.canPublishAudio, isFalse);
      expect(session.capabilities.canPublishVideo, isFalse);
      expect(session.capabilities.canSendData, isFalse);
      expect(session.capabilities.canReceiveData, isTrue);
      await expectLater(
        (session as BroadcastViewerSession).sendMessage('not allowed'),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.unsupportedFeature,
          ),
        ),
      );
      engine.events!.onMessage?.call(
        'u-host',
        jsonEncode({'topic': 'chat', 'message': 'welcome'}),
      );
      expect(session.snapshot.messages.single.message, 'welcome');
      await session.dispose();
    },
  );

  test(
    'refresh rejoins same channel and identity; changed identity is rejected',
    () async {
      final engine = _FakeArtcEngine();
      final session = ArtcSessionFactory(
        engineFactory: () async => engine,
      ).createSession(joinInfo());
      var refreshCalls = 0;
      (session as MediaCredentialRefreshable).setCredentialRefreshCallback((
        current,
      ) async {
        refreshCalls++;
        final original = current as ArtcJoinInfo;
        return ArtcJoinInfo(
          roomCode: original.roomCode,
          participantId: original.participantId,
          role: original.role,
          displayName: original.displayName,
          appId: original.appId,
          channelId: original.channelId,
          userId: original.userId,
          authInfo: 'renewed-auth-info',
          expiresAtMs: DateTime.now().millisecondsSinceEpoch + 600000,
        );
      });
      await session.join(joinInfo());
      engine.events!.onAuthWillExpire?.call();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(refreshCalls, 1);
      expect(engine.joined, hasLength(2));
      expect(engine.joined.last.authInfo, 'renewed-auth-info');
      expect(session.state, MediaSessionState.connected);
      await session.dispose();

      final changedEngine = _FakeArtcEngine();
      final changedSession = ArtcSessionFactory(
        engineFactory: () async => changedEngine,
      ).createSession(joinInfo());
      (changedSession as MediaCredentialRefreshable)
          .setCredentialRefreshCallback((current) async {
            final original = current as ArtcJoinInfo;
            return ArtcJoinInfo(
              roomCode: original.roomCode,
              participantId: original.participantId,
              role: original.role,
              displayName: original.displayName,
              appId: original.appId,
              channelId: 'other-channel',
              userId: original.userId,
              authInfo: 'wrong-room-auth',
              expiresAtMs: DateTime.now().millisecondsSinceEpoch + 600000,
            );
          });
      await changedSession.join(joinInfo());
      changedEngine.events!.onAuthWillExpire?.call();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(changedSession.state, MediaSessionState.failed);
      expect(changedEngine.joined, hasLength(1));
      await changedSession.dispose();
    },
  );

  test('only one ARTC engine session can be active at a time', () async {
    final engine = _FakeArtcEngine();
    final factory = ArtcSessionFactory(engineFactory: () async => engine);
    final first = factory.createSession(joinInfo());
    final second = factory.createSession(joinInfo());
    await first.join(joinInfo());
    await expectLater(
      second.join(joinInfo()),
      throwsA(
        isA<RealtimeException>().having(
          (error) => error.code,
          'code',
          RealtimeErrorCode.invalidState,
        ),
      ),
    );
    await first.dispose();
    await second.dispose();
  });
}

class _FakeArtcEngine implements ArtcEngine {
  Future<void>? pendingJoin;
  final List<ArtcJoinInfo> joined = [];
  final List<String> calls = [];
  ArtcEngineEvents? events;
  int leaveCount = 0;
  bool disposed = false;

  @override
  Future<void> join(ArtcJoinInfo info, ArtcEngineEvents events) async {
    joined.add(info);
    this.events = events;
    if (pendingJoin != null) await pendingJoin;
  }

  @override
  Future<void> leave() async {
    leaveCount++;
  }

  @override
  Future<void> setMuted(bool muted) async => calls.add('mute:$muted');

  @override
  Future<void> setVideoEnabled(bool enabled) async =>
      calls.add('video:$enabled');

  @override
  Future<void> setScreenShareEnabled(bool enabled) async =>
      calls.add('screen:$enabled');

  @override
  Future<void> switchCamera(MediaCameraPosition position) async =>
      calls.add('camera:${position.name}');

  @override
  Future<void> sendMessage(String message, String topic) async =>
      calls.add('message:$message:$topic');

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _FaultArtcEngine extends _FakeArtcEngine {
  @override
  Future<void> join(ArtcJoinInfo info, ArtcEngineEvents events) async {
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
