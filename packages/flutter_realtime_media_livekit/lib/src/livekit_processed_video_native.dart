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

/// Validate the native Flutter WebRTC descriptor before passing it to
/// MediaStreamNative.fromMap, which uses non-nullable String fields and
/// otherwise throws an unhelpful "Null is not a subtype of String".
Map<String, dynamic> checkedProcessedLiveKitStreamDescriptor(
  Map<String, dynamic>? map,
) {
  if (map == null) {
    throw StateError('The processed-video plugin did not create a stream.');
  }
  if (map['streamId'] is! String ||
      (map['streamId'] as String).isEmpty ||
      map['ownerTag'] is! String ||
      (map['ownerTag'] as String).isEmpty ||
      map['audioTracks'] is! List ||
      map['videoTracks'] is! List ||
      (map['videoTracks'] as List).length != 1) {
    throw StateError(
      'The processed-video plugin returned an invalid WebRTC stream '
      'descriptor (streamId, ownerTag, or videoTracks missing).',
    );
  }
  return map;
}

Future<lk.LocalVideoTrack> createProcessedLiveKitTrack(
  ProcessedVideoSource source, {
  bool screenShare = false,
}) async {
  final map = await _channel.invokeMapMethod<String, dynamic>('create', {
    'sourceId': source.id,
  });
  final stream = MediaStreamNative.fromMap(
    checkedProcessedLiveKitStreamDescriptor(map),
  );
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
