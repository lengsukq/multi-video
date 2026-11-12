import 'package:flutter/foundation.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'ivs_engine.dart';
import 'ivs_join_info.dart';
import 'ivs_media_session.dart';

class IvsSessionFactory implements MediaSessionFactory, MediaPreJoinProbe {
  const IvsSessionFactory({
    this.engineFactory = createNativeIvsEngine,
    this.deviceProbe = probeNativeIvsDevices,
    this.availabilityProbe = probeNativeIvsAvailability,
  });

  final IvsEngineFactory engineFactory;
  final IvsDeviceProbe deviceProbe;
  final IvsAvailabilityProbe availabilityProbe;

  @override
  String get providerId => IvsJoinInfo.providerIdValue;

  @override
  Set<MediaRole> get supportedRoles => const {
    MediaRole.participant,
    MediaRole.host,
    MediaRole.viewer,
  };

  @override
  IvsJoinInfo parseJoinInfo(Map<String, dynamic> json) =>
      IvsJoinInfo.fromJson(json);

  @override
  MediaSession createSession(MediaJoinInfo joinInfo) {
    if (joinInfo is! IvsJoinInfo ||
        joinInfo.providerId != providerId ||
        !supportedRoles.contains(joinInfo.role)) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'IVS session cannot be created for this provider or role.',
        providerId: IvsJoinInfo.providerIdValue,
      );
    }
    return switch (joinInfo.role) {
      MediaRole.participant => IvsParticipantSession(
        engineFactory: engineFactory,
      ),
      MediaRole.host => IvsBroadcastHostSession(engineFactory: engineFactory),
      MediaRole.viewer => IvsBroadcastViewerSession(
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
        defaultTargetPlatform == TargetPlatform.windows &&
        !await availabilityProbe()) {
      return const MediaPreJoinProbeResult([
        MediaPreJoinCheck(
          type: MediaPreJoinCheckType.provider,
          status: MediaPreJoinStatus.unsupported,
          severity: MediaPreJoinSeverity.blocking,
          message:
              'Amazon IVS Stage Windows media bridge is not installed or ready.',
        ),
      ]);
    }
    final needsMicrophone =
        request.requirements.microphone != MediaPreJoinRequirement.skipped;
    final needsCamera =
        request.requirements.camera != MediaPreJoinRequirement.skipped;
    if (needsMicrophone || needsCamera) {
      try {
        final devices = await deviceProbe();
        if (needsMicrophone) {
          checks.add(
            MediaPreJoinCheck(
              type: MediaPreJoinCheckType.microphoneDevice,
              status: devices.microphones > 0
                  ? MediaPreJoinStatus.passed
                  : MediaPreJoinStatus.failed,
              severity: request.requirements.microphone.severity,
              message: devices.microphones > 0
                  ? 'Found ${devices.microphones} IVS microphone device(s).'
                  : 'No IVS microphone device is available.',
            ),
          );
        }
        if (needsCamera) {
          checks.add(
            MediaPreJoinCheck(
              type: MediaPreJoinCheckType.cameraDevice,
              status: devices.cameras > 0
                  ? MediaPreJoinStatus.passed
                  : MediaPreJoinStatus.failed,
              severity: request.requirements.camera.severity,
              message: devices.cameras > 0
                  ? 'Found ${devices.cameras} IVS camera device(s).'
                  : 'No IVS camera device is available.',
            ),
          );
        }
      } catch (error) {
        if (needsMicrophone) {
          checks.add(
            MediaPreJoinCheck(
              type: MediaPreJoinCheckType.microphoneDevice,
              status: MediaPreJoinStatus.unknown,
              severity: request.requirements.microphone.severity,
              message: 'Unable to enumerate IVS microphone devices.',
              details: error,
            ),
          );
        }
        if (needsCamera) {
          checks.add(
            MediaPreJoinCheck(
              type: MediaPreJoinCheckType.cameraDevice,
              status: MediaPreJoinStatus.unknown,
              severity: request.requirements.camera.severity,
              message: 'Unable to enumerate IVS camera devices.',
              details: error,
            ),
          );
        }
      }
    }
    if (request.requirements.network != MediaPreJoinRequirement.skipped) {
      checks.add(
        MediaPreJoinCheck(
          type: MediaPreJoinCheckType.providerNetwork,
          status: MediaPreJoinStatus.unsupported,
          severity: request.requirements.network.severity,
          message:
              'Amazon IVS native Stage connectivity requires a participant token; '
              'Pre-Join does not consume join credentials for a synthetic probe.',
        ),
      );
    }
    return MediaPreJoinProbeResult(List.unmodifiable(checks));
  }
}
