part of 'livekit_media_session.dart';

/// LiveKit one-to-many broadcast host.
class LiveKitHostSession extends LiveKitInteractiveSession
    implements BroadcastHostSession {
  LiveKitHostSession({super.roomFactory, super.iosScreenShareMode})
    : super(role: MediaRole.host);
}
