import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_aws_chime/flutter_aws_chime.dart' as chime;
import 'package:flutter_realtime_media_chime/flutter_realtime_media_chime.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chime_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map<String, dynamic> backendJson({String role = 'participant'}) => {
    'contractVersion': 1,
    'provider': 'chime',
    'role': role,
    'roomCode': '482913',
    'participantId': 'attendee-local',
    'meeting': {
      'MeetingId': 'meeting-id',
      'ExternalMeetingId': 'room-482913',
      'MediaRegion': 'ap-southeast-1',
      'MediaPlacement': {
        'AudioHostUrl': 'https://audio.example',
        'AudioFallbackUrl': 'https://fallback.example',
        'SignalingUrl': 'wss://signal.example',
        'TurnControlUrl': 'https://turn.example',
      },
    },
    'attendee': {
      'AttendeeId': 'attendee-local',
      'ExternalUserId': 'Local User',
      'JoinToken': 'short-lived-token',
    },
  };

  test(
    'Chime retains the provider error code without exposing native payloads',
    () async {
      final provider = _FailingControlSession();
      final adapter = ChimeMediaSession(session: provider);
      addTearDown(adapter.dispose);
      await adapter.join(ChimeJoinInfo.fromBackendResponse(backendJson()));
      await expectLater(
        adapter.setMuted(false),
        throwsA(
          isA<RealtimeException>()
              .having(
                (error) => error.code,
                'code',
                RealtimeErrorCode.permissionDenied,
              )
              .having(
                (error) => error.message,
                'safe message',
                isNot(contains('native secret')),
              )
              .having((error) => error.cause, 'diagnostic cause', isNotNull),
        ),
      );
    },
  );

  test(
    'content modality retains its native ID and maps to its classroom owner',
    () {
      final track = ChimeMediaVideoTrack(
        const chime.MeetingVideoTile(
          tileId: 3,
          attendeeId: 'teacher#content',
          width: 1920,
          height: 1080,
          isLocal: false,
          isContentShare: true,
        ),
      );
      expect(track.participantId, 'teacher#content');
      expect((track as MediaVideoTrack).contentOwnerParticipantId, 'teacher');
      expect(track.isScreenShare, true);
    },
  );
  group('ChimeJoinInfo', () {
    test('wraps the existing Chime JoinInfo without changing its payload', () {
      final info = ChimeJoinInfo.fromBackendResponse(backendJson());

      expect(info.providerId, 'chime');
      expect(info.role, MediaRole.participant);
      expect(info.roomCode, '482913');
      expect(info.participantId, 'attendee-local');
      expect(info.chimeJoinInfo.meeting.meetingId, 'meeting-id');
      expect(info.chimeJoinInfo.attendee.joinToken, 'short-lived-token');
    });

    test('rejects broadcast roles until Chime can enforce them', () {
      expect(
        () => ChimeJoinInfo.fromBackendResponse(backendJson(role: 'viewer')),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.unsupportedFeature,
          ),
        ),
      );
    });
  });

  group('ChimeMediaSession', () {
    test(
      'iOS ScreenCaptureKit delegates actual content sharing to native Chime',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        const capture = MethodChannel(
          'flutter_realtime_processed_video/ios_system_screen_capture',
        );
        const chimeChannel = MethodChannel(
          'com.oneplusdream.aws.chime.methodChannel',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final calls = <String>[];
        messenger.setMockMethodCallHandler(capture, (call) async {
          calls.add(call.method);
          if (call.method == 'iosScreenCaptureKitAvailable') return true;
          if (call.method == 'iosScreenCaptureKitStart') {
            return {
              'id': 'screen-1',
              'kind': 'nativeFrameHub',
              'platform': 'ios',
              'width': 1170,
              'height': 2532,
              'frameRate': 30.0,
            };
          }
          return null;
        });
        messenger.setMockMethodCallHandler(chimeChannel, (call) async {
          calls.add(call.method);
          return {'success': true, 'data': null};
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(capture, null);
          messenger.setMockMethodCallHandler(chimeChannel, null);
        });
        final adapter = ChimeMediaSession(session: FakeChimeMeetingSession());
        await adapter.join(ChimeJoinInfo.fromBackendResponse(backendJson()));
        expect(adapter.capabilities.canScreenShare, isTrue);
        await adapter.setScreenShareEnabled(true);
        expect(adapter.snapshot.localScreenShareEnabled, isTrue);
        expect(calls, contains('attachIosScreenCaptureKitSource'));
        await adapter.setScreenShareEnabled(false);
        expect(adapter.snapshot.localScreenShareEnabled, isFalse);
        expect(calls, contains('detachIosScreenCaptureKitSource'));
        await adapter.dispose();
      },
    );

    test('repeated leave and dispose release Chime exactly once', () async {
      final provider = FakeChimeMeetingSession();
      final adapter = ChimeMediaSession(session: provider);
      final info = ChimeJoinInfo.fromBackendResponse(backendJson());
      await adapter.join(info);
      await adapter.leave();
      await adapter.leave();
      expect(
        provider.actions.where((action) => action == 'leave'),
        hasLength(1),
      );
      final first = adapter.dispose();
      final second = adapter.dispose();
      expect(identical(first, second), isTrue);
      await first;
      expect(
        provider.actions.where((action) => action == 'dispose'),
        hasLength(1),
      );
    });

    test('late provider join cannot revive a room after leave', () async {
      final pending = _PendingChimeSession();
      final adapter = ChimeMediaSession(session: pending);
      final info = ChimeJoinInfo.fromBackendResponse(backendJson());
      final joining = adapter.join(info);
      final failure = expectLater(
        joining,
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.cancelled,
          ),
        ),
      );
      await adapter.leave();
      expect(adapter.state, MediaSessionState.ended);
      pending.finishJoin();
      await failure;
      expect(adapter.state, MediaSessionState.ended);
      await adapter.dispose();
    });

    late FakeChimeMeetingSession providerSession;
    late ChimeMediaSession session;
    late ChimeJoinInfo joinInfo;

    setUp(() {
      providerSession = FakeChimeMeetingSession();
      session = ChimeMediaSession(session: providerSession);
      joinInfo = ChimeJoinInfo.fromBackendResponse(backendJson());
    });

    test(
      'processed input owns camera switching and is released on leave',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final commands = <MethodCall>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        for (final channel in [
          const MethodChannel('com.oneplusdream.aws.chime.methodChannel'),
          const MethodChannel('flutter_realtime_processed_video/sources'),
        ]) {
          messenger.setMockMethodCallHandler(channel, (call) async {
            commands.add(call);
            return null;
          });
          addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        }
        await session.join(joinInfo);
        const source = ProcessedVideoSource(
          id: 'shared-processed-frame-source',
          platform: ProcessedVideoPlatform.android,
          kind: ProcessedVideoSourceKind.nativeFrameHub,
          width: 1280,
          height: 720,
          frameRate: 24,
        );
        await session.attachProcessedVideoSource(source);
        await session.setVideoEnabled(true);
        await session.switchCamera(MediaCameraPosition.back);
        await session.selectMediaDevice(
          const MediaDevice(
            id: 'front',
            label: 'Front',
            kind: MediaDeviceKind.camera,
          ),
        );
        await session.setVideoEnabled(false);
        expect(providerSession.actions, isNot(contains('camera:back')));
        expect(
          commands
              .where((c) => c.method == 'selectCamera')
              .map((c) => (c.arguments as Map)['deviceId']),
          ['back', 'front'],
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
      'macOS declares effects only after a successful native input probe',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        const channel = MethodChannel(
          'com.oneplusdream.aws.chime.methodChannel',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'probeProcessedVideoInput',
        );
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        expect(session.capabilities.canBlurBackground, isFalse);
        await session.join(joinInfo);
        expect(session.capabilities.canBlurBackground, isTrue);
        expect(session.snapshot.capabilities.canReplaceBackgroundImage, isTrue);
        await session.dispose();
      },
    );

    test('maps join state and the local attendee', () async {
      await session.join(joinInfo);

      expect(session.state, MediaSessionState.connected);
      expect(session.snapshot.localParticipantId, 'attendee-local');
      expect(session.snapshot.localParticipant?.displayName, 'Local User');
      expect(session.capabilities.canPublishVideo, isTrue);
      expect(session.capabilities.canScreenShare, isFalse);
      expect(session.capabilities.canSelectAudioOutput, isTrue);
      expect(session.capabilities.canSendData, isTrue);
      expect(session.capabilities.canReceiveData, isTrue);
      expect(session.capabilities.maxDataMessageBytes, 2048);
      expect(session.capabilities.canReportNetworkStats, isFalse);
      await session.dispose();
    });

    test(
      'maps remote participants, video tiles, speaking, and messages',
      () async {
        await session.join(joinInfo);
        final events = <MediaEvent>[];
        final subscription = session.events.listen(events.add);

        providerSession.emitRemoteParticipant(
          id: 'remote-a',
          name: 'Remote A',
          videoTile: const chime.MeetingVideoTile(
            tileId: 7,
            attendeeId: 'remote-a',
            width: 1280,
            height: 720,
            isLocal: false,
            isContentShare: false,
          ),
        );
        providerSession.emitVolume('remote-a', chime.MeetingVolumeLevel.high);
        await session.sendMessage('hello', topic: 'chat');
        await pumpEventQueue();

        final remote = session.snapshot.remoteParticipants.single;
        expect(remote.id, 'remote-a');
        expect(remote.videoTrack, isA<ChimeMediaVideoTrack>());
        expect(remote.isSpeaking, isTrue);
        expect(session.snapshot.messages.single.message, 'hello');
        expect(session.snapshot.messages.single.providerId, 'chime');
        expect(events.whereType<MediaParticipantJoined>(), isNotEmpty);
        expect(events.whereType<MediaTrackPublished>(), isNotEmpty);
        expect(events.whereType<MediaSpeakingChanged>(), isNotEmpty);
        expect(events.whereType<MediaMessageReceived>(), isNotEmpty);

        providerSession.removeParticipant('remote-a');
        await pumpEventQueue();
        expect(session.snapshot.remoteParticipants, isEmpty);
        expect(events.whereType<MediaParticipantLeft>(), isNotEmpty);

        await subscription.cancel();
        await session.dispose();
      },
    );

    test(
      'delegates controls and rejects unsupported outgoing screen share',
      () async {
        await session.join(joinInfo);

        await session.setMuted(false);
        await session.setVideoEnabled(true);
        await session.switchCamera(MediaCameraPosition.back);
        final devices = await session.listAudioDevices();
        await session.selectAudioDevice(devices.single);

        expect(providerSession.actions, contains('muted:false'));
        expect(providerSession.actions, contains('video:true'));
        expect(providerSession.actions, contains('camera:back'));
        expect(providerSession.actions, contains('audio:Speaker'));
        await expectLater(
          session.setScreenShareEnabled(true),
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
      'dispose is idempotent through the existing provider session',
      () async {
        await session.join(joinInfo);
        await session.dispose();
        await session.dispose();

        expect(session.state, MediaSessionState.disposed);
        expect(
          providerSession.actions.where((item) => item == 'dispose').length,
          1,
        );
      },
    );
  });

  test('factory registers only the role Chime currently guarantees', () {
    final fake = FakeChimeMeetingSession();
    final factory = ChimeSessionFactory(sessionFactory: () => fake);
    final info = ChimeJoinInfo.fromBackendResponse(backendJson());

    expect(factory.providerId, 'chime');
    expect(factory.supportedRoles, {MediaRole.participant});
    expect(factory.createSession(info).chimeSession, same(fake));
  });
}

class _PendingChimeSession extends FakeChimeMeetingSession {
  final Completer<void> _pending = Completer<void>();

  @override
  Future<void> join(chime.JoinInfo info) async {
    await _pending.future;
    await super.join(info);
  }

  void finishJoin() => _pending.complete();
}

class _FailingControlSession extends FakeChimeMeetingSession {
  @override
  Future<void> setMuted(bool muted) async {
    throw const chime.RealtimeException(
      code: RealtimeErrorCode.permissionDenied,
      message: 'native secret',
    );
  }
}
