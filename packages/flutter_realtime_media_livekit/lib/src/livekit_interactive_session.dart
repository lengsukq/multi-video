part of 'livekit_media_session.dart';

/// LiveKit session for a symmetric meeting participant.
class LiveKitInteractiveSession extends LiveKitMediaSessionBase
    implements InteractiveMediaSession, ProcessedVideoSink {
  LiveKitInteractiveSession({
    super.role = MediaRole.participant,
    super.roomFactory,
    super.iosScreenShareMode,
  }) : assert(role != MediaRole.viewer),
       super(capabilities: _capabilitiesForRole(role));

  @override
  bool supportsProcessedVideoSource(ProcessedVideoSource source) =>
      _publishing.supportsProcessedVideoSource(source);
  @override
  Future<void> attachProcessedVideoSource(ProcessedVideoSource source) =>
      _publishing.attachProcessedVideoSource(source);
  @override
  Future<void> detachProcessedVideoSource() =>
      _publishing.detachProcessedVideoSource();
  @override
  Future<List<MediaDevice>> listMediaDevices({Set<MediaDeviceKind>? kinds}) =>
      _publishing.listMediaDevices(kinds: kinds);
  @override
  Future<void> selectMediaDevice(MediaDevice device) =>
      _publishing.selectMediaDevice(device);
  @override
  Future<void> setMuted(bool muted) => _publishing.setMuted(muted);
  @override
  Future<void> toggleMute() => _publishing.toggleMute();
  @override
  Future<void> setVideoEnabled(bool enabled) =>
      _publishing.setVideoEnabled(enabled);
  @override
  Future<void> setScreenShareEnabled(bool enabled) =>
      _publishing.setScreenShareEnabled(enabled);
  @override
  Future<void> switchCamera(MediaCameraPosition position) =>
      _publishing.switchCamera(position);
  @override
  Future<List<MediaAudioDevice>> listAudioDevices() =>
      _publishing.listAudioDevices();
  @override
  Future<void> selectAudioDevice(MediaAudioDevice device) =>
      _publishing.selectAudioDevice(device);
}
