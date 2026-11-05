import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:async';

import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_media_trtc/flutter_realtime_media_trtc.dart';
import 'package:flutter_realtime_media_trtc/src/trtc_engine.dart';
import 'package:flutter_test/flutter_test.dart';

TrtcJoinInfo joinInfo({MediaRole role = MediaRole.participant}) => TrtcJoinInfo(
  roomCode: '482913',
  participantId: 'u-person1',
  role: role,
  displayName: 'Person 1',
  sdkAppId: 1400000000,
  strRoomId: 'media-482913',
  userId: 'u-person1',
  userSig: 'short-lived-user-sig',
  privateMapKey: 'room-scoped-private-map-key',
  expiresAtMs: DateTime.now().millisecondsSinceEpoch + 600000,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final disposing in [false, true]) {
    test(
      'late TRTC refresh preserves the next active owner after $disposing',
      () async {
        final engine = _FakeTrtcEngine();
        final factory = TrtcSessionFactory(engineFactory: () async => engine);
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
        engine.lastEvents!.onError!(-100018, 'usersig expired');
        await started.future;
        if (disposing) {
          await session.dispose();
        } else {
          await session.leave();
        }
        final oldJoins = engine.enteredRooms.length;
        final calls = List<String>.of(engine.calls);
        final nextFactory = TrtcSessionFactory(
          engineFactory: () async => _FakeTrtcEngine(),
        );
        final nextInfo = joinInfo();
        final next = nextFactory.createSession(nextInfo);
        addTearDown(next.dispose);
        await next.join(nextInfo);
        engine.lastEvents!.onRemoteUserEnterRoom!('stale');
        pending.complete(joinInfo());
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(engine.enteredRooms.length, oldJoins);
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
    'TRTC preserves typed provider failures without native public text',
    () async {
      final engine = _ThrowingTrtcEngine();
      final session = TrtcSessionFactory(
        engineFactory: () async => engine,
      ).createSession(joinInfo());
      addTearDown(session.dispose);
      await expectLater(
        session.join(joinInfo()),
        throwsA(
          isA<RealtimeException>()
              .having(
                (error) => error.code,
                'code',
                RealtimeErrorCode.permissionDenied,
              )
              .having(
                (error) => error.message,
                'safe stage',
                isNot(contains('native secret')),
              )
              .having((error) => error.cause, 'original cause', isNotNull),
        ),
      );
    },
  );

  test('TRTC microphone captures only after explicit unmute', () async {
    final engine = _FakeTrtcEngine();
    final session = TrtcSessionFactory(
      engineFactory: () async => engine,
    ).createSession(joinInfo());
    addTearDown(session.dispose);
    await session.join(joinInfo());
    final publishing = session as InteractiveMediaSession;
    expect(session.snapshot.localMuted, isTrue);
    expect(engine.calls, isNot(contains('audio:start')));
    await publishing.setMuted(true);
    expect(engine.calls, isNot(contains('audio:start')));
    await publishing.setMuted(false);
    expect(engine.calls, contains('audio:start'));
    expect(engine.calls, contains('audio:mute:false'));
    await publishing.setMuted(true);
    await publishing.setMuted(false);
    expect(engine.calls.where((call) => call == 'audio:start'), hasLength(1));
    await session.leave();
  });

  test(
    'leave cancels a pending TRTC enter without reviving the room',
    () async {
      final pending = Completer<int>();
      final engine = _FakeTrtcEngine()..pendingEnter = pending.future;
      final session = TrtcSessionFactory(
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
      // Let the async factory resolve before leaving the pending SDK enter.
      await Future<void>.delayed(Duration.zero);
      await session.leave().timeout(const Duration(seconds: 2));
      expect(session.state, MediaSessionState.ended);
      expect(engine.disposed, isTrue);

      pending.complete(1);
      await cancelled;
      expect(session.state, MediaSessionState.ended);
      await session.dispose();
    },
  );

  test(
    'processed source owns camera control and detaches before leave',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final commands = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final channels = {
        const MethodChannel('flutter_realtime_processed_video/sources'),
        const MethodChannel('flutter_realtime_media_trtc/processed_video'),
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
      final engine = _FakeTrtcEngine();
      final session = TrtcSessionFactory(
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
      expect(engine.calls, isNot(contains('camera:false')));
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
        (commands.firstWhere((c) => c.method == 'attachProvider').arguments
            as Map)['sourceId'],
        source.id,
      );
      await session.leave();
      expect(commands.where((c) => c.method == 'detachProvider'), hasLength(1));
      await session.dispose();
      expect(commands.where((c) => c.method == 'detachProvider'), hasLength(1));
    },
  );

  test(
    'joins, publishes controls, maps events, renders tracks, and leaves',
    () async {
      final engine = _FakeTrtcEngine();
      final session = TrtcSessionFactory(
        engineFactory: () async => engine,
      ).createSession(joinInfo());
      final events = <MediaEvent>[];
      final subscription = session.events.listen(events.add);
      final stats = <MediaConnectionStats>[];
      final statsSubscription = session.stats.listen(stats.add);

      await session.join(joinInfo());
      expect(session.state, MediaSessionState.connected);
      expect(session.snapshot.localParticipantId, 'u-person1');
      expect(engine.enteredRooms, hasLength(1));
      expect(
        engine.calls,
        isNot(contains('audio:start')),
        reason: 'TRTC must not capture audio while joining muted',
      );

      final interactive = session as InteractiveMediaSession;
      await interactive.setMuted(false);
      await interactive.setVideoEnabled(true);
      await interactive.switchCamera(MediaCameraPosition.back);
      expect(session.snapshot.localMuted, isFalse);
      expect(session.snapshot.localVideoEnabled, isTrue);
      expect(
        engine.calls,
        containsAll([
          'audio:start',
          'audio:mute:false',
          'video:mute:false',
          'camera:false',
        ]),
      );
      expect(events.whereType<MediaTrackPublished>(), hasLength(1));
      await interactive.setScreenShareEnabled(true);
      expect(session.snapshot.localScreenShareEnabled, isTrue);
      expect(engine.calls, contains('screen:start'));
      await expectLater(
        interactive.sendMessage(List.filled(1000, 'x').join()),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.invalidArgument,
          ),
        ),
      );

      final engineEvents = engine.lastEvents!;
      engineEvents.onStats?.call(
        const MediaConnectionStats(
          timestampMs: 1,
          upstreamQuality: MediaNetworkQuality.good,
          downstreamQuality: MediaNetworkQuality.fair,
          rttMs: 55,
          uplinkPacketLossPercent: 1,
          downlinkPacketLossPercent: 2,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(session.connectionStats?.rttMs, 55);
      expect(stats.single.downstreamQuality, MediaNetworkQuality.fair);
      expect(events.whereType<MediaNetworkStatsUpdated>(), hasLength(1));

      engineEvents.onRemoteUserEnterRoom?.call('u-remote');
      engineEvents.onUserVideoAvailable?.call('u-remote', true);
      engineEvents.onUserAudioAvailable?.call('u-remote', true);
      final remote = session.snapshot.remoteParticipants.single;
      expect(remote.id, 'u-remote');
      expect(remote.isVideoEnabled, isTrue);
      expect(remote.isMuted, isFalse);
      expect(remote.videoTrack, isA<TrtcMediaVideoTrack>());

      // Tencent's onUserVoiceVolume uses an empty userId for local input.
      // Speaking must reflect real volume callbacks, not the mute button.
      engineEvents.onAudioLevels?.call({'': 48, 'u-remote': 55});
      expect(
        session.snapshot.participants.firstWhere((p) => p.isLocal).isSpeaking,
        isTrue,
      );
      expect(session.snapshot.remoteParticipants.single.isSpeaking, isTrue);
      engineEvents.onAudioLevels?.call({'': 0, 'u-remote': 0});
      expect(
        session.snapshot.participants.firstWhere((p) => p.isLocal).isSpeaking,
        isFalse,
      );
      expect(session.snapshot.remoteParticipants.single.isSpeaking, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<MediaSpeakingChanged>(), hasLength(4));

      final remoteTrack = remote.videoTrack! as TrtcMediaVideoTrack;
      remoteTrack.startRendering(77);
      remoteTrack.stopRendering();
      expect(
        engine.calls,
        containsAll(['remote:start:u-remote:77', 'remote:stop:u-remote']),
      );

      engineEvents.onUserSubStreamAvailable?.call('u-remote', true);
      final screenTrack =
          session.snapshot.contentShareTrack! as TrtcMediaVideoTrack;
      expect(screenTrack.isScreenShare, isTrue);
      screenTrack.startRendering(88);
      screenTrack.stopRendering();
      expect(
        engine.calls,
        containsAll([
          'remote:sub:start:u-remote:88',
          'remote:sub:stop:u-remote',
        ]),
      );
      // A shared screen is letterboxed, never cropped to the tile shape.
      expect(engine.calls, contains('remote:fill:u-remote:sub:true'));
      expect(screenTrack.width, 0);
      expect(screenTrack.height, 0);
      engineEvents.onUserSubStreamAvailable?.call('u-remote', false);
      expect(session.snapshot.contentShareTrack, isNull);

      await interactive.setScreenShareEnabled(false);
      expect(session.snapshot.localScreenShareEnabled, isFalse);
      expect(engine.calls, contains('screen:stop'));

      engineEvents.onRecvCustomCmdMsg?.call(
        'u-remote',
        1,
        jsonEncode({'topic': 'chat', 'message': 'hello'}),
      );
      await interactive.sendMessage('ack', topic: 'chat');
      await Future<void>.delayed(Duration.zero);
      expect(session.snapshot.messages.map((message) => message.message), [
        'hello',
        'ack',
      ]);
      expect(session.snapshot.messages.first.providerId, 'trtc');
      expect(events.whereType<MediaMessageReceived>(), hasLength(1));
      expect(engine.calls, contains('message:1'));

      engineEvents.onRemoteUserLeaveRoom?.call('u-remote');
      expect(session.snapshot.remoteParticipants, isEmpty);
      engineEvents.onConnectionLost?.call();
      expect(session.state, MediaSessionState.reconnecting);
      engineEvents.onConnectionRecovery?.call();
      expect(session.state, MediaSessionState.connected);
      engineEvents.onError?.call(-42, 'native failure');
      await Future<void>.delayed(Duration.zero);
      expect(session.snapshot.lastError?.code, RealtimeErrorCode.providerError);
      expect(
        session.snapshot.lastError?.message,
        isNot(contains('native failure')),
      );
      await session.leave();
      expect(session.state, MediaSessionState.ended);
      expect(engine.exitCount, 1);
      await statsSubscription.cancel();
      await subscription.cancel();
      await session.dispose();
      expect(session.state, MediaSessionState.disposed);
      expect(engine.disposed, isTrue);
    },
  );

  test(
    'viewer cannot publish or send messages and remains subscribe-only',
    () async {
      final engine = _FakeTrtcEngine();
      final session = TrtcSessionFactory(
        engineFactory: () async => engine,
      ).createSession(joinInfo(role: MediaRole.viewer));
      await session.join(joinInfo(role: MediaRole.viewer));

      expect(session, isA<BroadcastViewerSession>());
      expect(session, isNot(isA<InteractiveMediaSession>()));
      expect(engine.calls, isNot(contains('audio:start')));
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
      await session.dispose();
    },
  );

  test(
    'expired credentials refresh once and re-enter as the same identity',
    () async {
      final engine = _FakeTrtcEngine()..enterResults.addAll([-100018, 1]);
      final session = TrtcSessionFactory(
        engineFactory: () async => engine,
      ).createSession(joinInfo());
      var refreshCalls = 0;
      (session as MediaCredentialRefreshable).setCredentialRefreshCallback((
        current,
      ) async {
        refreshCalls++;
        final trtcCurrent = current as TrtcJoinInfo;
        return TrtcJoinInfo(
          roomCode: trtcCurrent.roomCode,
          participantId: trtcCurrent.participantId,
          role: trtcCurrent.role,
          displayName: trtcCurrent.displayName,
          sdkAppId: trtcCurrent.sdkAppId,
          strRoomId: trtcCurrent.strRoomId,
          userId: trtcCurrent.userId,
          userSig: 'renewed-user-sig',
          privateMapKey: 'renewed-private-map-key',
          expiresAtMs: DateTime.now().millisecondsSinceEpoch + 600000,
        );
      });

      await session.join(joinInfo());
      expect(refreshCalls, 1);
      expect(engine.enteredRooms, hasLength(2));
      expect(engine.enteredRooms.last.userId, 'u-person1');
      expect(engine.enteredRooms.last.userSig, 'renewed-user-sig');
      expect(session.state, MediaSessionState.connected);
      await session.dispose();
    },
  );

  test(
    'maps an unrecoverable native enter failure to a typed provider error',
    () async {
      final engine = _FakeTrtcEngine()..enterResults.add(-42);
      final session = TrtcSessionFactory(
        engineFactory: () async => engine,
      ).createSession(joinInfo());

      await expectLater(
        session.join(joinInfo()),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.providerId,
            'providerId',
            'trtc',
          ),
        ),
      );
      expect(session.state, MediaSessionState.failed);
      await session.dispose();
    },
  );
}

class _FakeTrtcEngine implements TrtcEngine {
  final List<int> enterResults = [];
  Future<int>? pendingEnter;
  final List<TrtcJoinInfo> enteredRooms = [];
  final List<String> calls = [];
  TrtcEngineEvents? lastEvents;
  int exitCount = 0;
  bool disposed = false;
  int? subStreamWidth;
  int? subStreamHeight;

  @override
  Future<int> enterRoom(TrtcJoinInfo joinInfo, TrtcEngineEvents events) async {
    enteredRooms.add(joinInfo);
    lastEvents = events;
    if (pendingEnter != null) return pendingEnter!;
    return enterResults.isEmpty ? 1 : enterResults.removeAt(0);
  }

  @override
  Future<void> exitRoom() async {
    exitCount++;
  }

  @override
  void startLocalAudio() => calls.add('audio:start');

  @override
  void muteLocalAudio(bool muted) => calls.add('audio:mute:$muted');

  @override
  void muteLocalVideo(bool muted) => calls.add('video:mute:$muted');

  @override
  void stopLocalPreview() => calls.add('preview:stop');

  @override
  void startLocalPreview(int viewId) => calls.add('preview:start:$viewId');

  @override
  void clearLocalView() => calls.add('preview:clear');

  @override
  void startRemoteView(String userId, int viewId) =>
      calls.add('remote:start:$userId:$viewId');

  @override
  void stopRemoteView(String userId) => calls.add('remote:stop:$userId');

  @override
  void startRemoteSubStreamView(String userId, int viewId) =>
      calls.add('remote:sub:start:$userId:$viewId');

  @override
  void stopRemoteSubStreamView(String userId) =>
      calls.add('remote:sub:stop:$userId');

  @override
  void setRemoteFillMode(String userId, bool subStream, bool fit) =>
      calls.add('remote:fill:$userId:${subStream ? 'sub' : 'big'}:$fit');

  @override
  int? remoteWidth(String userId, {required bool subStream}) =>
      subStream ? subStreamWidth : null;

  @override
  int? remoteHeight(String userId, {required bool subStream}) =>
      subStream ? subStreamHeight : null;

  @override
  void startScreenCapture() => calls.add('screen:start');

  @override
  void stopScreenCapture() => calls.add('screen:stop');

  @override
  int switchCamera(bool frontCamera) {
    calls.add('camera:$frontCamera');
    return 0;
  }

  @override
  bool sendCustomCmdMsg(int commandId, String data) {
    calls.add('message:$commandId');
    return true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _ThrowingTrtcEngine extends _FakeTrtcEngine {
  @override
  Future<int> enterRoom(TrtcJoinInfo joinInfo, TrtcEngineEvents events) async {
    throw const RealtimeException(
      code: RealtimeErrorCode.permissionDenied,
      message: 'native secret',
    );
  }
}
