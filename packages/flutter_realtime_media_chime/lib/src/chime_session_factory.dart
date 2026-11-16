import 'package:flutter/foundation.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_diagnostics.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_webview2_runtime.dart';
import 'package:flutter_aws_chime/flutter_aws_chime.dart' as chime;
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'chime_join_info.dart';
import 'chime_media_session.dart';

typedef ChimeMeetingSessionFactory = chime.ChimeMeetingSession Function();
typedef ChimeAvailabilityProbe = Future<bool> Function();
typedef ChimeWindowsDevicesProbe =
    Future<({int microphones, int cameras})> Function();
typedef ChimeWindowsDiagnosticProbe = AwsWindowsRuntimeDiagnostic? Function();

Future<({int microphones, int cameras})> probeWindowsChimeDevices() async {
  final raw = await AwsWindowsWebView2Runtime.instance.invoke('probeDevices');
  final devices = Map<String, dynamic>.from(raw as Map<Object?, Object?>);
  return (
    microphones: (devices['microphones'] as num?)?.toInt() ?? 0,
    cameras: (devices['cameras'] as num?)?.toInt() ?? 0,
  );
}

/// Default-enabled Windows WebView2 transport readiness, not a real-call E2E.
///
/// Do not assume a Chime Windows meeting can start simply because the Dart
/// package (and its iOS/Android native bindings) is linked into the build.
Future<bool> probeNativeChimeAvailability() async {
  if (kIsWeb) return false;
  if (defaultTargetPlatform != TargetPlatform.windows) return true;
  if (!const bool.fromEnvironment(
      'AWS_CHIME_WINDOWS_WEBVIEW2_EXPERIMENTAL',
      defaultValue: true,
  )) {
    return false;
  }
  try {
    return await AwsWindowsWebView2Runtime.instance.probe();
  } on Exception {
    return false;
  }
}

/// Registers the existing flutter_aws_chime implementation with [MediaClient].
class ChimeSessionFactory implements MediaSessionFactory, MediaPreJoinProbe {
  ChimeSessionFactory({
    ChimeMeetingSessionFactory? sessionFactory,
    this.availabilityProbe = probeNativeChimeAvailability,
    this.windowsDeviceProbe = probeWindowsChimeDevices,
    ChimeWindowsDiagnosticProbe? windowsDiagnosticProbe,
  }) : _sessionFactory = sessionFactory ?? chime.ChimeMeetingSession.new,
       windowsDiagnosticProbe = windowsDiagnosticProbe ??
           _defaultWindowsDiagnosticProbe;

  static AwsWindowsRuntimeDiagnostic? _defaultWindowsDiagnosticProbe() =>
      AwsWindowsWebView2Runtime.instance.lastDiagnostic;

  final ChimeMeetingSessionFactory _sessionFactory;
  final ChimeAvailabilityProbe availabilityProbe;
  final ChimeWindowsDevicesProbe windowsDeviceProbe;
  final ChimeWindowsDiagnosticProbe windowsDiagnosticProbe;

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
      final disabled = !const bool.fromEnvironment(
        'AWS_CHIME_WINDOWS_WEBVIEW2_EXPERIMENTAL', defaultValue: true);
      final diagnostic = disabled ? null : windowsDiagnosticProbe();
      return MediaPreJoinProbeResult([
        MediaPreJoinCheck(
          type: MediaPreJoinCheckType.provider,
          status: diagnostic == null || diagnostic.isUnsupported
              ? MediaPreJoinStatus.unsupported
              : MediaPreJoinStatus.failed,
          severity: MediaPreJoinSeverity.blocking,
          message: disabled
              ? 'Windows AWS Chime WebView2 was disabled in build settings. '
                  'Rebuild without AWS_CHIME_WINDOWS_WEBVIEW2_EXPERIMENTAL=false.'
              : diagnostic?.userMessage ??
                  'Windows Chime media readiness could not be verified. '
                  'Check WebView2 and the bundled AWS media SDK diagnostics.',
          details: diagnostic == null ? null :
              {'diagnosticCode': diagnostic.code.name},
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

    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows &&
        (request.requirements.microphone != MediaPreJoinRequirement.skipped ||
         request.requirements.camera != MediaPreJoinRequirement.skipped)) {
      try {
        final devices = await windowsDeviceProbe();
        void checkWindowsDevice(
          MediaPreJoinCheckType type,
          MediaPreJoinRequirement requirement,
          String label,
          int count,
        ) {
          if (requirement == MediaPreJoinRequirement.skipped) return;
          checks.add(MediaPreJoinCheck(
            type: type,
            status: count > 0
                ? MediaPreJoinStatus.passed
                : MediaPreJoinStatus.failed,
            severity: requirement.severity,
            message: count > 0
                ? 'Found $count Windows Chime $label device(s).'
                : awsWindowsDeviceUnavailableMessage(label),
          ));
        }
        checkWindowsDevice(
          MediaPreJoinCheckType.microphoneDevice,
          request.requirements.microphone,
          'microphone',
          devices.microphones,
        );
        checkWindowsDevice(
          MediaPreJoinCheckType.cameraDevice,
          request.requirements.camera,
          'camera',
          devices.cameras,
        );
      } catch (error) {
        for (final entry in [
          (MediaPreJoinCheckType.microphoneDevice,
           request.requirements.microphone),
          (MediaPreJoinCheckType.cameraDevice,
           request.requirements.camera),
        ]) {
          if (entry.$2 == MediaPreJoinRequirement.skipped) continue;
          checks.add(MediaPreJoinCheck(
            type: entry.$1,
            status: MediaPreJoinStatus.unknown,
            severity: entry.$2.severity,
            message: awsWindowsDeviceEnumerationFailure(error),
          ));
        }
      }
    } else {
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
    }
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
