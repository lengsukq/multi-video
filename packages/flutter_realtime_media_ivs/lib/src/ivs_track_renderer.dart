import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_macos_texture_view.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_webview2_runtime.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_processed_video/flutter_realtime_processed_video.dart';

import 'ivs_media_track.dart';

class IvsTrackRenderer extends MediaTrackRenderer {
  const IvsTrackRenderer();

  static const String viewType =
      'com.oneplusdream.flutter_realtime_media_ivs/video';

  @override
  bool handlesVideoFit(MediaVideoTrack track) {
    if (track is IvsMediaVideoTrack &&
        track.isLocal &&
        !track.isScreenShare &&
        track.processedSource != null) {
      return track.processedSource!.platform == ProcessedVideoPlatform.web;
    }
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows);
  }

  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      buildViewWithFit(context, track);

  @override
  Widget buildViewWithFit(
    BuildContext context,
    MediaVideoTrack track, {
    BoxFit fit = BoxFit.contain,
  }) {
    if (track is! IvsMediaVideoTrack) {
      throw ArgumentError.value(
        track,
        'track',
        'IvsTrackRenderer requires an IvsMediaVideoTrack.',
      );
    }
    if (track.isLocal &&
        !track.isScreenShare &&
        track.processedSource != null) {
      return const ProcessedVideoTrackRenderer().buildViewWithFit(
        context,
        ProcessedVideoTrack(source: track.processedSource!),
        fit: fit,
      );
    }
    final fitMode = fit == BoxFit.cover ? 'cover' : 'contain';
    final params = <String, Object?>{
      'userId': track.userId,
      'isLocal': track.isLocal,
      'generation': track.generation,
      'fit': fitMode,
    };
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => AndroidView(
        key: ValueKey('android-${track.id}-$fitMode'),
        viewType: viewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
      ),
      TargetPlatform.iOS => UiKitView(
        key: ValueKey('ios-${track.id}-$fitMode'),
        viewType: viewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
      ),
      TargetPlatform.macOS => AwsMacosTextureView.ivs(
        key: ValueKey('macos-${track.id}'),
        userId: track.userId,
        isLocal: track.isLocal,
        generation: track.generation,
        fit: fit,
      ),
      TargetPlatform.windows => _WindowsIvsFrameView(
        key: ValueKey(track.id),
        track: track,
        fit: fit,
      ),
      _ => const SizedBox.expand(),
    };
  }
}

/// Experimental IVS WebView2 frame path routed per viewKey.
class _WindowsIvsFrameView extends StatefulWidget {
  const _WindowsIvsFrameView({
    super.key,
    required this.track,
    this.fit = BoxFit.contain,
  });
  final IvsMediaVideoTrack track;
  final BoxFit fit;

  @override
  State<_WindowsIvsFrameView> createState() => _WindowsIvsFrameViewState();
}

class _WindowsIvsFrameViewState extends State<_WindowsIvsFrameView> {
  static int _nextViewId = 0;
  final _runtime = AwsWindowsWebView2Runtime.ivs;
  late final String _viewKey = 'ivs-view-${_nextViewId++}';
  StreamSubscription<Map<String, dynamic>>? _frames;
  StreamSubscription<Map<String, dynamic>>? _events;
  Uint8List? _frame;
  bool _bound = false;
  bool _binding = false;
  String? _boundJsTrackId;
  bool _painting = false;

  String get _lookupTrackId => widget.track.isLocal
      ? 'ivs:local-participant:${widget.track.userId}'
      : 'ivs:participant:${widget.track.userId}';

  @override
  void initState() {
    super.initState();
    _frames = _runtime.framesForView(_viewKey).listen(_onFrameEvent);
    _events = _runtime.events.listen(_onRuntimeEvent);
    unawaited(_bind());
  }

  String? _findCurrentJsTrackId(Map<String, dynamic> snapshot) {
    final rawTracks = snapshot['tracks'];
    if (rawTracks is! List) return null;
    for (final item in rawTracks) {
      if (item is! Map) continue;
      if (item['isScreenShare'] == true) continue;
      final isLocal = item['isLocal'] == true;
      final participantId = item['participantId']?.toString() ?? '';
      if (participantId == widget.track.userId &&
          isLocal == widget.track.isLocal) {
        return item['id']?.toString();
      }
    }
    return null;
  }

  void _onRuntimeEvent(Map<String, dynamic> event) {
    if (!mounted || event['type'] != 'snapshot') return;
    final currentJsId = _findCurrentJsTrackId(event);
    if (currentJsId == null) {
      _bound = false;
      _boundJsTrackId = null;
      return;
    }
    if (!_bound || (_boundJsTrackId != null && _boundJsTrackId != currentJsId)) {
      _bound = false;
      _boundJsTrackId = currentJsId;
      if (!_binding) unawaited(_bind(expectedJsId: currentJsId));
    }
  }

  @override
  void didUpdateWidget(covariant _WindowsIvsFrameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id != widget.track.id ||
        oldWidget.track.isLocal != widget.track.isLocal) {
      _bound = false;
      _boundJsTrackId = null;
      _frame = null;
      unawaited(
        _runtime
            .invoke('unbind', viewKey: _viewKey)
            .catchError((Object _) => null),
      );
      unawaited(_bind());
    }
  }

  void _onFrameEvent(Map<String, dynamic> event) {
    if (!mounted || _painting) return;
    final data = event['data'];
    if (data is! String || !data.startsWith('data:image/jpeg;base64,')) return;
    final encoded = data.substring('data:image/jpeg;base64,'.length);
    if (encoded.length > 1800000) return;
    try {
      final bytes = base64Decode(encoded);
      if (!mounted) return;
      _painting = true;
      setState(() => _frame = bytes);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _painting = false;
      });
    } on FormatException {
      // Drop a damaged frame rather than displaying corrupt pixels.
    }
  }

  Future<void> _bind({String? expectedJsId}) async {
    if (_bound || _binding || !mounted) return;
    _binding = true;
    try {
      await _runtime.invoke('bind', trackId: _lookupTrackId, viewKey: _viewKey);
      if (!mounted) {
        await _runtime.invoke('unbind', viewKey: _viewKey);
        return;
      }
      _bound = true;
      if (expectedJsId != null) _boundJsTrackId = expectedJsId;
    } catch (_) {
      // Automatically retried on the next snapshot update.
    } finally {
      _binding = false;
    }
  }

  @override
  void dispose() {
    unawaited(_frames?.cancel());
    unawaited(_events?.cancel());
    if (_bound) {
      unawaited(
        _runtime
            .invoke('unbind', viewKey: _viewKey)
            .catchError((Object _) => null),
      );
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
            fit: widget.fit,
            gaplessPlayback: true,
            width: double.infinity,
            height: double.infinity,
          ),
  );
}
