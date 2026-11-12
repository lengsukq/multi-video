import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_realtime_media_artc/flutter_realtime_media_artc.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _backendUrl = String.fromEnvironment('ARTC_E2E_BACKEND_URL');
const _token = String.fromEnvironment('ARTC_E2E_TOKEN');
const _roomCode = String.fromEnvironment('ARTC_E2E_ROOM_CODE');
const _nickname = String.fromEnvironment(
  'ARTC_E2E_NICKNAME',
  defaultValue: 'artc-e2e',
);
const _roleName = String.fromEnvironment('ARTC_E2E_ROLE', defaultValue: 'host');
const _createRoom = bool.fromEnvironment(
  'ARTC_E2E_CREATE_ROOM',
  defaultValue: true,
);
const _runDeviceMedia = bool.fromEnvironment('ARTC_E2E_DEVICE_MEDIA');
const _expectRemoteParticipantCount = int.fromEnvironment(
  'ARTC_E2E_EXPECT_REMOTE_PARTICIPANTS',
);
const _expectRemoteMessage = bool.fromEnvironment(
  'ARTC_E2E_EXPECT_REMOTE_MESSAGE',
);
const _expectRenewal = bool.fromEnvironment('ARTC_E2E_EXPECT_RENEWAL');
const _renderRemoteVideo = bool.fromEnvironment('ARTC_E2E_RENDER_REMOTE_VIDEO');
const _holdSeconds = int.fromEnvironment('ARTC_E2E_HOLD_SECONDS');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real device ARTC session lifecycle',
    (tester) async {
      expect(
        defaultTargetPlatform,
        anyOf(
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.windows,
        ),
      );
      final role = MediaRole.tryParse(_roleName);
      if (role == null) {
        fail('ARTC_E2E_ROLE must be participant, host, or viewer.');
      }
      if (!_createRoom && _roomCode.trim().isEmpty) {
        fail('ARTC_E2E_ROOM_CODE is required when ARTC_E2E_CREATE_ROOM=false.');
      }

      final client = MediaClient(
        backendUrl: _backendUrl,
        registry: MediaRegistry([const ArtcSessionFactory()]),
        tokenProvider: _token.trim().isEmpty ? null : () => _token,
        heartbeatInterval: const Duration(seconds: 2),
      );
      MediaRoomSession? room;
      addTearDown(() async {
        await room?.dispose();
        client.dispose();
      });

      room = _createRoom
          ? await client
                .createRoomAndJoin(
                  roomCode: _roomCode.trim().isEmpty ? null : _roomCode,
                  nickname: _nickname,
                  role: role,
                )
                .timeout(const Duration(seconds: 60))
          : await client
                .joinRoom(roomCode: _roomCode, nickname: _nickname, role: role)
                .timeout(const Duration(seconds: 60));

      final session = room.session;
      expect(room.providerId, 'artc');
      expect(session.providerId, 'artc');
      await _waitForState(session, MediaSessionState.connected);
      expect(session.snapshot.localParticipant, isNotNull);

      final renewal = _expectRenewal
          ? session.states.firstWhere(
              (state) => state == MediaSessionState.reconnecting,
            )
          : null;

      if (role == MediaRole.viewer) {
        expect(session, isA<BroadcastViewerSession>());
        expect(session, isNot(isA<InteractiveMediaSession>()));
        expect(session.capabilities.canPublishAudio, isFalse);
        expect(session.capabilities.canPublishVideo, isFalse);
        expect(session.capabilities.canSendData, isFalse);
        await expectLater(
          (session as BroadcastViewerSession).sendMessage('viewer-send-denied'),
          throwsA(isA<RealtimeException>()),
        );
      } else {
        expect(session, isA<InteractiveMediaSession>());
        final interactive = session as InteractiveMediaSession;
        if (_runDeviceMedia) {
          await interactive
              .setMuted(false)
              .timeout(const Duration(seconds: 20));
          await interactive
              .setVideoEnabled(true)
              .timeout(const Duration(seconds: 20));
          if (defaultTargetPlatform != TargetPlatform.windows) {
            await interactive.switchCamera(MediaCameraPosition.back);
            await interactive.switchCamera(MediaCameraPosition.front);
          }
          expect(session.snapshot.localVideoEnabled, isTrue);
        }
      }

      if (_expectRemoteParticipantCount > 0) {
        await _waitForRemoteCount(session, _expectRemoteParticipantCount);
      }
      if (role != MediaRole.viewer && _runDeviceMedia) {
        await (session as InteractiveMediaSession).sendMessage(
          'artc-e2e-${DateTime.now().millisecondsSinceEpoch}',
          topic: 'artc-e2e',
        );
      }
      if (_expectRemoteMessage) await _waitForRemoteMessage(session);
      if (_renderRemoteVideo) {
        final track = await _waitForRemoteVideo(session);
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: MediaTrackView(
              renderer: const ArtcTrackRenderer(),
              track: track,
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 2));
      }
      if (renewal != null) {
        await renewal.timeout(const Duration(minutes: 12));
        await _waitForState(session, MediaSessionState.connected);
      }
      if (_holdSeconds > 0) {
        await Future<void>.delayed(Duration(seconds: _holdSeconds));
      }

      await room.leave().timeout(const Duration(seconds: 20));
      expect(session.state, MediaSessionState.ended);
      await room.dispose().timeout(const Duration(seconds: 20));
      expect(session.state, MediaSessionState.disposed);
    },
    skip: _backendUrl.trim().isEmpty,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

Future<void> _waitForState(
  MediaSession session,
  MediaSessionState expected,
) async {
  if (session.state == expected) return;
  final state = await session.states
      .firstWhere(
        (value) =>
            value == expected ||
            value == MediaSessionState.failed ||
            value == MediaSessionState.ended ||
            value == MediaSessionState.disposed,
      )
      .timeout(const Duration(seconds: 60));
  if (state != expected) {
    fail('Expected ARTC state $expected, but reached $state.');
  }
}

Future<void> _waitForRemoteCount(MediaSession session, int count) async {
  bool reached(MediaSnapshot snapshot) =>
      snapshot.remoteParticipants.length >= count;
  if (reached(session.snapshot)) return;
  await session.snapshots
      .firstWhere(reached)
      .timeout(const Duration(seconds: 60));
}

Future<void> _waitForRemoteMessage(MediaSession session) async {
  bool received(MediaSnapshot snapshot) => snapshot.messages.any(
    (message) => message.participantId != session.snapshot.localParticipantId,
  );
  if (received(session.snapshot)) return;
  await session.snapshots
      .firstWhere(received)
      .timeout(const Duration(seconds: 60));
}

Future<MediaVideoTrack> _waitForRemoteVideo(MediaSession session) async {
  MediaVideoTrack? track(MediaSnapshot snapshot) {
    for (final participant in snapshot.remoteParticipants) {
      if (participant.videoTrack != null) return participant.videoTrack;
    }
    return null;
  }

  final current = track(session.snapshot);
  if (current != null) return current;
  return session.snapshots
      .map(track)
      .where((item) => item != null)
      .cast<MediaVideoTrack>()
      .first
      .timeout(const Duration(seconds: 60));
}
