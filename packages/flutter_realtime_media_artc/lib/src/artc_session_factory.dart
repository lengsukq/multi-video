import 'package:flutter/foundation.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'artc_engine.dart';
import 'artc_join_info.dart';
import 'artc_media_session.dart';

/// Creates optional Alibaba Cloud ARTC sessions without affecting other adapters.
class ArtcSessionFactory implements MediaSessionFactory, MediaPreJoinProbe {
  const ArtcSessionFactory({
    this.engineFactory = createNativeArtcEngine,
    this.availabilityProbe = probeNativeArtcAvailability,
  });

  /// Native factory defaults to ARTC's singleton engine. Tests may inject a fake.
  final ArtcEngineFactory engineFactory;
  final ArtcAvailabilityProbe availabilityProbe;

  @override
  String get providerId => ArtcJoinInfo.providerIdValue;

  @override
  Set<MediaRole> get supportedRoles => const {
    MediaRole.participant,
    MediaRole.host,
    MediaRole.viewer,
  };

  @override
  ArtcJoinInfo parseJoinInfo(Map<String, dynamic> json) =>
      ArtcJoinInfo.fromJson(json);

  @override
  MediaSession createSession(MediaJoinInfo joinInfo) {
    if (joinInfo.providerId != providerId ||
        !supportedRoles.contains(joinInfo.role)) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'ARTC session cannot be created for this provider or role.',
        providerId: ArtcJoinInfo.providerIdValue,
      );
    }
    return switch (joinInfo.role) {
      MediaRole.participant => ArtcParticipantSession(
        engineFactory: engineFactory,
      ),
      MediaRole.host => ArtcBroadcastHostSession(engineFactory: engineFactory),
      MediaRole.viewer => ArtcBroadcastViewerSession(
        engineFactory: engineFactory,
      ),
    };
  }

  @override
  Future<MediaPreJoinProbeResult> runPreJoinProbe(
    MediaPreJoinProbeRequest request,
  ) async {
    final checks = <MediaPreJoinCheck>[];
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows)) {
      final available = await availabilityProbe();
      if (!available) {
        checks.add(
          MediaPreJoinCheck(
            type: MediaPreJoinCheckType.provider,
            status: MediaPreJoinStatus.unsupported,
            severity: MediaPreJoinSeverity.blocking,
            message: defaultTargetPlatform == TargetPlatform.windows
                ? 'Alibaba ARTC Windows native engine is not installed or ready.'
                : 'Alibaba ARTC macOS framework is not bundled with this SDK build.',
          ),
        );
      }
    }

    void addDeviceCheck(
      MediaPreJoinCheckType type,
      MediaPreJoinRequirement requirement,
      String label,
    ) {
      if (requirement == MediaPreJoinRequirement.skipped) return;
      checks.add(
        MediaPreJoinCheck(
          type: type,
          status: MediaPreJoinStatus.unsupported,
          severity: requirement.severity,
          message:
              'ARTC does not expose pre-join $label enumeration through this adapter.',
        ),
      );
    }

    addDeviceCheck(
      MediaPreJoinCheckType.microphoneDevice,
      request.requirements.microphone,
      'microphone',
    );
    addDeviceCheck(
      MediaPreJoinCheckType.cameraDevice,
      request.requirements.camera,
      'camera',
    );
    if (request.requirements.network != MediaPreJoinRequirement.skipped) {
      checks.add(
        const MediaPreJoinCheck(
          type: MediaPreJoinCheckType.providerNetwork,
          status: MediaPreJoinStatus.unsupported,
          severity: MediaPreJoinSeverity.warning,
          message:
              'ARTC cannot run a provider network probe without issued room credentials.',
        ),
      );
    }
    return MediaPreJoinProbeResult(List.unmodifiable(checks));
  }
}
