import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_processed_video/flutter_realtime_processed_video.dart';

import 'artc_media_track.dart';

/// Renders an ARTC local or remote camera track through a native platform view.
class ArtcTrackRenderer extends MediaTrackRenderer {
  const ArtcTrackRenderer();

  @override
  bool handlesVideoFit(MediaVideoTrack track) {
    if (track is ArtcMediaVideoTrack &&
        track.isLocal &&
        !track.isScreenShare &&
        track.processedSource != null) {
      return track.processedSource!.platform == ProcessedVideoPlatform.web;
    }
    return true;
  }

  static const String viewType =
      'com.oneplusdream.flutter_realtime_media_artc/video';

  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      buildViewWithFit(context, track);

  @override
  Widget buildViewWithFit(
    BuildContext context,
    MediaVideoTrack track, {
    BoxFit fit = BoxFit.contain,
  }) {
    if (track is! ArtcMediaVideoTrack) {
      throw ArgumentError.value(
        track,
        'track',
        'ArtcTrackRenderer requires an ArtcMediaVideoTrack.',
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
    final creationParams = <String, Object?>{
      'userId': track.userId,
      'isLocal': track.isLocal,
      'isScreenShare': track.isScreenShare,
      'generation': track.generation,
      'fitMode': fit == BoxFit.contain ? 1 : 0,
    };
    final viewKey = ValueKey('${track.id}:${fit.name}');
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => AndroidView(
        key: viewKey,
        viewType: viewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      ),
      TargetPlatform.iOS => UiKitView(
        key: viewKey,
        viewType: viewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      ),
      TargetPlatform.macOS => AppKitView(
        key: viewKey,
        viewType: viewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      ),
      TargetPlatform.windows => _WindowsArtcTexture(
        key: ValueKey(track.id),
        params: creationParams,
        fit: fit,
      ),
      _ => const SizedBox.expand(),
    };
  }
}

/// Windows renders SDK BGRA frames through Flutter's external texture API.
/// The native plugin owns each texture for the active ARTC engine session.
class _WindowsArtcTexture extends StatefulWidget {
  const _WindowsArtcTexture({
    super.key,
    required this.params,
    required this.fit,
  });
  final Map<String, Object?> params;
  final BoxFit fit;

  @override
  State<_WindowsArtcTexture> createState() => _WindowsArtcTextureState();
}

class _WindowsArtcTextureState extends State<_WindowsArtcTexture> {
  static const _channel = MethodChannel(
    'com.oneplusdream.flutter_realtime_media_artc/methods',
  );
  late Future<int?> _texture;
  Timer? _dimensionTimer;
  bool _checkingDimensions = false;
  double _sourceWidth = 1280;
  double _sourceHeight = 720;
  int _bindGeneration = 0;

  @override
  void initState() {
    super.initState();
    _bindTexture();
  }

  @override
  void didUpdateWidget(covariant _WindowsArtcTexture oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed =
        oldWidget.params['userId'] != widget.params['userId'] ||
        oldWidget.params['isLocal'] != widget.params['isLocal'] ||
        oldWidget.params['isScreenShare'] != widget.params['isScreenShare'] ||
        oldWidget.params['generation'] != widget.params['generation'];
    if (changed) {
      _dimensionTimer?.cancel();
      _dimensionTimer = null;
      _sourceWidth = 1280;
      _sourceHeight = 720;
      _bindTexture();
    }
  }

  void _bindTexture() {
    final generation = ++_bindGeneration;
    _texture = _channel.invokeMethod<int>('getTextureId', widget.params).then((
      id,
    ) {
      if (id != null && id >= 0 && mounted && generation == _bindGeneration) {
        _dimensionTimer?.cancel();
        _dimensionTimer = Timer.periodic(
          const Duration(seconds: 1),
          (_) => unawaited(_refreshDimensions()),
        );
        unawaited(_refreshDimensions());
      }
      return id;
    });
  }

  Future<void> _refreshDimensions() async {
    if (_checkingDimensions || !mounted) return;
    _checkingDimensions = true;
    try {
      final dimensions = await _channel.invokeMapMethod<String, Object?>(
        'getTextureDimensions',
        widget.params,
      );
      final width = (dimensions?['width'] as num?)?.toDouble() ?? 0;
      final height = (dimensions?['height'] as num?)?.toDouble() ?? 0;
      if (mounted &&
          width > 0 &&
          height > 0 &&
          (width != _sourceWidth || height != _sourceHeight)) {
        setState(() {
          _sourceWidth = width;
          _sourceHeight = height;
        });
      }
    } on PlatformException {
      // Frame may disappear while the native session is leaving.
    } on MissingPluginException {
      // A removed Windows plugin cannot provide new frames.
    } finally {
      _checkingDimensions = false;
    }
  }

  @override
  void dispose() {
    _bindGeneration++;
    _dimensionTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<int?>(
    future: _texture,
    builder: (context, snapshot) {
      final id = snapshot.data;
      if (id == null || id < 0) return const SizedBox.expand();
      return SizedBox.expand(
        child: FittedBox(
          fit: widget.fit,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: _sourceWidth,
            height: _sourceHeight,
            child: Texture(textureId: id),
          ),
        ),
      );
    },
  );
}
