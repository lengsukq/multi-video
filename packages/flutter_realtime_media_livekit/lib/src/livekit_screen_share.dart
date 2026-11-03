part of 'livekit_media_session.dart';

class _LiveKitScreenShare {
  _LiveKitScreenShare(this._session);
  final LiveKitMediaSessionBase _session;
  bool _androidScreenShareServiceStarted = false;

  /// LiveKit Flutter 2.4+ returns before capture when
  /// LocalParticipant.setScreenShareEnabled(true) is called on iOS without
  /// a Broadcast Upload Extension, even if useiOSBroadcastExtension is false.
  /// Capture the current app directly through flutter_webrtc instead and
  /// publish a real screenShareVideo track before reporting success.
  ///
  /// This captures only our app's contents. Sharing the entire iOS display
  /// (including other apps) requires a separately signed ReplayKit Broadcast
  /// Upload Extension and a matching App Group in the host application.
  Future<void> _setIosInAppScreenShareEnabled(bool enabled) async {
    final participant = _session._requireLocalParticipant();
    final existing = participant.getTrackPublicationBySource(
      lk.TrackSource.screenShareVideo,
    );
    if (!enabled) {
      if (existing != null) {
        await participant.setScreenShareEnabled(false);
      }
      return;
    }
    if (existing != null) return;

    final track = await captureAndPublishIosInAppScreen<lk.LocalVideoTrack>(
      capture: () => lk.LocalVideoTrack.createScreenShareTrack(
        const lk.ScreenShareCaptureOptions(useiOSBroadcastExtension: false),
      ),
      publish: (track) async {
        await participant.publishVideoTrack(track);
      },
      release: (track) => track.stop(),
    );
    if (participant.getTrackPublicationBySource(
          lk.TrackSource.screenShareVideo,
        ) ==
        null) {
      try {
        await track.stop();
      } catch (_) {
        // Report the missing publication, not the subsequent cleanup error.
      }
      throw RealtimeException(
        code: RealtimeErrorCode.providerError,
        message: 'iOS app screen capture did not publish a LiveKit track.',
        providerId: _session.providerId,
        operation: 'screenShare',
        recoverable: true,
        suggestedAction: 'retry-screen-sharing',
      );
    }
  }

  Future<void> _prepareAndroidScreenShare() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    // System annotation windows must be visible in the shared display; an
    // Android single-app projection excludes windows belonging to other apps.
    final permissionGranted = await rtc.Helper.requestCapturePermission(
      fullScreenOnly: true,
    );
    if (!permissionGranted) {
      throw RealtimeException(
        code: RealtimeErrorCode.permissionDenied,
        message: 'Screen-capture permission was denied.',
        providerId: _session.providerId,
      );
    }

    await _androidScreenShareChannel.invokeMethod<void>('start');
    _androidScreenShareServiceStarted = true;
  }

  Future<void> _prepareMacOsScreenShare() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return;

    final permissionGranted = await rtc.Helper.requestCapturePermission();
    if (!permissionGranted) {
      throw RealtimeException(
        code: RealtimeErrorCode.permissionDenied,
        message:
            'LiveKit screen sharing needs macOS Screen Recording permission. '
            'Allow it in System Settings > Privacy & Security > Screen Recording, '
            'then restart the app.',
        providerId: _session.providerId,
      );
    }
  }

  Future<void> _stopAndroidScreenShareService() async {
    if (!_androidScreenShareServiceStarted ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _androidScreenShareServiceStarted = false;
    await _androidScreenShareChannel.invokeMethod<void>('stop');
  }
}
