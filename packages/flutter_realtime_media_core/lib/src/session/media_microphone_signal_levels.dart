import 'dart:async';

/// Optional microphone signal meter for an already-published local RTC track.
///
/// Values are real sampled amplitudes in [0, 1], not inferred from a
/// published/unmuted flag. Subscribing must not start a new microphone capture
/// source. Providers without a supported meter simply omit this interface.
abstract interface class MediaMicrophoneSignalLevels {
  Stream<double> get microphoneLevels;
}
