import 'dart:convert';
import 'dart:typed_data';

/// Private SDK protocol used only for remote video-source classification.
/// It deliberately isn't an end-user chat message or a Demo-defined event.
enum AgoraScreenShareSignal { started, stopped }

const agoraScreenShareTopic = '_flutter_realtime.screen_share.v1';

Uint8List encodeAgoraScreenShareSignal(
  AgoraScreenShareSignal state, {
  int? timestampMs,
}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'version': 1,
      'topic': agoraScreenShareTopic,
      'message': state.name,
      'timestampMs': timestampMs ?? DateTime.now().millisecondsSinceEpoch,
    }),
  ),
);

/// Returns null for non-protocol messages and malformed/unrecognized payloads.
AgoraScreenShareSignal? decodeAgoraScreenShareSignal(Uint8List bytes) {
  if (bytes.length > 1024) return null;
  try {
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic> ||
        data['version'] != 1 ||
        data['topic'] != agoraScreenShareTopic) {
      return null;
    }
    return switch (data['message']) {
      'started' => AgoraScreenShareSignal.started,
      'stopped' => AgoraScreenShareSignal.stopped,
      _ => null,
    };
  } on FormatException {
    return null;
  }
}

/// Tracks media availability independently from the arrival order of metadata.
///
/// A signal can arrive before the first frame, and a video stream can be
/// unpublished and then republished when a presenter switches video sources.
class AgoraRemoteScreenState {
  final Set<int> _available = {};
  final Set<int> _screenPublishers = {};

  bool videoAvailable(int uid) => _available.contains(uid);
  bool isScreenPublisher(int uid) => _screenPublishers.contains(uid);
  bool showsCamera(int uid) => videoAvailable(uid) && !isScreenPublisher(uid);
  // Screen capture is a separate Agora video source. Camera mute/stopped
  // callbacks do not imply that a published screen stream has disappeared.
  // A confirmed start signal is sufficient to expose the remote screen
  // renderer; its frame arrives asynchronously through the RTC video source.
  bool showsScreen(int uid) => isScreenPublisher(uid);

  void onVideo(int uid, {required bool available}) {
    if (available) {
      _available.add(uid);
    } else {
      _available.remove(uid);
    }
  }

  void onSignal(int uid, AgoraScreenShareSignal state) {
    if (state == AgoraScreenShareSignal.started) {
      _screenPublishers.add(uid);
    } else {
      _screenPublishers.remove(uid);
    }
  }

  void remove(int uid) {
    _available.remove(uid);
    _screenPublishers.remove(uid);
  }

  void clear() {
    _available.clear();
    _screenPublishers.clear();
  }
}
