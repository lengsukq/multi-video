import 'package:flutter/foundation.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_diagnostics.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_webview2_runtime.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'ivs_engine.dart';
import 'ivs_join_info.dart';
import 'ivs_media_session.dart';

class IvsSessionFactory implements MediaSessionFactory, MediaPreJoinProbe {
  const IvsSessionFactory({
    this.engineFactory = createNativeIvsEngine,
    this.deviceProbe = probeNativeIvsDevices,
    this.availabilityProbe = probeNativeIvsAvailability,
    this.windowsDiagnosticProbe = defaultWindowsIvsDiagnostic,
  });

  final IvsEngineFactory engineFactory;
  final IvsDeviceProbe deviceProbe;
  final IvsAvailabilityProbe availabilityProbe;
  final AwsWindowsRuntimeDiagnostic? Function() windowsDiagnosticProbe;

  static AwsWindowsRuntimeDiagnostic? defaultWindowsIvsDiagnostic() =>
      AwsWindowsWebView2Runtime.ivs.lastDiagnostic;

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
      final disabled = !const bool.fromEnvironment(
        'AWS_IVS_WINDOWS_WEBVIEW2_EXPERIMENTAL', defaultValue: true);
      final diagnostic = disabled ? null : windowsDiagnosticProbe();
      return MediaPreJoinProbeResult([
        MediaPreJoinCheck(
          type: MediaPreJoinCheckType.provider,
          status: diagnostic == null || diagnostic.isUnsupported
              ? MediaPreJoinStatus.unsupported
              : MediaPreJoinStatus.failed,
          severity: MediaPreJoinSeverity.blocking,
          message: disabled
              ? 'Windows AWS IVS WebView2 was disabled in build settings. '
                  'Rebuild without AWS_IVS_WINDOWS_WEBVIEW2_EXPERIMENTAL=false.'
              : diagnostic?.userMessage ??
                  'Windows IVS media readiness could not be verified. '
                  'Check WebView2 and the bundled AWS IVS SDK diagnostics. '
                  'AWS does not support embedded IVS WebViews.',
          details: diagnostic == null ? null :
              {'diagnosticCode': diagnostic.code.name},
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
                  : !kIsWeb &&
                        defaultTargetPlatform == TargetPlatform.windows
                      ? awsWindowsDeviceUnavailableMessage('microphone')
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
                  : !kIsWeb &&
                        defaultTargetPlatform == TargetPlatform.windows
                      ? awsWindowsDeviceUnavailableMessage('camera')
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
              message: !kIsWeb &&
                      defaultTargetPlatform == TargetPlatform.windows
                  ? awsWindowsDeviceEnumerationFailure(error)
                  : 'Unable to enumerate IVS microphone devices.',
              details: defaultTargetPlatform == TargetPlatform.windows
                  ? null : error,
            ),
          );
        }
        if (needsCamera) {
          checks.add(
            MediaPreJoinCheck(
              type: MediaPreJoinCheckType.cameraDevice,
              status: MediaPreJoinStatus.unknown,
              severity: request.requirements.camera.severity,
              message: !kIsWeb &&
                      defaultTargetPlatform == TargetPlatform.windows
                  ? awsWindowsDeviceEnumerationFailure(error)
                  : 'Unable to enumerate IVS camera devices.',
              details: defaultTargetPlatform == TargetPlatform.windows
                  ? null : error,
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
