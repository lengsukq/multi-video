import 'package:flutter/services.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'native_system_screen_capture.dart';

/// Shared native Android MediaProjection screen capture source.
///
/// Captured RGBA frames stay inside [ProcessedVideoFrameHub]. Providers
/// attach their own publishing sinks to [source].
class AndroidSystemScreenCapture extends NativeSystemScreenCaptureClient {
  AndroidSystemScreenCapture._()
    : super(
        const MethodChannel(
          'flutter_realtime_processed_video/android_system_screen_capture',
        ),
        TargetPlatform.android,
        ProcessedVideoPlatform.android,
        'androidScreenCapture',
        'Android screen capture requires native Android.',
      );

  static final AndroidSystemScreenCapture instance =
      AndroidSystemScreenCapture._();
}
