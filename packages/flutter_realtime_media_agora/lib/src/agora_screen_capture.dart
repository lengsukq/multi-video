import 'package:agora_rtc_engine/agora_rtc_engine.dart' as agora;
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

/// Platform-specific screen capture is intentionally confined to the Agora
/// adapter. Flutter apps and the Demo only call the MediaSession abstraction.
class AgoraScreenCapture {
  const AgoraScreenCapture();

  Future<List<MediaScreenShareSource>> listSources(agora.RtcEngine engine) async {
    final sources = await engine.getScreenCaptureSources(
      thumbSize: const agora.SIZE(width: 160, height: 90),
      iconSize: const agora.SIZE(width: 32, height: 32),
      includeScreen: true,
    );
    return [
      for (final item in sources)
        if (item.sourceId != null &&
            (item.type ==
                    agora.ScreenCaptureSourceType.screencapturesourcetypeScreen ||
                item.type ==
                    agora.ScreenCaptureSourceType.screencapturesourcetypeWindow))
          MediaScreenShareSource(
            id: item.sourceId!.toString(),
            name: (item.sourceTitle?.trim().isNotEmpty ?? false)
                ? item.sourceTitle!
                : (item.sourceName?.trim().isNotEmpty ?? false)
                    ? item.sourceName!
                    : item.type ==
                            agora.ScreenCaptureSourceType.screencapturesourcetypeWindow
                        ? 'Window ${item.sourceId}'
                        : 'Display ${item.sourceId}',
            kind: item.type ==
                    agora.ScreenCaptureSourceType.screencapturesourcetypeWindow
                ? MediaScreenShareSourceKind.window
                : MediaScreenShareSourceKind.display,
            primary: item.primaryMonitor == true,
          ),
    ];
  }

  Future<void> start(
    agora.RtcEngine engine,
    TargetPlatform platform, {
    MediaScreenShareSource? selectedSource,
  }) async {
    switch (platform) {
      case TargetPlatform.android:
        await engine.startScreenCapture(
          const agora.ScreenCaptureParameters2(
            captureVideo: true,
            captureAudio: false,
          ),
        );
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        final sources = await listSources(engine);
        final displays = sources.where(
          (source) => source.kind == MediaScreenShareSourceKind.display,
        );
        if (displays.isEmpty && selectedSource == null) {
          throw const RealtimeException(
            code: RealtimeErrorCode.unsupportedFeature,
            providerId: 'agora',
            message:
                'Agora found no shareable display. '
                'Grant screen-recording permission and try again.',
          );
        }
        final primary = displays.where((display) => display.primary);
        final source = selectedSource ??
            (primary.isNotEmpty ? primary.first : displays.first);
        if (!sources.any((item) =>
            item.id == source.id && item.kind == source.kind)) {
          throw const RealtimeException(
            code: RealtimeErrorCode.invalidArgument,
            providerId: 'agora',
            message: 'The selected screen or window is no longer available.',
          );
        }
        final id = int.parse(source.id);
        const params = agora.ScreenCaptureParameters(
          frameRate: 10,
          captureMouseCursor: true,
        );
        if (source.kind == MediaScreenShareSourceKind.window) {
          await engine.startScreenCaptureByWindowId(
            windowId: id,
            regionRect: const agora.Rectangle(),
            captureParams: params,
          );
        } else {
          await engine.startScreenCaptureByDisplayId(
            displayId: id,
            regionRect: const agora.Rectangle(),
            captureParams: params,
          );
        }
      case TargetPlatform.iOS:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        throw const RealtimeException(
          code: RealtimeErrorCode.unsupportedFeature,
          providerId: 'agora',
          message:
              'This platform needs an Agora screen-capture integration '
              'that is not yet supplied by the Flutter adapter.',
        );
    }
  }

  Future<void> stop(agora.RtcEngine engine) => engine.stopScreenCapture();
}
