import 'package:flutter/foundation.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_media_trtc/flutter_realtime_media_trtc.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> joinPayload({
  String role = 'participant',
  String roomCode = '482913',
  String participantId = 'u-person1',
  String userId = 'u-person1',
}) => {
  'contractVersion': 1,
  'provider': 'trtc',
  'role': role,
  'roomCode': roomCode,
  'participantId': participantId,
  'displayName': 'Person 1',
  'trtc': {
    'sdkAppId': 1400000000,
    'strRoomId': 'media-482913',
    'userId': userId,
    'userSig': 'short-lived-user-sig',
    'privateMapKey': 'room-scoped-private-map-key',
    'expiresAtMs': DateTime.now().millisecondsSinceEpoch + 600000,
  },
};

void main() {
  const factory = TrtcSessionFactory();
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('TRTC join information', () {
    test('parses credentials and maps role to a room scene', () {
      final participant = TrtcJoinInfo.fromJson(joinPayload());
      final host = TrtcJoinInfo.fromJson(joinPayload(role: 'host'));
      final viewer = TrtcJoinInfo.fromJson(joinPayload(role: 'viewer'));

      expect(participant.scene, TrtcRoomScene.videoCall);
      expect(host.scene, TrtcRoomScene.live);
      expect(viewer.scene, TrtcRoomScene.live);
      expect(participant.userId, participant.participantId);
      expect(participant.sdkAppId, 1400000000);
      expect(participant.privateMapKey, isNotEmpty);
      expect(
        participant.expiresAtMs,
        greaterThan(DateTime.now().millisecondsSinceEpoch),
      );
    });

    test(
      'rejects a TRTC user id that differs from the common participant id',
      () {
        expect(
          () => TrtcJoinInfo.fromJson(joinPayload(userId: 'another-user')),
          throwsA(
            isA<RealtimeException>().having(
              (error) => error.code,
              'code',
              RealtimeErrorCode.invalidArgument,
            ),
          ),
        );
      },
    );

    test('rejects missing provider credentials and invalid app ids', () {
      final missing = joinPayload()..remove('trtc');
      final invalidAppId = joinPayload()
        ..['trtc'] = {...joinPayload()['trtc'] as Map, 'sdkAppId': 0};

      expect(
        () => TrtcJoinInfo.fromJson(missing),
        throwsA(isA<RealtimeException>()),
      );
      expect(
        () => TrtcJoinInfo.fromJson(invalidAppId),
        throwsA(isA<RealtimeException>()),
      );
    });
  });

  group('role surfaces and capabilities', () {
    test('Windows host can attach native-frame provider only', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final host = factory.createSession(
        TrtcJoinInfo.fromJson(joinPayload(role: 'host')),
      );
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
      await host.dispose();
    });
    test('iOS host supports Vision processed frame publishing', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final host = factory.createSession(
        TrtcJoinInfo.fromJson(joinPayload(role: 'host')),
      );
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
    });
    test(
      'screen capture capability follows native desktop and mobile hosts only',
      () async {
        for (final platform in <TargetPlatform>[
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.macOS,
          TargetPlatform.windows,
        ]) {
          debugDefaultTargetPlatformOverride = platform;
          final host = factory.createSession(
            TrtcJoinInfo.fromJson(joinPayload(role: 'host')),
          );
          final viewer = factory.createSession(
            TrtcJoinInfo.fromJson(joinPayload(role: 'viewer')),
          );
          expect(
            host.capabilities.canScreenShare,
            isTrue,
            reason: 'platform: $platform',
          );
          expect(
            viewer.capabilities.canScreenShare,
            isFalse,
            reason: 'viewer $platform',
          );
          await host.dispose();
          await viewer.dispose();
        }
      },
    );
    test('factory creates publishable participant and host sessions', () {
      final participant = factory.createSession(
        TrtcJoinInfo.fromJson(joinPayload()),
      );
      final host = factory.createSession(
        TrtcJoinInfo.fromJson(joinPayload(role: 'host')),
      );

      expect(participant, isA<InteractiveMediaSession>());
      expect(host, isA<BroadcastHostSession>());
      expect(host.capabilities.canPublishAudio, isTrue);
      expect(host.capabilities.canPublishVideo, isTrue);
      expect(host.capabilities.canSendData, isTrue);
      expect(host.capabilities.canReceiveData, isTrue);
      expect(host.capabilities.canScreenShare, isTrue);
      expect(host.capabilities.canEnumerateAudioDevices, isFalse);
      expect(host.capabilities.canReportNetworkStats, isTrue);
      expect(host.capabilities.maxDataMessageBytes, 1024);
      expect(host.capabilities.canListParticipants, isTrue);
      expect(host.capabilities.canCloseRoom, isTrue);
      expect(host.capabilities.canRemoveParticipants, isFalse);
    });

    test('viewer is subscribe-only and cannot send data', () {
      final viewer = factory.createSession(
        TrtcJoinInfo.fromJson(joinPayload(role: 'viewer')),
      );

      expect(viewer, isA<BroadcastViewerSession>());
      expect(viewer, isNot(isA<InteractiveMediaSession>()));
      expect(viewer.capabilities.canSubscribeVideo, isTrue);
      expect(viewer.capabilities.canPublishAudio, isFalse);
      expect(viewer.capabilities.canPublishVideo, isFalse);
      expect(viewer.capabilities.canSendData, isFalse);
      expect(viewer.capabilities.canReceiveData, isTrue);
      expect(viewer.capabilities.canReportNetworkStats, isTrue);
    });
  });
}
