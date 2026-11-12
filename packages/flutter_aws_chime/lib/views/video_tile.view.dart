import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_realtime_foundation/flutter_realtime_foundation.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_webview2_runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import '../models/meeting_snapshot.dart';

/// Renders one AWS Chime video tile on iOS, Android, macOS, or experimental Windows.
class MeetingVideoTileView extends StatelessWidget {
  const MeetingVideoTileView({super.key, required this.tile});

  final MeetingVideoTile tile;

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
      );
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: 'videoTile',
        creationParams: tile.tileId,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }

    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return AppKitView(
        viewType: 'videoTile',
        creationParams: tile.tileId,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }

    return PlatformViewLink(
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
          creationParams: tile.tileId,
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

/// Provisional frame renderer matching the macOS WebKit bridge's JPEG frame
/// event contract. It is not a low-latency native GPU texture.
class _WindowsChimeFrameView extends StatefulWidget {
  const _WindowsChimeFrameView({super.key, required this.tile});
  final MeetingVideoTile tile;

  @override
  State<_WindowsChimeFrameView> createState() => _WindowsChimeFrameViewState();
}

class _WindowsChimeFrameViewState extends State<_WindowsChimeFrameView> {
  static int _nextViewId = 0;
  final _runtime = AwsWindowsWebView2Runtime.instance;
  late final String _viewKey =
      'aws-chime-${widget.tile.tileId}-${_nextViewId++}';
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Uint8List? _frame;

  @override
  void initState() {
    super.initState();
    _subscription = _runtime.frames.listen((event) {
      if (event['viewKey'] != _viewKey || !mounted) return;
      final encoded = event['data'];
      if (encoded is! String || !encoded.startsWith('data:image/jpeg;base64,')) {
        return;
      }
      try {
        final raw = encoded.substring('data:image/jpeg;base64,'.length);
        // Bound frame copies to protect Flutter's image decoder.
        if (raw.length > 1800000) return;
        final bytes = base64Decode(raw);
        if (mounted) setState(() => _frame = bytes);
      } on FormatException {
        // A damaged frame is discarded; the next frame can recover.
      }
    });
    _bind();
  }

  Future<void> _bind() async {
    try {
      await _runtime.invoke(
        'bind',
        trackId: 'chime:tile:${widget.tile.tileId}',
        viewKey: _viewKey,
      );
      if (!mounted) {
        await _runtime.invoke('unbind', viewKey: _viewKey);
      }
    } catch (_) {
      // Keep a black tile rather than misreport a successful remote frame.
    }
  }

  @override
  void didUpdateWidget(covariant _WindowsChimeFrameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tile.tileId != widget.tile.tileId) {
      unawaited(_runtime.invoke('unbind', viewKey: _viewKey)
          .catchError((Object _) => null));
      _frame = null;
      _bind();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    unawaited(_runtime.invoke('unbind', viewKey: _viewKey)
        .catchError((Object _) => null));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
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
