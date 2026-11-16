import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'artc_media_track.dart';

/// Renders an ARTC local or remote camera track through a native platform view.
class ArtcTrackRenderer extends MediaTrackRenderer {
  const ArtcTrackRenderer();

  @override
  bool handlesVideoFit(MediaVideoTrack track) => true;

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
    final creationParams = <String, Object?>{
      'userId': track.userId,
      'isLocal': track.isLocal,
      'isScreenShare': track.isScreenShare,
      'generation': track.generation,
      'fitMode': fit == BoxFit.contain ? 1 : 0,
    };
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => AndroidView(
        viewType: viewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      ),
      TargetPlatform.iOS => UiKitView(
        viewType: viewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      ),
      TargetPlatform.macOS => AppKitView(
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
  static const _channel =
      MethodChannel('com.oneplusdream.flutter_realtime_media_artc/methods');
  late Future<int?> _texture;
  Timer? _dimensionTimer;
  bool _checkingDimensions = false;
  double _sourceWidth = 1280;
  double _sourceHeight = 720;

  @override
  void initState() {
    super.initState();
    _texture = _channel.invokeMethod<int>('getTextureId', widget.params).then((id) {
      if (id != null && id >= 0 && mounted) {
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
      if (mounted && width > 0 && height > 0 &&
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
