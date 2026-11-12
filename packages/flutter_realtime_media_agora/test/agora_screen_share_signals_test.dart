import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_realtime_media_agora/src/agora_screen_share_signals.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Agora screen-share SDK signalling protocol', () {
    test('encodes only provider-internal metadata, not a chat event', () {
      final bytes = encodeAgoraScreenShareSignal(
        AgoraScreenShareSignal.started,
        timestampMs: 123,
      );
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(decoded, {
        'version': 1,
        'topic': agoraScreenShareTopic,
        'message': 'started',
        'timestampMs': 123,
      });
      expect(
        decodeAgoraScreenShareSignal(bytes),
        AgoraScreenShareSignal.started,
      );
      expect(
        decodeAgoraScreenShareSignal(
          encodeAgoraScreenShareSignal(AgoraScreenShareSignal.stopped),
        ),
        AgoraScreenShareSignal.stopped,
      );
    });

    test('ignores malformed, unrelated or unsupported messages', () {
      Uint8List json(Map<String, Object?> map) =>
          Uint8List.fromList(utf8.encode(jsonEncode(map)));

      expect(decodeAgoraScreenShareSignal(Uint8List.fromList([255])), null);
      expect(decodeAgoraScreenShareSignal(json({'message': 'started'})), null);
      expect(
        decodeAgoraScreenShareSignal(
          json({
            'version': 2,
            'topic': agoraScreenShareTopic,
            'message': 'started',
          }),
        ),
        null,
      );
      expect(
        decodeAgoraScreenShareSignal(
          json({'version': 1, 'topic': 'chat', 'message': 'started'}),
        ),
        null,
      );
      expect(
        decodeAgoraScreenShareSignal(
          json({
            'version': 1,
            'topic': agoraScreenShareTopic,
            'message': 'bad-status',
          }),
        ),
        null,
      );
      expect(decodeAgoraScreenShareSignal(Uint8List(1025)), null);
    });
  });

  group('remote screen publisher state', () {
    test('screen signalling is independent of camera video availability', () {
      final state = AgoraRemoteScreenState();
      state.onSignal(10, AgoraScreenShareSignal.started);
      expect(state.isScreenPublisher(10), isTrue);
      expect(state.showsCamera(10), isFalse);
      expect(state.showsScreen(10), isTrue);

      state.onVideo(10, available: true);
      expect(state.showsScreen(10), isTrue);
      expect(state.showsCamera(10), isFalse);

      // Switching camera off as screen capture starts must never remove
      // the independently published screen video.
      state.onVideo(10, available: false);
      expect(state.showsScreen(10), isTrue);
      expect(state.showsCamera(10), isFalse);

      state.onSignal(10, AgoraScreenShareSignal.stopped);
      expect(state.showsScreen(10), isFalse);
      expect(state.showsCamera(10), isFalse);
    });

    test(
      'leaving or rejoining cannot inherit a previous user screen state',
      () {
        final state = AgoraRemoteScreenState()
          ..onVideo(15, available: true)
          ..onSignal(15, AgoraScreenShareSignal.started);
        state.remove(15);
        state.onVideo(15, available: true);
        expect(state.showsCamera(15), isTrue);
        expect(state.showsScreen(15), isFalse);
        state.clear();
        expect(state.videoAvailable(15), isFalse);
      },
    );
  });
}
