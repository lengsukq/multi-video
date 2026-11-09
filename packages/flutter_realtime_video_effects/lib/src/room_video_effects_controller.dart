import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_realtime_video_effects/flutter_realtime_video_effects.dart';

/// Owns the single processed source and serializes source/publication changes.
class RoomVideoEffectsController
    implements RealtimeVideoEffectsController, RealtimeCameraEffectsController {
  RoomVideoEffectsController({
    required this.media,
    required this.providerId,
    required this.effectsCapabilities,
    required void Function(RealtimeException) onFailure,
    VideoEffectsBridge? bridge,
  }) : _videoEffectsBridge = bridge ?? VideoEffectsBridge() {
    _failures = _videoEffectsBridge.failures.listen((failure) {
      if (!_disposed && failure.sourceId == _processedVideoSource?.id) {
        onFailure(
          RealtimeException(
            code: RealtimeErrorCode.providerError,
            message: 'videoEffects.processFrame failed.',
            providerId: providerId,
            domain: 'videoEffects',
            operation: 'processFrame',
            cause: failure.message,
            suggestedAction: 'reset-background-effect',
          ),
        );
        unawaited(
          _serializeVideoOperation(() async {
            final active = media.session;
            if (active is InteractiveMediaSession &&
                active.snapshot.localVideoEnabled) {
              await active.setVideoEnabled(false);
            }
          }).catchError((Object error, StackTrace stack) {
            if (!_disposed) {
              onFailure(
                normalizeRealtimeException(
                  error,
                  domain: 'videoEffects',
                  operation: 'stopPublication',
                  providerId: providerId,
                  stackTrace: stack,
                ),
              );
            }
          }),
        );
      }
    });
  }
  final MediaRoomSession media;
  final String providerId;
  final MediaBackgroundCapabilities effectsCapabilities;
  final VideoEffectsBridge _videoEffectsBridge;
  StreamSubscription<VideoEffectsFailure>? _failures;
  Future<void> _videoOperation = Future<void>.value();
  Future<void>? _disposeFuture;
  bool _disposed = false;
  ProcessedVideoSource? _processedVideoSource;
  MediaBackgroundEffect _processedBackgroundEffect =
      const MediaBackgroundEffect.none();

  @override
  MediaBackgroundCapabilities get backgroundCapabilities {
    final active = media.session;
    final native = active is ProcessedVideoSink
        ? MediaBackgroundCapabilities(
            canBlur: active.capabilities.canBlurBackground,
            canReplaceImage: active.capabilities.canReplaceBackgroundImage,
          )
        : media.backgroundCapabilities;
    return MediaBackgroundCapabilities(
      canBlur: native.canBlur && effectsCapabilities.canBlur,
      canReplaceImage:
          native.canReplaceImage && effectsCapabilities.canReplaceImage,
    );
  }

  @override
  MediaBackgroundEffect get backgroundEffect => _processedVideoSource != null
      ? _processedBackgroundEffect
      : media.backgroundEffect;

  @override
  Future<void> prepareVideoEffects(MediaLocalPreviewSettings settings) =>
      _serializeVideoOperation(
        () => _prepareVideoEffects(settings),
        operation: 'prepareVideoEffects',
      );

  @override
  Future<void> setCameraEnabled(bool enabled) =>
      _serializeVideoOperation(() async {
        if (_disposed) {
          throw RealtimeException(
            code: RealtimeErrorCode.invalidState,
            message: 'The room has been disposed.',
            providerId: providerId,
          );
        }
        final active = media.session;
        if (active is! InteractiveMediaSession ||
            !active.capabilities.canPublishVideo) {
          throw RealtimeException(
            code: RealtimeErrorCode.unsupportedFeature,
            message: 'Camera publishing is unavailable for this room.',
            providerId: providerId,
          );
        }

        final source = _processedVideoSource;
        if (!enabled) {
          // Stop provider publication first, then stop the camera capture.
          await active.setVideoEnabled(false);
          if (source != null) {
            await _videoEffectsBridge.setEnabled(source, false);
          }
          return;
        }

        // Source capture must be running before the provider publishes an
        // already attached source. A previously closed camera is the case
        // where merely setting the provider's video flag can be black.
        if (source != null) {
          await _videoEffectsBridge.setEnabled(source, true);
        }
        try {
          await active.setVideoEnabled(true);
        } catch (_) {
          // Never leave the processed camera capturing after a failed
          // publish. The caller still receives the original error.
          if (source != null) {
            try {
              await _videoEffectsBridge.setEnabled(source, false);
            } catch (_) {
              // Preserve the actual publish failure.
            }
          }
          rethrow;
        }
      }, operation: enabled ? 'enableCamera' : 'disableCamera');

  Future<void> _prepareVideoEffects(MediaLocalPreviewSettings settings) async {
    final active = media.session;
    final publisher = active is InteractiveMediaSession ? active : null;
    final protectPublishing =
        !_disposed &&
        settings.backgroundEffect.enabled &&
        publisher != null &&
        active.snapshot.localVideoEnabled;
    // Hold camera publication until the selected protection is ready. Failure
    // deliberately leaves publication disabled; there is no raw-camera fallback.
    if (protectPublishing) await publisher.setVideoEnabled(false);
    await _prepareVideoEffectsSource(settings);
    if (protectPublishing && settings.cameraEnabled && !_disposed) {
      await publisher.setVideoEnabled(true);
    }
  }

  Future<void> _prepareVideoEffectsSource(
    MediaLocalPreviewSettings settings,
  ) async {
    if (_disposed) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'The room has been disposed.',
        providerId: providerId,
      );
    }
    final active = media.session;
    if (!active.capabilities.canPublishVideo) {
      if (settings.backgroundEffect.enabled) _unsupportedBackground();
      return;
    }
    if (active is! ProcessedVideoSink) {
      if (settings.backgroundEffect.enabled) {
        await media.setBackgroundEffect(settings.backgroundEffect);
      }
      return;
    }
    final sink = active as ProcessedVideoSink;
    // A room without a selected virtual background must publish through the
    // provider's normal camera path. Eagerly attaching a canvas-processed
    // source here makes the Pre-Join camera work but can prevent Web camera
    // publication after joining, even though the user selected no effect.
    // The source is created later, when blur or image replacement is chosen.
    if (!settings.backgroundEffect.enabled && _processedVideoSource == null) {
      return;
    }
    if (!backgroundCapabilities.supports(settings.backgroundEffect)) {
      _unsupportedBackground();
    }
    // Platforms reserved for future bridges retain their normal camera path
    // when effects are off. They must never advertise an enabled effect.
    if (!backgroundCapabilities.isSupported ||
        !await _supportsEffectsRuntime()) {
      if (settings.backgroundEffect.enabled) _unsupportedBackground();
      return;
    }

    var source = _processedVideoSource;
    if (source == null) {
      source = await _videoEffectsBridge.createSource(
        config: VideoEffectsSourceConfig(
          frameRate: 30,
          cameraDeviceId: settings.camera?.id,
          effect: settings.backgroundEffect,
        ),
      );
      if (_disposed) {
        await _videoEffectsBridge.disposeSource(source);
        throw RealtimeException(
          code: RealtimeErrorCode.invalidState,
          providerId: providerId,
          message: 'The room has been disposed.',
        );
      }
      if (!sink.supportsProcessedVideoSource(source)) {
        await _videoEffectsBridge.disposeSource(source);
        if (settings.backgroundEffect.enabled) _unsupportedBackground();
        return;
      }
      try {
        // Bind while muted so a disabled camera cannot briefly publish frames.
        await _videoEffectsBridge.setEnabled(source, false);
        await sink.attachProcessedVideoSource(source);
        if (_disposed) {
          throw const RealtimeException(
            code: RealtimeErrorCode.invalidState,
            message: 'The video source owner is closing.',
          );
        }
      } catch (error, stack) {
        final cleanup = Cleanup();
        await cleanup.run(
          'video.sink.rollback',
          sink.detachProcessedVideoSource,
        );
        await cleanup.run(
          'video.source.rollback',
          () => _videoEffectsBridge.disposeSource(source!),
        );
        cleanup.finish(
          domain: 'videoEffects',
          cause: normalizeRealtimeException(
            error,
            domain: 'videoEffects',
            operation: 'attach',
            stackTrace: stack,
          ),
        );
        if (_isUnavailableBridge(error)) {
          if (!settings.backgroundEffect.enabled) return;
          _unsupportedBackground();
        }
        rethrow;
      }
      _processedVideoSource = source;
    } else {
      if (settings.camera != null) {
        await _videoEffectsBridge.selectCamera(source, settings.camera!.id);
      }
      await _videoEffectsBridge.setEffect(source, settings.backgroundEffect);
    }
    await _videoEffectsBridge.setEnabled(source, settings.cameraEnabled);
    _processedBackgroundEffect = settings.backgroundEffect;
  }

  Future<bool> _supportsEffectsRuntime() async {
    try {
      return await _videoEffectsBridge.isSupported();
    } catch (error) {
      if (_isUnavailableBridge(error)) return false;
      rethrow;
    }
  }

  bool _isUnavailableBridge(Object error) =>
      error is MissingPluginException ||
      (error is RealtimeException &&
          error.code == RealtimeErrorCode.unsupportedFeature) ||
      (error is PlatformException &&
          (error.code.toLowerCase().contains('unsupported') ||
              error.code == 'not_implemented'));

  Never _unsupportedBackground() => throw RealtimeException(
    code: RealtimeErrorCode.unsupportedFeature,
    message:
        'The active provider cannot publish this background effect '
        'on this platform.',
    providerId: media.providerId,
  );

  Future<void> _serializeVideoOperation(
    Future<void> Function() action, {
    String operation = 'update',
  }) {
    final pending = _videoOperation.then((_) async {
      try {
        await action();
      } on MissingPluginException catch (error) {
        assert(() {
          debugPrint('[videoEffects/$operation] missing plugin: $error');
          return true;
        }());
        throw RealtimeException(
          code: RealtimeErrorCode.unsupportedFeature,
          providerId: providerId,
          message: 'The video-effects bridge is unavailable.',
          details: error,
        );
      } on PlatformException catch (error) {
        assert(() {
          debugPrint('[videoEffects/$operation] native error '
              'code=${error.code} message=${error.message}');
          return true;
        }());
        final code = error.code.toLowerCase();
        throw RealtimeException(
          code: _isUnavailableBridge(error)
              ? RealtimeErrorCode.unsupportedFeature
              : code.contains('invalid')
              ? RealtimeErrorCode.invalidArgument
              : code.contains('permission') || code.contains('denied')
              ? RealtimeErrorCode.permissionDenied
              : RealtimeErrorCode.providerError,
          providerId: providerId,
          domain: 'videoEffects',
          operation: operation,
          message: error.message ?? 'Video processing failed.',
          details: error,
        );
      } catch (error, stack) {
        assert(() {
          debugPrint('[videoEffects/$operation] ${error.runtimeType}: $error');
          debugPrint('[videoEffects/$operation] $stack');
          return true;
        }());
        Error.throwWithStackTrace(
          normalizeRealtimeException(
            error,
            domain: 'videoEffects',
            operation: operation,
            providerId: providerId,
            stackTrace: stack,
          ),
          stack,
        );
      }
    });
    _videoOperation = pending.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return pending;
  }

  @override
  Future<void> setBackgroundEffect(MediaBackgroundEffect effect) =>
      _serializeVideoOperation(() async {
        if (media.session is ProcessedVideoSink) {
          await _prepareVideoEffects(
            MediaLocalPreviewSettings(
              cameraEnabled: media.session.snapshot.localVideoEnabled,
              backgroundEffect: effect,
            ),
          );
          return;
        }
        await media.setBackgroundEffect(effect);
      }, operation: 'setBackgroundEffect');

  Future<void> _disposeProcessedVideoSource() async {
    final source = _processedVideoSource;
    _processedVideoSource = null;
    if (source == null) return;
    final active = media.session;
    try {
      final ProcessedVideoSink? sink = active is ProcessedVideoSink
          ? active as ProcessedVideoSink
          : null;
      if (sink != null) {
        await sink.detachProcessedVideoSource();
      }
    } finally {
      await _videoEffectsBridge.disposeSource(source);
      _processedBackgroundEffect = const MediaBackgroundEffect.none();
    }
  }

  @override
  Future<void> release() =>
      _serializeVideoOperation(
        _disposeProcessedVideoSource,
        operation: 'releaseSource',
      );

  /// Invalidate in-flight creation synchronously when the owning room starts
  /// disposal. Room cleanup may first await recording/annotation resources,
  /// but no source may be attached during that interval.
  @override
  void beginDisposal() {
    _disposed = true;
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();
  Future<void> _dispose() async {
    _disposed = true;
    final cleanup = Cleanup();
    await cleanup.run('video.operations', () => _videoOperation);
    await cleanup.run('video.failures', () async {
      await _failures?.cancel();
    });
    await cleanup.run('video.source', _disposeProcessedVideoSource);
    cleanup.finish(domain: 'videoEffects');
  }
}
