import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

/// Provider-specific Web behavior kept outside the shared session machinery.
///
/// This is intentionally small: providers can progressively move parsing,
/// capabilities and bridge behavior behind profiles without another large
/// provider-id switch accumulating in ProviderWebSessionFactory.
class ProviderWebProfile {
  const ProviderWebProfile({
    required this.providerId,
    required this.supportedRoles,
    this.usesChimeAttendeePayload = false,
    this.canSwitchCamera = true,
    this.canReportNetworkStats = true,
    this.canManageParticipants = true,
    this.canRemoveParticipants = false,
    this.supportsAudioOutputSelection = false,
    this.canSendData = false,
    this.canReceiveData = false,
    this.canBlurBackground = true,
    this.canReplaceBackgroundImage = true,
  });

  final String providerId;
  final Set<MediaRole> supportedRoles;
  final bool usesChimeAttendeePayload;
  final bool canSwitchCamera;
  final bool canReportNetworkStats;
  final bool canManageParticipants;
  final bool canRemoveParticipants;
  final bool supportsAudioOutputSelection;
  final bool canSendData;
  final bool canReceiveData;
  final bool canBlurBackground;
  final bool canReplaceBackgroundImage;

  String contentOwner(String participantId, {required bool isScreenShare}) =>
      usesChimeAttendeePayload &&
          isScreenShare &&
          participantId.endsWith('#content')
      ? participantId.substring(0, participantId.length - '#content'.length)
      : participantId;

  static ProviderWebProfile forProvider(
    String providerId,
  ) => switch (providerId) {
    'chime' => const ProviderWebProfile(
      providerId: 'chime',
      supportedRoles: {MediaRole.participant},
      usesChimeAttendeePayload: true,
      canSwitchCamera: false,
      canReportNetworkStats: false,
      canManageParticipants: false,
      supportsAudioOutputSelection: true,
      canSendData: true,
      canReceiveData: true,
    ),
    'agora' => const ProviderWebProfile(
      providerId: 'agora',
      supportedRoles: {MediaRole.participant, MediaRole.host, MediaRole.viewer},
      supportsAudioOutputSelection: true,
      canSendData: true,
      canReceiveData: true,
      canBlurBackground: true,
      canReplaceBackgroundImage: true,
    ),
    'ivs' => const ProviderWebProfile(
      providerId: 'ivs',
      supportedRoles: {MediaRole.participant, MediaRole.host, MediaRole.viewer},
      canRemoveParticipants: true,
    ),
    _ => ProviderWebProfile(
      providerId: providerId,
      supportedRoles: const {
        MediaRole.participant,
        MediaRole.host,
        MediaRole.viewer,
      },
    ),
  };
}
