import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_aws_chime/flutter_aws_chime.dart' as chime;
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'chime_join_info.dart';
import 'chime_media_session.dart';

typedef ChimeMeetingSessionFactory = chime.ChimeMeetingSession Function();
typedef ChimeAvailabilityProbe = Future<bool> Function();

/// A C++ Windows Chime runtime must register its native meeting bridge.
///
/// Do not assume a Chime Windows meeting can start simply because the Dart
/// package (and its iOS/Android native bindings) is linked into the build.
Future<bool> probeNativeChimeAvailability() async {
  if (kIsWeb) return false;
  if (defaultTargetPlatform != TargetPlatform.windows) return true;
  const channel = MethodChannel('com.oneplusdream.aws.chime.methodChannel');
  try {
    return await channel.invokeMethod<bool>('isAvailable') ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// Registers the existing flutter_aws_chime implementation with [MediaClient].
class ChimeSessionFactory implements MediaSessionFactory, MediaPreJoinProbe {
  ChimeSessionFactory({
    ChimeMeetingSessionFactory? sessionFactory,
    this.availabilityProbe = probeNativeChimeAvailability,
  }) : _sessionFactory = sessionFactory ?? chime.ChimeMeetingSession.new;

  final ChimeMeetingSessionFactory _sessionFactory;
  final ChimeAvailabilityProbe availabilityProbe;

  @override
  String get providerId => ChimeJoinInfo.providerIdValue;

  @override
  Set<MediaRole> get supportedRoles => const {MediaRole.participant};

  @override
  ChimeJoinInfo parseJoinInfo(Map<String, dynamic> json) =>
      ChimeJoinInfo.fromBackendResponse(json);

  @override
  ChimeMediaSession createSession(MediaJoinInfo joinInfo) {
    if (joinInfo is! ChimeJoinInfo || joinInfo.role != MediaRole.participant) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'ChimeSessionFactory requires participant ChimeJoinInfo.',
        providerId: ChimeJoinInfo.providerIdValue,
      );
    }
    return ChimeMediaSession(session: _sessionFactory());
  }

  @override
  Future<MediaPreJoinProbeResult> runPreJoinProbe(
    MediaPreJoinProbeRequest request,
  ) async {
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows &&
        !await availabilityProbe()) {
      return const MediaPreJoinProbeResult([
        MediaPreJoinCheck(
          type: MediaPreJoinCheckType.provider,
          status: MediaPreJoinStatus.unsupported,
          severity: MediaPreJoinSeverity.blocking,
          message:
              'Amazon Chime Windows native meeting bridge is not installed or ready.',
        ),
      ]);
    }
    // Keep the previous default diagnostics: adding the Windows capability
    // probe must not silently remove microphone/camera/network warnings from
    // iOS, Android or macOS callers.
    final checks = <MediaPreJoinCheck>[];
    void addDevice(
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
          message: 'Chime does not expose pre-join $label enumeration.',
        ),
      );
    }

    addDevice(
      MediaPreJoinCheckType.microphoneDevice,
      request.requirements.microphone,
      'microphone',
    );
    addDevice(
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
              'Chime requires provider-issued credentials for a native network probe.',
        ),
      );
    }
    return MediaPreJoinProbeResult(List.unmodifiable(checks));
  }
}
