import 'package:flutter/widgets.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_media_livekit/flutter_realtime_media_livekit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LiveKit session contract', () {
    test('publisher exposes the declared media capabilities', () {
      final session = LiveKitInteractiveSession();

      expect(session.role, MediaRole.participant);
      expect(session.state, MediaSessionState.idle);
      expect(session.capabilities.canPublishAudio, isTrue);
      expect(session.capabilities.canPublishVideo, isTrue);
      expect(session.capabilities.canSwitchCamera, isTrue);
      expect(session.capabilities.canScreenShare, isTrue);
      expect(session.capabilities.canSendData, isTrue);
      expect(session.capabilities.canReceiveData, isTrue);
      expect(session.capabilities.canSubscribeVideo, isTrue);
      expect(session.capabilities.canReportNetworkStats, isTrue);
      expect(session.capabilities.canTargetData, isTrue);
      expect(session.capabilities.canSendUnreliableData, isTrue);
      expect(session.capabilities.maxDataMessageBytes, 15 * 1024);
      expect(session.iosScreenShareMode, IosScreenShareMode.system);
    });

    test('iOS application-only capture is an explicit opt-in', () async {
      final session = LiveKitInteractiveSession(
        iosScreenShareMode: IosScreenShareMode.application,
      );
      expect(session.iosScreenShareMode, IosScreenShareMode.application);
      await session.dispose();
    });

    test('viewer is subscribe-only at the Dart type and capability layers', () {
      final MediaSession session = LiveKitViewerSession();

      expect(session, isA<BroadcastViewerSession>());
      expect(session, isNot(isA<InteractiveMediaSession>()));
      expect(session.role, MediaRole.viewer);
      expect(session.capabilities.canPublishAudio, isFalse);
      expect(session.capabilities.canPublishVideo, isFalse);
      expect(session.capabilities.canScreenShare, isFalse);
      expect(session.capabilities.canSubscribeVideo, isTrue);
      expect(session.capabilities.canReceiveData, isTrue);
      expect(session.capabilities.canTargetData, isTrue);
    });

    test('media operations fail with typed invalidState before join', () async {
      final session = LiveKitInteractiveSession();

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
      await expectLater(
        session.setVideoEnabled(true),
        throwsA(isA<RealtimeException>()),
      );
      await expectLater(
        session.sendMessage('hello'),
        throwsA(isA<RealtimeException>()),
      );
      await session.dispose();
    });

    test('dispose is idempotent without a provider connection', () async {
      final session = LiveKitViewerSession();
      final states = <MediaSessionState>[];
      final subscription = session.states.listen(states.add);

      await session.dispose();
      await session.dispose();
      await pumpEventQueue();

      expect(session.state, MediaSessionState.disposed);
      expect(states, isEmpty);
      expect(session.state, MediaSessionState.disposed);
      await subscription.cancel();
    });

    test(
      'pre-join probe degrades network checks without credentials',
      () async {
        const factory = LiveKitSessionFactory();
        final probe = factory as MediaPreJoinProbe;

        final result = await probe.runPreJoinProbe(
          const MediaPreJoinProbeRequest(
            providerId: 'livekit',
            role: MediaRole.viewer,
            requirements: MediaPreJoinRequirements.viewer(),
          ),
        );

        expect(
          result.checks
              .singleWhere(
                (check) => check.type == MediaPreJoinCheckType.providerNetwork,
              )
              .status,
          MediaPreJoinStatus.unsupported,
        );
        expect(
          result.checks.where(
            (check) => check.type == MediaPreJoinCheckType.microphoneDevice,
          ),
          isEmpty,
        );
        expect(
          result.checks.where(
            (check) => check.type == MediaPreJoinCheckType.cameraDevice,
          ),
          isEmpty,
        );
      },
    );

    test('required device enumeration failure is blocking', () async {
      final factory = LiveKitSessionFactory(
        audioInputCountLoader: () async => throw StateError('device failure'),
        videoInputCountLoader: () async => 1,
      );
      final probe = factory as MediaPreJoinProbe;

      final result = await probe.runPreJoinProbe(
        const MediaPreJoinProbeRequest(
          providerId: 'livekit',
          role: MediaRole.participant,
          requirements: MediaPreJoinRequirements(
            microphone: MediaPreJoinRequirement.required,
            camera: MediaPreJoinRequirement.skipped,
            network: MediaPreJoinRequirement.skipped,
          ),
        ),
      );

      final microphone = result.checks.singleWhere(
        (check) => check.type == MediaPreJoinCheckType.microphoneDevice,
      );
      expect(microphone.status, MediaPreJoinStatus.unknown);
      expect(microphone.isBlocking, isTrue);
    });

    testWidgets('renderer rejects a track from another provider', (
      tester,
    ) async {
      final renderer = LiveKitTrackRenderer();
      late Object thrown;

      await tester.pumpWidget(
        Builder(
          builder: (context) {
            try {
              renderer.buildView(context, const _OtherProviderTrack());
            } catch (error) {
              thrown = error;
            }
            return const SizedBox.shrink();
          },
        ),
      );

      expect(thrown, isA<ArgumentError>());
    });
  });
}

class _OtherProviderTrack extends MediaVideoTrack {
  const _OtherProviderTrack();

  @override
  String get id => 'other-track';

  @override
  String get participantId => 'other-participant';

  @override
  bool get isLocal => false;

  @override
  bool get isScreenShare => false;

  @override
  int get width => 0;

  @override
  int get height => 0;
}
