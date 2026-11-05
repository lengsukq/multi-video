part of 'livekit_media_session.dart';

/// Opt-in meter for the microphone track already used by LiveKit RTC.
///
/// No second getUserMedia/AVAudioSession is created. This is deliberately
/// independent of publication.muted and speaking-state UI events: it proves
/// whether actual capture samples are arriving from the selected input.
class _LiveKitMicrophoneLevels {
  _LiveKitMicrophoneLevels(this._session);

  final LiveKitMediaSessionBase _session;
  late final StreamController<double> _samples =
      StreamController<double>.broadcast(
        onListen: () => unawaited(refresh()),
        onCancel: () => unawaited(stop()),
      );

  Stream<double> get levels => _samples.stream;
  Future<void> _pending = Future<void>.value();
  lk.AudioVisualizer? _meter;
  lk.EventsListener<lk.AudioVisualizerEvent>? _listener;
  bool _closed = false;
  int _lastSampleMs = 0;

  Future<void> _queue(Future<void> Function() operation) {
    final next = _pending.then((_) => operation());
    // A provider's visualizer failure must never break mute/unmute or leave
    // a poisoned queue that prevents later recovery.
    _pending = next.catchError((Object error) {
      debugPrint('[realtime/livekit] microphone level meter: $error');
    });
    return _pending;
  }

  Future<void> refresh() => _queue(_refresh);
  Future<void> stop() => _queue(_stop);

  Future<void> _refresh() async {
    await _stop();
    if (_closed || !_samples.hasListener) return;
    final publication = _session._room?.localParticipant
        ?.getTrackPublicationBySource(lk.TrackSource.microphone);
    final track = publication?.track;
    if (track is! lk.LocalAudioTrack || track.muted) return;
    try {
      final meter = lk.createVisualizer(
        track,
        options: const lk.AudioVisualizerOptions(
          barCount: 16,
          centeredBands: false,
          smoothTransition: false,
        ),
      );
      final listener = meter.createListener();
      _meter = meter;
      _listener = listener;
      listener.on<lk.AudioVisualizerEvent>((event) {
        if (_closed || _samples.isClosed || !_samples.hasListener) return;
        var peak = 0.0;
        for (final sample in event.event) {
          if (sample is num && sample.isFinite) {
            final amplitude = sample.toDouble();
            if (amplitude > peak) peak = amplitude;
          }
        }
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastSampleMs < 100) return;
        _lastSampleMs = now;
        final normalized = peak > 1 ? peak / 255 : peak;
        _samples.add(normalized.clamp(0.0, 1.0));
      });
      await meter.start();
    } catch (error) {
      debugPrint('[realtime/livekit] microphone visualizer unavailable: $error');
      await _stop();
    }
  }

  Future<void> _stop() async {
    final listener = _listener;
    final meter = _meter;
    _listener = null;
    _meter = null;
    try {
      await listener?.dispose();
    } catch (_) {}
    if (meter != null) {
      try {
        await meter.stop();
      } catch (_) {}
      try {
        await meter.dispose();
      } catch (_) {}
    }
    if (!_samples.isClosed && _samples.hasListener) _samples.add(0);
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    await stop();
    await _samples.close();
  }
}
