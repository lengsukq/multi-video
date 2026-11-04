part of 'ivs_media_session.dart';

class IvsBroadcastHostSession extends _IvsMediaSession
    implements BroadcastHostSession {
  IvsBroadcastHostSession({required super.engineFactory})
    : super(role: MediaRole.host);

  @override
  Future<void> setMuted(bool muted) => _publishing._setMuted(muted);
  @override
  Future<void> toggleMute() => setMuted(!snapshot.localMuted);
  @override
  Future<void> setVideoEnabled(bool enabled) =>
      _publishing._setVideoEnabled(enabled);
  @override
  Future<void> switchCamera(MediaCameraPosition position) =>
      _publishing._switchCamera(position);
  @override
  Future<void> setScreenShareEnabled(bool enabled) =>
      _publishing._setScreenShareEnabled(enabled);
  @override
  Future<List<MediaAudioDevice>> listAudioDevices() async {
    await _unsupported('audio-output enumeration');
    return const [];
  }

  @override
  Future<void> selectAudioDevice(MediaAudioDevice device) =>
      _unsupported('audio-output selection');
  @override
  Future<void> sendMessage(String message, {String topic = 'chat'}) =>
      _unsupported('RTC data messaging; use a Chat Provider instead');
}
