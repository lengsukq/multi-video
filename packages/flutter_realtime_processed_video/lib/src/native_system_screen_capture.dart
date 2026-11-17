import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

/// Shared native FrameHub screen capture channel client (iOS & Android).
abstract class NativeSystemScreenCaptureClient {
  NativeSystemScreenCaptureClient(
    this._channel,
    this._targetPlatform,
    this._expectedPlatform,
    this._methodPrefix,
    this._unsupportedMessage,
  ) {
    _channel.setMethodCallHandler(_handleCall);
  }

  final MethodChannel _channel;
  final TargetPlatform _targetPlatform;
  final ProcessedVideoPlatform _expectedPlatform;
  final String _methodPrefix;
  final String _unsupportedMessage;

  ProcessedVideoSource? _source;
  ProcessedVideoSource? get source => _source;
  Future<void> Function()? _onStopped;
  bool _starting = false;
  int _generation = 0;

  void onSystemStopped(Future<void> Function()? handler) {
    _onStopped = handler;
  }

  Future<bool> get isAvailable async {
    if (kIsWeb || defaultTargetPlatform != _targetPlatform) return false;
    try {
      return await _channel.invokeMethod<bool>('${_methodPrefix}Available') ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<ProcessedVideoSource> start() async {
    if (kIsWeb || defaultTargetPlatform != _targetPlatform) {
      throw UnsupportedError(_unsupportedMessage);
    }
    if (_starting || _source != null) {
      throw StateError('A screen capture is already active.');
    }
    _starting = true;
    final generation = ++_generation;
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        '${_methodPrefix}Start',
      );
      if (result == null) {
        throw StateError('Screen capture did not start.');
      }
      if (generation != _generation) {
        throw StateError('Screen capture was stopped while starting.');
      }
      final source = ProcessedVideoSource.fromJson(result);
      if (source.kind != ProcessedVideoSourceKind.nativeFrameHub ||
          source.platform != _expectedPlatform) {
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
    if (!kIsWeb && defaultTargetPlatform == _targetPlatform) {
      await _channel.invokeMethod<void>('${_methodPrefix}Stop');
    }
  }

  Future<void> _handleCall(MethodCall call) async {
    if (call.method != '${_methodPrefix}Ended') return;
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
