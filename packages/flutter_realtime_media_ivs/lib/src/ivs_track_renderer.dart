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
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
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
      'isScreenShare': track.isScreenShare,
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
        isScreenShare: track.isScreenShare,
        generation: track.generation,
        fit: fit,
      ),
      TargetPlatform.windows => _WindowsIvsFrameView(
        key: ValueKey(
          track.isScreenShare && track.isLocal
              ? 'ivs-local-screen-${track.userId}'
              : track.id,
        ),
        track: track,
        fit: fit,
      ),
      _ => const SizedBox.expand(),
    };
  }
}

/// Experimental IVS WebView2 frame path routed per viewKey, with direct native
/// frame rendering for local Windows screen sharing.
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
  StreamSubscription<Uint8List>? _localScreenFrames;
  Uint8List? _frame;
  bool _bound = false;
  bool _binding = false;
  String? _boundJsTrackId;
  bool _painting = false;

  bool get _usesDirectLocalScreenFrames =>
      widget.track.isScreenShare && widget.track.isLocal;

  String get _lookupTrackId {
    if (widget.track.isScreenShare) {
      return widget.track.isLocal
          ? 'ivs:local-screen:${widget.track.userId}'
          : 'ivs:screen-participant:${widget.track.userId}';
    }
    return widget.track.isLocal
        ? 'ivs:local-participant:${widget.track.userId}'
        : 'ivs:participant:${widget.track.userId}';
  }

  @override
  void initState() {
    super.initState();
    _attachSource();
  }

  void _attachSource() {
    if (_usesDirectLocalScreenFrames) {
      _frame = _runtime.latestLocalScreenFrame;
      _localScreenFrames = _runtime.localScreenFrames.listen(_paintFrameBytes);
      return;
    }
    _frames = _runtime.framesForView(_viewKey).listen(_onFrameEvent);
    _events = _runtime.events.listen(_onRuntimeEvent);
    unawaited(_bind());
  }

  void _detachSource() {
    final localSub = _localScreenFrames;
    _localScreenFrames = null;
    if (localSub != null) unawaited(localSub.cancel());
    final framesSub = _frames;
    _frames = null;
    if (framesSub != null) unawaited(framesSub.cancel());
    final eventsSub = _events;
    _events = null;
    if (eventsSub != null) unawaited(eventsSub.cancel());
    _boundJsTrackId = null;
    if (_bound || _binding) {
      _bound = false;
      unawaited(
        _runtime
            .invoke('unbind', viewKey: _viewKey)
            .catchError((Object _) => null),
      );
    }
  }

  void _paintFrameBytes(Uint8List bytes) {
    if (!mounted || _painting) return;
    _painting = true;
    setState(() => _frame = bytes);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _painting = false;
    });
  }

  String? _findCurrentJsTrackId(Map<String, dynamic> snapshot) {
    final rawTracks = snapshot['tracks'];
    if (rawTracks is! List) return null;
    for (final item in rawTracks) {
      if (item is! Map) continue;
      final isScreen = item['isScreenShare'] == true;
      if (isScreen != widget.track.isScreenShare) continue;
      final isLocal = item['isLocal'] == true;
      if (isLocal != widget.track.isLocal) continue;
      final participantId = item['participantId']?.toString() ?? '';
      final matchesUser = widget.track.isScreenShare && !widget.track.isLocal
          ? (participantId == widget.track.userId ||
                participantId == '${widget.track.userId}#content')
          : participantId == widget.track.userId;
      if (matchesUser) {
        return item['id']?.toString();
      }
    }
    return null;
  }

  void _onRuntimeEvent(Map<String, dynamic> event) {
    if (!mounted ||
        _usesDirectLocalScreenFrames ||
        event['type'] != 'snapshot') {
      return;
    }
    final currentJsId = _findCurrentJsTrackId(event);
    if (currentJsId == null) {
      _bound = false;
      _boundJsTrackId = null;
      return;
    }
    if (!_bound ||
        (_boundJsTrackId != null && _boundJsTrackId != currentJsId)) {
      _bound = false;
      _boundJsTrackId = currentJsId;
      if (!_binding) unawaited(_bind(expectedJsId: currentJsId));
    }
  }

  @override
  void didUpdateWidget(covariant _WindowsIvsFrameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldDirect = oldWidget.track.isScreenShare && oldWidget.track.isLocal;
    if (oldDirect != _usesDirectLocalScreenFrames ||
        (!_usesDirectLocalScreenFrames &&
            oldWidget.track.id != widget.track.id) ||
        oldWidget.track.userId != widget.track.userId ||
        oldWidget.track.isLocal != widget.track.isLocal ||
        oldWidget.track.isScreenShare != widget.track.isScreenShare) {
      _detachSource();
      _frame = null;
      _attachSource();
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
      _paintFrameBytes(bytes);
    } on FormatException {
      // Drop a damaged frame rather than displaying corrupt pixels.
    }
  }

  Future<void> _bind({String? expectedJsId}) async {
    if (_usesDirectLocalScreenFrames || _bound || _binding || !mounted) return;
    _binding = true;
    try {
      await _runtime.invoke(
        'bind',
        trackId: expectedJsId ?? _lookupTrackId,
        viewKey: _viewKey,
      );
      if (!mounted || _usesDirectLocalScreenFrames) {
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
    _detachSource();
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
