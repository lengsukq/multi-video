/// Diagnostic state of the *native* voice engine and remote audio tracks.
///
/// An unmuted microphone publication is not proof that an iOS audio engine
/// is recording; a subscribed remote audio track is not proof of playout.
class MediaAudioEngineReport {
  const MediaAudioEngineReport({
    required this.recordingEnabled,
    required this.playoutEnabled,
    required this.audioSessionMode,
    required this.speakerPreferred,
    required this.remoteAudioPublished,
    required this.remoteAudioSubscribed,
  });

  final bool recordingEnabled;
  final bool playoutEnabled;
  final String audioSessionMode;
  final bool speakerPreferred;
  final int remoteAudioPublished;
  final int remoteAudioSubscribed;

  @override
  String toString() =>
      'recording=$recordingEnabled playout=$playoutEnabled '
      'session=$audioSessionMode speakerPreferred=$speakerPreferred '
      'remoteAudio=$remoteAudioSubscribed/$remoteAudioPublished';
}

/// Optional provider-level view of engine diagnostics; observing never
/// creates a microphone input or modifies the audio session.
abstract interface class MediaAudioEngineDiagnostics {
  MediaAudioEngineReport get audioEngineReport;
  Stream<MediaAudioEngineReport> get audioEngineReports;
}

/// Actual WebRTC RTP and source energy counters, not UI/speaking flags.
///
/// All counters are cumulative. Compare two samples several seconds apart
/// while speaking to distinguish capture, sending and receiving failures.
/// Null means the native peer connection did not expose that statistic.
class MediaAudioRtpReport {
  const MediaAudioRtpReport({
    required this.microphoneTrackPresent,
    required this.microphoneTrackMuted,
    required this.captureTrackEnabled,
    required this.senderTrackPresent,
    required this.senderTrackEnabled,
    required this.senderMatchesCapture,
    required this.remoteAudioTracks,
    this.outboundPackets,
    this.outboundBytes,
    this.inputAudioLevel,
    this.inputAudioEnergy,
    this.inboundPackets,
    this.inboundBytes,
    this.receivedAudioEnergy,
  });

  final bool microphoneTrackPresent;
  final bool? microphoneTrackMuted;
  final bool? captureTrackEnabled;
  final bool senderTrackPresent;
  final bool? senderTrackEnabled;
  final bool? senderMatchesCapture;
  final int remoteAudioTracks;
  final num? outboundPackets;
  final num? outboundBytes;
  final num? inputAudioLevel;
  final num? inputAudioEnergy;
  final num? inboundPackets;
  final num? inboundBytes;
  final num? receivedAudioEnergy;

  @override
  String toString() =>
      'track=$microphoneTrackPresent muted=$microphoneTrackMuted '
      'captureEnabled=$captureTrackEnabled senderTrack=$senderTrackPresent '
      'senderEnabled=$senderTrackEnabled senderMatches=$senderMatchesCapture '
      'outPackets=$outboundPackets outBytes=$outboundBytes '
      'inputLevel=$inputAudioLevel inputEnergy=$inputAudioEnergy '
      'remoteTracks=$remoteAudioTracks '
      'inPackets=$inboundPackets inBytes=$inboundBytes '
      'recvEnergy=$receivedAudioEnergy';
}

/// Diagnostic polling is opt-in and must not start or alter media tracks.
abstract interface class MediaAudioRtpDiagnostics {
  Future<MediaAudioRtpReport> readAudioRtpReport();
}
