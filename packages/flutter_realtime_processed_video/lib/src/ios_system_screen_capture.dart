import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'native_system_screen_capture.dart';

/// Describes which iOS screen capture backend will be used by [IosSystemScreenCapture].
class IosScreenCaptureConfiguration {
  const IosScreenCaptureConfiguration({
    required this.captureBackend,
    required this.crossAppSupported,
    required this.broadcastExtensionConfigured,
    this.appGroup = '',
    this.extensionId = '',
  });

  /// One of `'screenCaptureKit'` (iOS 27+), `'broadcastExtension'` (iOS 15–26
  /// with signed ReplayKit `.appex` and App Group), `'inAppReplayKit'`, or
  /// `'unavailable'`.
  final String captureBackend;
  final bool crossAppSupported;
  final bool broadcastExtensionConfigured;
  final String appGroup;
  final String extensionId;

  factory IosScreenCaptureConfiguration.fromMap(Map<Object?, Object?> raw) {
    final backend = raw['captureBackend']?.toString() ?? 'unavailable';
    return IosScreenCaptureConfiguration(
      captureBackend: backend,
      crossAppSupported: raw['crossAppSupported'] == true,
      broadcastExtensionConfigured: raw['configured'] == true,
      appGroup: raw['appGroup']?.toString() ?? '',
      extensionId: raw['extensionId']?.toString() ?? '',
    );
  }
}

/// Shared native iOS screen capture source for all media providers.
///
/// Uses `ScreenCaptureKit` on iOS 27+, a signed ReplayKit Broadcast Upload
/// Extension (`rtc_SSFD` App Group socket) on iOS 15–26 when configured on the
/// host target, and falls back to `RPScreenRecorder` in-app capture otherwise.
/// Captured `CVPixelBuffer`s stay inside the native FrameHub.
class IosSystemScreenCapture extends NativeSystemScreenCaptureClient {
  IosSystemScreenCapture._()
    : super(
        _iosCaptureChannel,
        TargetPlatform.iOS,
        ProcessedVideoPlatform.ios,
        'iosScreenCaptureKit',
        'iOS screen capture requires native iOS.',
      );

  static const _iosCaptureChannel = MethodChannel(
    'flutter_realtime_processed_video/ios_system_screen_capture',
  );

  static final IosSystemScreenCapture instance = IosSystemScreenCapture._();

  /// Queries the active iOS screen-capture backend and Broadcast Extension readiness.
  Future<IosScreenCaptureConfiguration> configuration() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return const IosScreenCaptureConfiguration(
        captureBackend: 'unavailable',
        crossAppSupported: false,
        broadcastExtensionConfigured: false,
      );
    }
    try {
      final raw = await _iosCaptureChannel.invokeMapMethod<Object?, Object?>(
        'iosScreenCaptureConfiguration',
      );
      if (raw == null) {
        return const IosScreenCaptureConfiguration(
          captureBackend: 'unavailable',
          crossAppSupported: false,
          broadcastExtensionConfigured: false,
        );
      }
      return IosScreenCaptureConfiguration.fromMap(raw);
    } on MissingPluginException {
      return const IosScreenCaptureConfiguration(
        captureBackend: 'unavailable',
        crossAppSupported: false,
        broadcastExtensionConfigured: false,
      );
    } on PlatformException {
      return const IosScreenCaptureConfiguration(
        captureBackend: 'unavailable',
        crossAppSupported: false,
        broadcastExtensionConfigured: false,
      );
    }
  }
}
