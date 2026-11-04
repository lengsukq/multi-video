part of 'agora_media_session.dart';

const _agoraProviderId = AgoraJoinInfo.providerIdValue;

MediaCapabilities _capabilitiesForRole(MediaRole role) {
  if (role == MediaRole.viewer) {
    return const MediaCapabilities(
      canSubscribeVideo: true,
      canSendData: false,
      canReceiveData: true,
      canReportNetworkStats: true,
    );
  }

  final canSwitchCamera =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);
  return MediaCapabilities(
    canPublishAudio: true,
    canPublishVideo: true,
    canBlurBackground:
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows),
    canReplaceBackgroundImage:
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows),
    canEnumerateCameras:
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows),
    canSelectCamera:
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows),
    canSwitchCamera: canSwitchCamera,
    // iOS 27+ uses the shared ScreenCaptureKit custom video track; older
    // iOS releases fail with an explicit unsupported-feature exception.
    canScreenShare:
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows),
    canSendData: true,
    canReceiveData: true,
    canSubscribeVideo: true,
    canEnumerateAudioDevices: false,
    canReportNetworkStats: true,
    maxDataMessageBytes: 1024,
    canListParticipants: role == MediaRole.host,
    canCloseRoom: role == MediaRole.host,
  );
}
