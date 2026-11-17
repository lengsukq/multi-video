import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Shared macOS GPU texture renderer for AWS Chime and Amazon IVS desktop
/// WebKit video streams.
///
/// Replaces heavyweight `AppKitView` platform views with an `IOSurface`-backed
/// `FlutterTexture`, eliminating main-thread JPEG decoding, AppKit layer
/// synchronization, and native view destruction when [BoxFit] changes.
class AwsMacosTextureView extends StatefulWidget {
  const AwsMacosTextureView.chime({
    super.key,
    required int this.tileId,
    this.initialWidth = 0,
    this.initialHeight = 0,
    this.fit = BoxFit.contain,
  }) : provider = 'chime',
       userId = '',
       isLocal = false,
       generation = 0;

  const AwsMacosTextureView.ivs({
    super.key,
    required this.userId,
    required this.isLocal,
    this.generation = 0,
    this.initialWidth = 0,
    this.initialHeight = 0,
    this.fit = BoxFit.contain,
  }) : provider = 'ivs',
       tileId = null;

  final String provider;
  final int? tileId;
  final String userId;
  final bool isLocal;
  final int generation;
  final int initialWidth;
  final int initialHeight;
  final BoxFit fit;

  @override
  State<AwsMacosTextureView> createState() => _AwsMacosTextureViewState();
}

class _AwsMacosTextureRegistry {
  _AwsMacosTextureRegistry._() {
    channel.setMethodCallHandler(_handleCall);
  }

  static final _AwsMacosTextureRegistry instance = _AwsMacosTextureRegistry._();

  final MethodChannel channel = const MethodChannel(
    'com.oneplusdream.aws.desktop.textures',
  );
  final Map<String, void Function(int width, int height)> _sizeListeners =
      <String, void Function(int width, int height)>{};

  void register(String viewKey, void Function(int width, int height) listener) {
    _sizeListeners[viewKey] = listener;
  }

  void unregister(String viewKey) {
    _sizeListeners.remove(viewKey);
  }

  Future<void> _handleCall(MethodCall call) async {
    if (call.method != 'onTextureSizeChanged') return;
    final arguments = call.arguments;
    if (arguments is! Map) return;
    final viewKey = arguments['viewKey']?.toString();
    final width = (arguments['width'] as num?)?.toInt() ?? 0;
    final height = (arguments['height'] as num?)?.toInt() ?? 0;
    if (viewKey == null || width <= 0 || height <= 0) return;
    _sizeListeners[viewKey]?.call(width, height);
  }
}

class _AwsMacosTextureViewState extends State<AwsMacosTextureView> {
  int? _textureId;
  String? _viewKey;
  int _frameWidth = 0;
  int _frameHeight = 0;
  int _bucketedMaxDimension = 960;
  int _sessionGeneration = 0;

  @override
  void initState() {
    super.initState();
    _frameWidth = widget.initialWidth;
    _frameHeight = widget.initialHeight;
    unawaited(_acquireTexture());
  }

  @override
  void didUpdateWidget(covariant AwsMacosTextureView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final identityChanged =
        oldWidget.provider != widget.provider ||
        oldWidget.tileId != widget.tileId ||
        oldWidget.userId != widget.userId ||
        oldWidget.isLocal != widget.isLocal ||
        oldWidget.generation != widget.generation;
    if (identityChanged) {
      unawaited(_releaseCurrentTexture());
      _textureId = null;
      _viewKey = null;
      _frameWidth = widget.initialWidth;
      _frameHeight = widget.initialHeight;
      unawaited(_acquireTexture());
      return;
    }
    if (_frameWidth <= 0 && widget.initialWidth > 0) {
      _frameWidth = widget.initialWidth;
    }
    if (_frameHeight <= 0 && widget.initialHeight > 0) {
      _frameHeight = widget.initialHeight;
    }
  }

  Future<void> _acquireTexture() async {
    final generation = ++_sessionGeneration;
    try {
      final response = await _AwsMacosTextureRegistry.instance.channel
          .invokeMapMethod<String, Object?>('createTexture', <String, Object?>{
            'provider': widget.provider,
            if (widget.tileId != null) 'tileId': widget.tileId,
            'userId': widget.userId,
            'isLocal': widget.isLocal,
            'maxDimension': _bucketedMaxDimension,
          });
      final textureId = (response?['textureId'] as num?)?.toInt();
      final viewKey = response?['viewKey']?.toString();
      if (textureId == null || textureId < 0 || viewKey == null) return;
      if (!mounted || generation != _sessionGeneration) {
        await _AwsMacosTextureRegistry.instance.channel.invokeMethod<void>(
          'disposeTexture',
          <String, Object?>{'viewKey': viewKey},
        );
        return;
      }
      _AwsMacosTextureRegistry.instance.register(viewKey, (width, height) {
        if (!mounted || _viewKey != viewKey) return;
        if (width != _frameWidth || height != _frameHeight) {
          setState(() {
            _frameWidth = width;
            _frameHeight = height;
          });
        }
      });
      setState(() {
        _textureId = textureId;
        _viewKey = viewKey;
      });
    } on MissingPluginException {
      // Widget tests without native desktop bridge remain black safely.
    } on PlatformException {
      // Keep black placeholder on transient native disposal.
    }
  }

  Future<void> _releaseCurrentTexture() async {
    _sessionGeneration++;
    final viewKey = _viewKey;
    if (viewKey == null) return;
    _AwsMacosTextureRegistry.instance.unregister(viewKey);
    try {
      await _AwsMacosTextureRegistry.instance.channel.invokeMethod<void>(
        'disposeTexture',
        <String, Object?>{'viewKey': viewKey},
      );
    } on MissingPluginException {
      // Nothing to release when running in headless widget tests.
    } on PlatformException {
      // Ignore teardown races when engine shuts down.
    }
  }

  void _updateTargetBucket(BoxConstraints constraints, double pixelRatio) {
    if (!constraints.hasBoundedWidth && !constraints.hasBoundedHeight) return;
    final logicalLongest = math.max(
      constraints.hasBoundedWidth ? constraints.maxWidth : 0.0,
      constraints.hasBoundedHeight ? constraints.maxHeight : 0.0,
    );
    if (logicalLongest <= 0 || !logicalLongest.isFinite) return;
    final physicalLongest = logicalLongest * math.min(pixelRatio, 2.0);
    final bucket = switch (physicalLongest) {
      <= 320 => 320,
      <= 480 => 480,
      <= 640 => 640,
      <= 960 => 960,
      _ => 1280,
    };
    if (bucket == _bucketedMaxDimension) return;
    _bucketedMaxDimension = bucket;
    final viewKey = _viewKey;
    if (viewKey != null) {
      unawaited(
        _AwsMacosTextureRegistry.instance.channel
            .invokeMethod<void>('updateTextureTarget', <String, Object?>{
              'viewKey': viewKey,
              'maxDimension': bucket,
            })
            .catchError((Object _) {}),
      );
    }
  }

  @override
  void dispose() {
    unawaited(_releaseCurrentTexture());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pixelRatio =
        MediaQuery.maybeDevicePixelRatioOf(context) ??
        WidgetsBinding
            .instance
            .platformDispatcher
            .views
            .firstOrNull
            ?.devicePixelRatio ??
        1.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        _updateTargetBucket(constraints, pixelRatio);
        final id = _textureId;
        if (id == null || id < 0) {
          return const ColoredBox(
            color: Color(0xFF000000),
            child: SizedBox.expand(),
          );
        }
        final width = (_frameWidth > 0 ? _frameWidth : 640).toDouble();
        final height = (_frameHeight > 0 ? _frameHeight : 360).toDouble();
        return ColoredBox(
          color: const Color(0xFF000000),
          child: SizedBox.expand(
            child: FittedBox(
              fit: widget.fit,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: width,
                height: height,
                child: Texture(textureId: id),
              ),
            ),
          ),
        );
      },
    );
  }
}
