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
      return _WindowsChimeFrameView(
        key: ValueKey('windows-chime-${tile.tileId}'),
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
/// broadcast filtering.
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
  Uint8List? _frame;
  bool _bound = false;
  bool _binding = false;
  bool _painting = false;

  @override
  void initState() {
    super.initState();
    _subscription = _runtime.framesForView(_viewKey).listen(_onFrameEvent);
    _eventsSubscription = _runtime.events.listen(_onRuntimeEvent);
    unawaited(_bind());
  }

  void _onRuntimeEvent(Map<String, dynamic> event) {
    if (!mounted || _bound || _binding) return;
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
      if (!mounted) return;
      _painting = true;
      setState(() => _frame = bytes);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _painting = false;
      });
    } on FormatException {
      // A damaged frame is discarded; the next frame can recover.
    }
  }

  Future<void> _bind() async {
    if (_bound || _binding || !mounted) return;
    _binding = true;
    try {
      await _runtime.invoke(
        'bind',
        trackId: 'chime:tile:${widget.tile.tileId}',
        viewKey: _viewKey,
      );
      if (!mounted) {
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
    if (oldWidget.tile.tileId != widget.tile.tileId) {
      _bound = false;
      _frame = null;
      unawaited(
        _runtime
            .invoke('unbind', viewKey: _viewKey)
            .catchError((Object _) => null),
      );
      unawaited(_bind());
    }
  }

  @override
  void dispose() {
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    final eventsSubscription = _eventsSubscription;
    if (eventsSubscription != null) unawaited(eventsSubscription.cancel());
    unawaited(
      _runtime
          .invoke('unbind', viewKey: _viewKey)
          .catchError((Object _) => null),
    );
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
