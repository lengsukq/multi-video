import 'dart:async';

import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_media_livekit/flutter_realtime_media_livekit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const backendUrl = String.fromEnvironment('MEDIA_E2E_BACKEND_URL');
  const runDeviceMedia = bool.fromEnvironment('MEDIA_E2E_DEVICE_MEDIA');

  testWidgets('LiveKit host + viewer signaling/data E2E', (tester) async {
    if (backendUrl.isEmpty) {
      markTestSkipped(
        'Set MEDIA_E2E_BACKEND_URL to run the local LiveKit E2E.',
      );
      return;
    }

    final registry = MediaRegistry([const LiveKitSessionFactory()]);
    final hostClient = MediaClient(
      backendUrl: backendUrl,
      registry: registry,
      heartbeatInterval: const Duration(seconds: 2),
    );
    final viewerClient = MediaClient(
      backendUrl: backendUrl,
      registry: registry,
      heartbeatInterval: const Duration(seconds: 2),
    );
    MediaRoomSession? hostRoom;
    MediaRoomSession? viewerRoom;

    try {
      hostRoom = await hostClient
          .createRoomAndJoin(nickname: 'E2E Host', role: MediaRole.host)
          .timeout(const Duration(seconds: 20));
      viewerRoom = await viewerClient
          .joinRoom(
            roomCode: hostRoom.roomCode,
            nickname: 'E2E Viewer',
            role: MediaRole.viewer,
          )
          .timeout(const Duration(seconds: 20));

      expect(hostRoom.session, isA<LiveKitHostSession>());
      expect(viewerRoom.session, isA<LiveKitViewerSession>());
      expect(viewerRoom.session, isNot(isA<InteractiveMediaSession>()));

      final host = hostRoom.session as InteractiveMediaSession;

      await _waitUntil(
        () => viewerRoom!.session.snapshot.remoteParticipants.any(
          (participant) => participant.id == hostRoom!.participantId,
        ),
      );

      await host
          .sendMessage('hello-viewer', topic: 'e2e')
          .timeout(const Duration(seconds: 10));
      await _waitUntil(
        () => viewerRoom!.session.snapshot.messages.any(
          (message) =>
              message.topic == 'e2e' && message.message == 'hello-viewer',
        ),
      );

      expect(viewerRoom.session.capabilities.canPublishVideo, isFalse);
      expect(viewerRoom.session.capabilities.canSubscribeVideo, isTrue);
    } finally {
      if (viewerRoom != null) {
        await viewerRoom.dispose().timeout(const Duration(seconds: 10));
      }
      if (hostRoom != null) {
        await hostRoom.dispose().timeout(const Duration(seconds: 10));
      }
      viewerClient.dispose();
      hostClient.dispose();
    }
  });

  testWidgets('LiveKit device media E2E', (tester) async {
    if (backendUrl.isEmpty || !runDeviceMedia) {
      markTestSkipped(
        'Set MEDIA_E2E_BACKEND_URL and MEDIA_E2E_DEVICE_MEDIA=true on a '
        'device with microphone/camera support.',
      );
      return;
    }

    final registry = MediaRegistry([const LiveKitSessionFactory()]);
    final hostClient = MediaClient(
      backendUrl: backendUrl,
      registry: registry,
      heartbeatInterval: const Duration(seconds: 2),
    );
    final viewerClient = MediaClient(
      backendUrl: backendUrl,
      registry: registry,
      heartbeatInterval: const Duration(seconds: 2),
    );
    MediaRoomSession? hostRoom;
    MediaRoomSession? viewerRoom;

    try {
      hostRoom = await hostClient
          .createRoomAndJoin(nickname: 'Device Host', role: MediaRole.host)
          .timeout(const Duration(seconds: 20));
      viewerRoom = await viewerClient
          .joinRoom(
            roomCode: hostRoom.roomCode,
            nickname: 'Device Viewer',
            role: MediaRole.viewer,
          )
          .timeout(const Duration(seconds: 20));

      final host = hostRoom.session as InteractiveMediaSession;
      await host.setMuted(false).timeout(const Duration(seconds: 15));
      expect(hostRoom.session.snapshot.localMuted, isFalse);
      await host.setVideoEnabled(true).timeout(const Duration(seconds: 15));
      await host
          .switchCamera(MediaCameraPosition.back)
          .timeout(const Duration(seconds: 15));
      await host
          .switchCamera(MediaCameraPosition.front)
          .timeout(const Duration(seconds: 15));

      await _waitUntil(
        () => viewerRoom!.session.snapshot.remoteParticipants.any(
          (participant) => participant.id == hostRoom!.participantId,
        ),
      );
      await _waitUntil(
        () => viewerRoom!.session.snapshot.remoteParticipants.any(
          (participant) => participant.videoTrack != null,
        ),
      );

      expect(hostRoom.session.snapshot.localVideoEnabled, isTrue);
      expect(viewerRoom.session.capabilities.canPublishVideo, isFalse);

      await host.setVideoEnabled(false).timeout(const Duration(seconds: 15));
      await host.setMuted(true).timeout(const Duration(seconds: 15));
      expect(hostRoom.session.snapshot.localMuted, isTrue);
      await host.setMuted(false).timeout(const Duration(seconds: 15));
      expect(hostRoom.session.snapshot.localMuted, isFalse);
    } finally {
      if (viewerRoom != null) {
        await viewerRoom.dispose().timeout(const Duration(seconds: 10));
      }
      if (hostRoom != null) {
        await hostRoom.dispose().timeout(const Duration(seconds: 10));
      }
      viewerClient.dispose();
      hostClient.dispose();
    }
  });
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met within $timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
