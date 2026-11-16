import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:web/web.dart' as web;

import 'provider_web_bridge.dart';
import 'provider_web_track.dart';

class ProviderWebTrackRenderer extends MediaTrackRenderer {
  const ProviderWebTrackRenderer();

  // Provider Web bridge applies HTMLVideoElement.objectFit (contain/cover).
  @override
  bool handlesVideoFit(MediaVideoTrack track) => true;

  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      buildViewWithFit(context, track);

  @override
  Widget buildViewWithFit(
    BuildContext context,
    MediaVideoTrack track, {
    BoxFit fit = BoxFit.contain,
  }) {
    if (track is! ProviderWebVideoTrack) {
      throw ArgumentError.value(
        track,
        'track',
        'ProviderWebTrackRenderer requires a ProviderWebVideoTrack.',
      );
    }
    return _ProviderWebVideoView(track: track, fit: fit);
  }
}

class _ProviderWebVideoView extends StatefulWidget {
  const _ProviderWebVideoView({
    required this.track,
    this.fit = BoxFit.contain,
  });

  final ProviderWebVideoTrack track;
  final BoxFit fit;

  @override
  State<_ProviderWebVideoView> createState() => _ProviderWebVideoViewState();
}

class _ProviderWebVideoViewState extends State<_ProviderWebVideoView> {
  static int _nextElementId = 0;

  late String _elementId;
  web.HTMLDivElement? _element;

  String get _objectFit => widget.fit == BoxFit.cover ? 'cover' : 'contain';

  void _syncVideoFit() {
    final container = _element;
    if (container == null) return;
    container.dataset['videoFit'] = _objectFit;
    final video = container.querySelector('video');
    if (video != null && video.isA<web.HTMLVideoElement>()) {
      (video as web.HTMLVideoElement).style.objectFit = _objectFit;
    }
  }

  @override
  void initState() {
    super.initState();
    _elementId = 'provider-video-${_nextElementId++}';
  }

  @override
  void didUpdateWidget(covariant _ProviderWebVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.sessionId != widget.track.sessionId ||
        oldWidget.track.id != widget.track.id) {
      _detach(oldWidget.track, _elementId);
      _syncVideoFit();
      if (_element != null) _attach(widget.track, _elementId);
    } else if (oldWidget.fit != widget.fit) {
      _syncVideoFit();
    }
  }

  void _attach(ProviderWebVideoTrack track, String elementId) {
    observeDetached(
      ProviderWebBridge.attachVideo(
        providerId: track.providerId,
        sessionId: track.sessionId,
        trackId: track.id,
        elementId: elementId,
        element: _element,
      ),
    );
  }

  void _detach(ProviderWebVideoTrack track, String elementId) {
    ProviderWebBridge.detachVideo(
      providerId: track.providerId,
      sessionId: track.sessionId,
      trackId: track.id,
      elementId: elementId,
    );
  }

  @override
  void dispose() {
    _detach(widget.track, _elementId);
    _element = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView.fromTagName(
    tagName: 'div',
    onElementCreated: (element) {
      final container = element as web.HTMLDivElement;
      _element = container;
      container.id = _elementId;
      container.style
        ..width = '100%'
        ..height = '100%'
        ..overflow = 'hidden'
        ..backgroundColor = '#000000';
      _syncVideoFit();
      _attach(widget.track, _elementId);
    },
  );
}
