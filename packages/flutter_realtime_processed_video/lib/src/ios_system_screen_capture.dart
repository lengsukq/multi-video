import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

/// One shared native iOS 27+ ScreenCaptureKit source for all media providers.
///
/// Captured CVPixelBuffers stay inside the native FrameHub. Agora, TRTC, and
/// LiveKit attach their own provider-specific publishing sinks to [source].
/// It intentionally does not depend on a particular RTC provider.
class IosSystemScreenCapture {
  IosSystemScreenCapture._() {
    _channel.setMethodCallHandler(_handleCall);
  }

  static final IosSystemScreenCapture instance = IosSystemScreenCapture._();
  static const _channel = MethodChannel(
    'flutter_realtime_processed_video/ios_system_screen_capture',
  );

  ProcessedVideoSource? _source;
  ProcessedVideoSource? get source => _source;
  Future<void> Function()? _onStopped;
  bool _starting = false;
  int _generation = 0;

  void onSystemStopped(Future<void> Function()? handler) {
    _onStopped = handler;
  }

  Future<bool> get isAvailable async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'iosScreenCaptureKitAvailable',
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<ProcessedVideoSource> start() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      throw UnsupportedError('ScreenCaptureKit requires native iOS 27+.');
    }
    if (_starting || _source != null) {
      throw StateError('An iOS screen capture is already active.');
    }
    _starting = true;
    final generation = ++_generation;
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'iosScreenCaptureKitStart',
      );
      if (result == null) {
        throw StateError('ScreenCaptureKit did not start a capture.');
      }
      if (generation != _generation) {
        throw StateError('Screen capture was stopped while starting.');
      }
      final source = ProcessedVideoSource.fromJson(result);
      if (source.kind != ProcessedVideoSourceKind.nativeFrameHub ||
          source.platform != ProcessedVideoPlatform.ios) {
        throw StateError('Unexpected native screen capture source.');
      }
      _source = source;
      return source;
    } catch (_) {
      await stop();
      rethrow;
    } finally {
      _starting = false;
    }
  }

  Future<void> stop() async {
    ++_generation;
    _source = null;
    _onStopped = null;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      await _channel.invokeMethod<void>('iosScreenCaptureKitStop');
    }
  }

  Future<void> _handleCall(MethodCall call) async {
    if (call.method != 'iosScreenCaptureKitEnded') return;
    final source = _source;
    final arguments = call.arguments;
    if (source == null ||
        arguments is! Map ||
        arguments['sourceId'] != source.id) {
      // A late stop notification from an earlier capture must not terminate
      // the current meeting's new screen-share source.
      return;
    }
    ++_generation;
    _source = null;
    final handler = _onStopped;
    _onStopped = null;
    if (handler != null) await handler();
  }
}
