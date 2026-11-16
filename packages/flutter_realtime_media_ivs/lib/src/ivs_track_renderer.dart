import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_webview2_runtime.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'ivs_media_track.dart';

class IvsTrackRenderer extends MediaTrackRenderer {
  const IvsTrackRenderer();

  static const String viewType =
      'com.oneplusdream.flutter_realtime_media_ivs/video';

  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) {
    if (track is! IvsMediaVideoTrack) {
      throw ArgumentError.value(
        track,
        'track',
        'IvsTrackRenderer requires an IvsMediaVideoTrack.',
      );
    }
    final params = <String, Object?>{
      'userId': track.userId,
      'isLocal': track.isLocal,
      'generation': track.generation,
    };
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => AndroidView(
        viewType: viewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
      ),
      TargetPlatform.iOS => UiKitView(
        viewType: viewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
      ),
      TargetPlatform.macOS => AppKitView(
        viewType: viewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
      ),
      TargetPlatform.windows => _WindowsIvsFrameView(
        key: ValueKey(track.id),
        track: track,
      ),
      _ => const SizedBox.expand(),
    };
  }
}

/// Experimental IVS WebView2 frame path. This is JPEG transport, not a
/// native GPU texture; production/low-latency use needs a supported bridge.
class _WindowsIvsFrameView extends StatefulWidget {
  const _WindowsIvsFrameView({super.key, required this.track});
  final IvsMediaVideoTrack track;

  @override
  State<_WindowsIvsFrameView> createState() => _WindowsIvsFrameViewState();
}

class _WindowsIvsFrameViewState extends State<_WindowsIvsFrameView> {
  static int _nextViewId = 0;
  final _runtime = AwsWindowsWebView2Runtime.ivs;
  late final String _viewKey = 'ivs-view-${_nextViewId++}';
  StreamSubscription<Map<String, dynamic>>? _frames;
  Uint8List? _frame;
  bool _bound = false;

  @override
  void initState() {
    super.initState();
    _frames = _runtime.frames.listen((event) {
      if (!mounted || event['viewKey'] != _viewKey) return;
      final data = event['data'];
      if (data is! String || !data.startsWith('data:image/jpeg;base64,')) return;
      final encoded = data.substring('data:image/jpeg;base64,'.length);
      if (encoded.length > 1800000) return;
      try {
        final bytes = base64Decode(encoded);
        if (mounted) setState(() => _frame = bytes);
      } on FormatException {
        // Drop a damaged frame rather than displaying corrupt pixels.
      }
    });
    unawaited(_bind());
  }

  Future<void> _bind() async {
    if (_bound || !mounted) return;
    try {
      await _runtime.invoke(
        'bind',
        trackId: 'ivs:participant:${widget.track.userId}',
        viewKey: _viewKey,
      );
      if (!mounted) {
        await _runtime.invoke('unbind', viewKey: _viewKey);
        return;
      }
      _bound = true;
    } catch (_) {
      // A missing track must remain black, not become a success placeholder.
    }
  }

  @override
  void dispose() {
    unawaited(_frames?.cancel());
    if (_bound) {
      unawaited(_runtime.invoke('unbind', viewKey: _viewKey)
          .catchError((Object _) => null));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF000000),
    child: _frame == null
        ? const SizedBox.expand()
        : Image.memory(
            _frame!,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            width: double.infinity,
            height: double.infinity,
          ),
  );
}
