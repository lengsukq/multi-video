import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:dart_webrtc/dart_webrtc.dart';
import 'package:flutter_realtime_processed_video/flutter_realtime_processed_video.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:web/web.dart' as web;

@JS('RealtimeProcessedVideoBridge')
external JSObject get _bridge;

final Map<String, web.MediaStreamTrack> _clonedTracks =
    <String, web.MediaStreamTrack>{};

Future<lk.LocalVideoTrack> createProcessedLiveKitTrack(
  ProcessedVideoSource source, {
  bool screenShare = false,
}) async {
  _clonedTracks.remove(source.id)?.stop();
  final track = _bridge
      .callMethod<web.MediaStreamTrack>('getTrack'.toJS, source.id.toJS)
      .clone();
  _clonedTracks[source.id] = track;
  final stream = MediaStreamWeb(web.MediaStream([track].toJS), 'local');
  // Externally supplied tracks must not invoke camera capture.
  // ignore: invalid_use_of_internal_member
  return lk.LocalVideoTrack(
    lk.TrackSource.camera,
    stream,
    stream.getVideoTracks().single,
    const lk.CameraCaptureOptions(),
  );
}

Future<void> disposeProcessedLiveKitTrack(ProcessedVideoSource source) async {
  _clonedTracks.remove(source.id)?.stop();
}
