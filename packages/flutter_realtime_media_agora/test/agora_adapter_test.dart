import 'package:flutter/foundation.dart';
import 'package:flutter_realtime_media_agora/flutter_realtime_media_agora.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('AgoraJoinInfo', () {
    test('parses the provider block and numeric UID', () {
      final info = AgoraJoinInfo.fromBackendResponse({
        'provider': 'agora',
        'role': 'host',
        'roomCode': '482913',
        'participantId': '12345',
        'displayName': 'Host A',
        'agora': {
          'appId': 'app-id',
          'channelName': 'media-482913',
          'token': 'short-token',
          'uid': 12345,
        },
      });

      expect(info.providerId, 'agora');
      expect(info.role, MediaRole.host);
      expect(info.participantId, '12345');
      expect(info.uid, 12345);
      expect(info.channelName, 'media-482913');
      expect(info.displayName, 'Host A');
    });

    test('accepts a numeric UID string and derives participantId', () {
      final info = AgoraJoinInfo.fromBackendResponse({
        'provider': 'agora',
        'roomCode': 'room-a',
        'agora': {
          'appId': 'app-id',
          'channelName': 'channel-a',
          'token': 'token',
          'uid': '42',
        },
      });

      expect(info.role, MediaRole.participant);
      expect(info.uid, 42);
      expect(info.participantId, '42');
    });

    test('rejects a participantId that does not match uid', () {
      expect(
        () => AgoraJoinInfo.fromBackendResponse({
          'provider': 'agora',
          'roomCode': 'room-a',
          'participantId': '99',
          'agora': {
            'appId': 'app-id',
            'channelName': 'channel-a',
            'token': 'token',
            'uid': 42,
          },
        }),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.invalidArgument,
          ),
        ),
      );
    });

    test('rejects invalid provider and missing Agora block', () {
      expect(
        () => AgoraJoinInfo.fromBackendResponse({
          'provider': 'livekit',
          'roomCode': 'room-a',
        }),
        throwsA(isA<RealtimeException>()),
      );
      expect(
        () => AgoraJoinInfo.fromBackendResponse({
          'provider': 'agora',
          'roomCode': 'room-a',
        }),
        throwsA(isA<RealtimeException>()),
      );
    });

    test('rejects Agora UIDs outside the signed 32-bit range', () {
      expect(
        () => AgoraJoinInfo.fromBackendResponse({
          'provider': 'agora',
          'roomCode': 'room-a',
          'agora': {
            'appId': 'app-id',
            'channelName': 'channel-a',
            'token': 'token',
            'uid': 2147483648,
          },
        }),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.invalidArgument,
          ),
        ),
      );
    });
  });

  group('AgoraSessionFactory', () {
    final factory = AgoraSessionFactory();

    AgoraJoinInfo joinInfo(MediaRole role) => AgoraJoinInfo(
      roomCode: 'room-a',
      participantId: '123',
      role: role,
      appId: 'app-id',
      channelName: 'channel-a',
      token: 'token',
      uid: 123,
    );

    test('Windows exposes native processed-video sink for host only', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final host = factory.createSession(joinInfo(MediaRole.host));
      final viewer = factory.createSession(joinInfo(MediaRole.viewer));
      const source = ProcessedVideoSource(
        id: 'windows',
        platform: ProcessedVideoPlatform.windows,
        kind: ProcessedVideoSourceKind.nativeFrameHub,
        width: 640,
        height: 360,
        frameRate: 24,
      );
      expect(host.capabilities.canBlurBackground, isTrue);
      expect(host.capabilities.canReplaceBackgroundImage, isTrue);
      expect(
        (host as ProcessedVideoSink).supportsProcessedVideoSource(source),
        isTrue,
      );
      expect(viewer.capabilities.canBlurBackground, isFalse);
      await host.dispose();
      await viewer.dispose();
    });

    test(
      'iOS publisher accepts a native Vision processed-video source',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final host = factory.createSession(joinInfo(MediaRole.host));
        const source = ProcessedVideoSource(
          id: 'ios-vision',
          platform: ProcessedVideoPlatform.ios,
          kind: ProcessedVideoSourceKind.nativeFrameHub,
          width: 720,
          height: 1280,
          frameRate: 24,
        );
        expect(host.capabilities.canBlurBackground, isTrue);
        expect(host.capabilities.canReplaceBackgroundImage, isTrue);
        expect(host.capabilities.canSelectCamera, isTrue);
        expect(
          (host as ProcessedVideoSink).supportsProcessedVideoSource(source),
          isTrue,
        );
        await host.dispose();
      },
    );

    test('supports participant, host, and viewer roles', () {
      expect(
        factory.supportedRoles,
        containsAll(<MediaRole>{
          MediaRole.participant,
          MediaRole.host,
          MediaRole.viewer,
        }),
      );
      expect(factory.providerId, 'agora');
    });

    test('creates role-specific session surfaces', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final participant =
          factory.createSession(joinInfo(MediaRole.participant))
              as InteractiveMediaSession;
      final host = factory.createSession(joinInfo(MediaRole.host));
      final viewer = factory.createSession(joinInfo(MediaRole.viewer));

      expect(participant, isA<InteractiveMediaSession>());
      expect(host, isA<BroadcastHostSession>());
      expect(viewer, isA<BroadcastViewerSession>());
      expect(viewer, isNot(isA<InteractiveMediaSession>()));

      expect(participant.capabilities.canPublishAudio, isTrue);
      expect(participant.capabilities.canPublishVideo, isTrue);
      expect(participant.capabilities.canBlurBackground, isTrue);
      expect(participant.capabilities.canReplaceBackgroundImage, isTrue);
      expect(participant.capabilities.canSwitchCamera, isTrue);
      expect(participant.capabilities.canScreenShare, isTrue);
      expect(participant.capabilities.canSendData, isTrue);
      expect(participant.capabilities.canReceiveData, isTrue);
      expect(participant.capabilities.canReportNetworkStats, isTrue);
      expect(participant.capabilities.maxDataMessageBytes, 1024);
      expect(host.capabilities.canListParticipants, isTrue);
      expect(host.capabilities.canCloseRoom, isTrue);
      expect(host.capabilities.canRemoveParticipants, isFalse);

      expect(viewer.capabilities.canPublishAudio, isFalse);
      expect(viewer.capabilities.canPublishVideo, isFalse);
      expect(viewer.capabilities.canBlurBackground, isFalse);
      expect(viewer.capabilities.canSubscribeVideo, isTrue);
      expect(viewer.capabilities.canSendData, isFalse);
      expect(viewer.capabilities.canReceiveData, isTrue);
      expect(viewer.capabilities.canReportNetworkStats, isTrue);

      await participant.dispose();
      await host.dispose();
      await viewer.dispose();
    });

    test('supports macOS with desktop-appropriate capabilities', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

      final participant =
          factory.createSession(joinInfo(MediaRole.participant))
              as InteractiveMediaSession;
      expect(participant.capabilities.canPublishAudio, isTrue);
      expect(participant.capabilities.canPublishVideo, isTrue);
      expect(participant.capabilities.canSubscribeVideo, isTrue);
      expect(participant.capabilities.canSendData, isTrue);
      expect(participant.capabilities.canSwitchCamera, isFalse);
      expect(participant.capabilities.canBlurBackground, isTrue);
      expect(participant.capabilities.canReplaceBackgroundImage, isTrue);

      await expectLater(
        participant.switchCamera(MediaCameraPosition.back),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.unsupportedFeature,
          ),
        ),
      );

      await participant.dispose();
    });

    test('rejects generic join info', () {
      expect(
        () => factory.createSession(
          MediaJoinInfo(
            providerId: 'agora',
            roomCode: 'room-a',
            participantId: '123',
            role: MediaRole.participant,
          ),
        ),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.invalidArgument,
          ),
        ),
      );
    });
  });

  group('Agora session contract', () {
    test('media operations fail with typed invalidState before join', () async {
      final session = AgoraInteractiveSession();
      await expectLater(
        session.setMuted(false),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.invalidState,
          ),
        ),
      );
      await session.dispose();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final android = AgoraHostSession();
      expect(android.capabilities.canScreenShare, isTrue);
      await expectLater(
        android.setScreenShareEnabled(true),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.invalidState,
          ),
        ),
      );
      await android.dispose();
    });

    test(
      'native screen-share capability matches available capture implementations',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final session = AgoraHostSession();
        expect(session.capabilities.canScreenShare, isTrue);
        await expectLater(
          session.setScreenShareEnabled(true),
          throwsA(
            isA<RealtimeException>().having(
              (error) => error.code,
              'code',
              RealtimeErrorCode.invalidState,
            ),
          ),
        );
        await session.dispose();
      },
    );

    test('dispose is idempotent before native engine creation', () async {
      final session = AgoraViewerSession();
      await session.dispose();
      await session.dispose();
      expect(session.state, MediaSessionState.disposed);
    });
  });
}
