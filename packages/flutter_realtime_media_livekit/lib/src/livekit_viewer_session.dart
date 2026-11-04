part of 'livekit_media_session.dart';

/// LiveKit subscribe-only broadcast viewer.
class LiveKitViewerSession extends LiveKitMediaSessionBase
    implements BroadcastViewerSession {
  LiveKitViewerSession({super.roomFactory, super.iosScreenShareMode})
    : super(
        role: MediaRole.viewer,
        capabilities: _capabilitiesForRole(MediaRole.viewer),
      );
}
