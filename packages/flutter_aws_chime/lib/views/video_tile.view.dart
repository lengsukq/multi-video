import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';
import 'package:flutter_realtime_foundation/flutter_realtime_foundation.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_macos_texture_view.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_webview2_runtime.dart';

import '../models/meeting_snapshot.dart';

/// Renders one AWS Chime video tile on iOS, Android, macOS, or experimental Windows.
class MeetingVideoTileView extends StatelessWidget {
  const MeetingVideoTileView({
    super.key,
    required this.tile,
    this.fit = BoxFit.contain,
  });

  final MeetingVideoTile tile;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.macOS &&
            defaultTargetPlatform != TargetPlatform.windows)) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Text(
            'Chime video is unavailable on this platform.',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }

    if (defaultTargetPlatform == TargetPlatform.windows) {
      final viewIdentity = tile.isContentShare && tile.isLocal
          ? 'local-screen-${tile.attendeeId}'
          : '${tile.tileId}';
      return _WindowsChimeFrameView(
        key: ValueKey('windows-chime-$viewIdentity'),
        tile: tile,
        fit: fit,
      );
    }

    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return AwsMacosTextureView.chime(
        key: ValueKey('macos-chime-${tile.tileId}'),
        tileId: tile.tileId,
        initialWidth: tile.width,
        initialHeight: tile.height,
        fit: fit,
      );
    }

    final fitMode = fit == BoxFit.cover ? 'cover' : 'contain';
    final creationParams = <String, Object?>{
      'tileId': tile.tileId,
      'fit': fitMode,
      if (defaultTargetPlatform == TargetPlatform.android &&
          tile.isLocal &&
          !tile.isContentShare)
        'isLocal': true,
    };

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        key: ValueKey('ios-chime-${tile.tileId}-$fitMode'),
        viewType: 'videoTile',
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }

    return PlatformViewLink(
      key: ValueKey('android-chime-${tile.tileId}-$fitMode'),
      viewType: 'videoTile',
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
      ),
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: 'videoTile',
          layoutDirection: TextDirection.ltr,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        );
        controller.addOnPlatformViewCreatedListener(
          params.onPlatformViewCreated,
        );
        observeDetached(controller.create());
        return controller;
      },
    );
  }
}

/// Provisional frame renderer matching the desktop WebView2 JPEG frame event
/// contract. Subscribes to per-viewKey frame routing rather than O(N^2) global
/// broadcast filtering, and reads local screen-share frames directly from the
/// native Win32 screen-capture stream without an offscreen WebView2 round-trip.
class _WindowsChimeFrameView extends StatefulWidget {
  const _WindowsChimeFrameView({
    super.key,
    required this.tile,
    this.fit = BoxFit.contain,
  });
  final MeetingVideoTile tile;
  final BoxFit fit;

  @override
  State<_WindowsChimeFrameView> createState() => _WindowsChimeFrameViewState();
}

class _WindowsChimeFrameViewState extends State<_WindowsChimeFrameView> {
  static int _nextViewId = 0;
  final _runtime = AwsWindowsWebView2Runtime.instance;
  late final String _viewKey =
      'aws-chime-${widget.tile.tileId}-${_nextViewId++}';
  StreamSubscription<Map<String, dynamic>>? _subscription;
  StreamSubscription<Map<String, dynamic>>? _eventsSubscription;
  StreamSubscription<Uint8List>? _localScreenSubscription;
  Uint8List? _frame;
  bool _bound = false;
  bool _binding = false;
  bool _painting = false;

  bool get _usesDirectLocalScreenFrames =>
      widget.tile.isContentShare && widget.tile.isLocal;

  @override
  void initState() {
    super.initState();
    _attachSource();
  }

  void _attachSource() {
    if (_usesDirectLocalScreenFrames) {
      _frame = _runtime.latestLocalScreenFrame;
      _localScreenSubscription = _runtime.localScreenFrames.listen(
        _paintFrameBytes,
      );
      return;
    }
    _subscription = _runtime.framesForView(_viewKey).listen(_onFrameEvent);
    _eventsSubscription = _runtime.events.listen(_onRuntimeEvent);
    unawaited(_bind());
  }

  void _detachSource() {
    final localSub = _localScreenSubscription;
    _localScreenSubscription = null;
    if (localSub != null) unawaited(localSub.cancel());
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    final eventsSubscription = _eventsSubscription;
    _eventsSubscription = null;
    if (eventsSubscription != null) unawaited(eventsSubscription.cancel());
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

  void _onRuntimeEvent(Map<String, dynamic> event) {
    if (!mounted || _usesDirectLocalScreenFrames || _bound || _binding) return;
    if (event['type'] == 'snapshot') {
      unawaited(_bind());
    }
  }

  void _onFrameEvent(Map<String, dynamic> event) {
    if (!mounted || _painting) return;
    final encoded = event['data'];
    if (encoded is! String || !encoded.startsWith('data:image/jpeg;base64,')) {
      return;
    }
    try {
      final raw = encoded.substring('data:image/jpeg;base64,'.length);
      // Bound frame copies to protect Flutter's image decoder.
      if (raw.length > 1800000) return;
      final bytes = base64Decode(raw);
      _paintFrameBytes(bytes);
    } on FormatException {
      // A damaged frame is discarded; the next frame can recover.
    }
  }

  String get _lookupTrackId {
    if (widget.tile.isContentShare) {
      return widget.tile.isLocal
          ? 'chime:local-screen:${widget.tile.attendeeId}'
          : 'chime:remote-screen:${widget.tile.attendeeId}';
    }
    return 'chime:tile:${widget.tile.tileId}';
  }

  Future<void> _bind() async {
    if (_usesDirectLocalScreenFrames || _bound || _binding || !mounted) return;
    _binding = true;
    try {
      await _runtime.invoke('bind', trackId: _lookupTrackId, viewKey: _viewKey);
      if (!mounted || _usesDirectLocalScreenFrames) {
        await _runtime.invoke('unbind', viewKey: _viewKey);
        return;
      }
      _bound = true;
    } catch (_) {
      // Retry automatically when the next snapshot event arrives.
    } finally {
      _binding = false;
    }
  }

  @override
  void didUpdateWidget(covariant _WindowsChimeFrameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldDirect = oldWidget.tile.isContentShare && oldWidget.tile.isLocal;
    if (oldDirect != _usesDirectLocalScreenFrames ||
        (!_usesDirectLocalScreenFrames &&
            oldWidget.tile.tileId != widget.tile.tileId) ||
        oldWidget.tile.isContentShare != widget.tile.isContentShare ||
        oldWidget.tile.isLocal != widget.tile.isLocal ||
        oldWidget.tile.attendeeId != widget.tile.attendeeId) {
      _detachSource();
      _frame = null;
      _attachSource();
    }
  }

  @override
  void dispose() {
    _detachSource();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
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
