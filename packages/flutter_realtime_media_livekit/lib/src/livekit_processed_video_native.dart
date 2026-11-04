import 'package:flutter/services.dart';
import 'package:flutter_realtime_processed_video/flutter_realtime_processed_video.dart';
// The plugin returns a registered native stream descriptor; FlutterWebRTC
// currently exposes its descriptor wrapper through this implementation file.
// ignore: implementation_imports
import 'package:flutter_webrtc/src/native/media_stream_impl.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

const _channel = MethodChannel(
  'flutter_realtime_media_livekit/processed_video',
);
Future<lk.LocalVideoTrack> createProcessedLiveKitTrack(
  ProcessedVideoSource source, {
  bool screenShare = false,
}) async {
  final map = await _channel.invokeMapMethod<String, dynamic>('create', {
    'sourceId': source.id,
  });
  if (map == null) throw StateError('No WebRTC track was created.');
  final stream = MediaStreamNative.fromMap(map);
  // Externally supplied tracks must not invoke camera capture.
  // ignore: invalid_use_of_internal_member
  return lk.LocalVideoTrack(
    screenShare ? lk.TrackSource.screenShareVideo : lk.TrackSource.camera,
    stream,
    stream.getVideoTracks().single,
    screenShare
        ? const lk.ScreenShareCaptureOptions(useiOSBroadcastExtension: false)
        : const lk.CameraCaptureOptions(),
  );
}

Future<void> disposeProcessedLiveKitTrack(ProcessedVideoSource source) =>
    _channel.invokeMethod<void>('dispose', {'sourceId': source.id});
