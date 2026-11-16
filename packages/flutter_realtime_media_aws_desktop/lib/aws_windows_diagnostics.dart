/// A stable, actionable reason why an experimental Windows AWS media host
/// cannot be used. Diagnoses describe transport readiness, never call E2E.
enum AwsWindowsRuntimeIssueCode {
  unsupportedPlatform,
  webView2Missing,
  webView2DetectionFailed,
  assetLoadFailed,
  webView2InitializationFailed,
  pageLoadFailed,
  invalidBrowserProbe,
  insecureBrowserContext,
  webRtcApiUnavailable,
  mediaApiUnavailable,
  providerSdkUnavailable,
  mediaBridgeUnavailable,
  hostBridgeUnavailable,
  unexpectedError,
}

class AwsWindowsRuntimeDiagnostic {
  const AwsWindowsRuntimeDiagnostic({
    required this.code,
    required this.message,
    required this.suggestion,
  });

  final AwsWindowsRuntimeIssueCode code;
  final String message;
  final String suggestion;

  /// A missing/incompatible API is unsupported; operational failures are
  /// reported as failed, not as a claim that WebView2 was never installed.
  bool get isUnsupported => switch (code) {
    AwsWindowsRuntimeIssueCode.unsupportedPlatform ||
    AwsWindowsRuntimeIssueCode.webView2Missing ||
    AwsWindowsRuntimeIssueCode.insecureBrowserContext ||
    AwsWindowsRuntimeIssueCode.webRtcApiUnavailable ||
    AwsWindowsRuntimeIssueCode.mediaApiUnavailable => true,
    _ => false,
  };

  String get userMessage => '$message $suggestion';

  static const unsupportedPlatform = AwsWindowsRuntimeDiagnostic(
    code: AwsWindowsRuntimeIssueCode.unsupportedPlatform,
    message: 'AWS desktop media requires Windows and a working WebView2 host.',
    suggestion: 'Use a supported Windows host to join.',
  );

  static const webView2Missing = AwsWindowsRuntimeDiagnostic(
    code: AwsWindowsRuntimeIssueCode.webView2Missing,
    message: 'Microsoft Edge WebView2 Runtime was not detected.',
    suggestion: 'Install or repair Microsoft Edge WebView2 Runtime, then restart the app.',
  );

  static const webView2DetectionFailed = AwsWindowsRuntimeDiagnostic(
    code: AwsWindowsRuntimeIssueCode.webView2DetectionFailed,
    message: 'Unable to check the installed WebView2 Runtime.',
    suggestion: 'Check WebView2 installation and Windows permissions, then retry.',
  );

  static const assetLoadFailed = AwsWindowsRuntimeDiagnostic(
    code: AwsWindowsRuntimeIssueCode.assetLoadFailed,
    message: 'The bundled AWS JavaScript or bridge assets could not be loaded.',
    suggestion: 'Rebuild/reinstall the app and verify the Flutter asset bundle is complete.',
  );

  static const webView2InitializationFailed = AwsWindowsRuntimeDiagnostic(
    code: AwsWindowsRuntimeIssueCode.webView2InitializationFailed,
    message: 'WebView2 is detected but its browser instance could not start.',
    suggestion: 'Check the WebView2 user-data directory, Windows policy and permissions, then retry.',
  );

  static const pageLoadFailed = AwsWindowsRuntimeDiagnostic(
    code: AwsWindowsRuntimeIssueCode.pageLoadFailed,
    message: 'WebView2 started but its local AWS media page did not load.',
    suggestion: 'Check local virtual-host mapping and resource access, then restart the app.',
  );

  static const invalidBrowserProbe = AwsWindowsRuntimeDiagnostic(
    code: AwsWindowsRuntimeIssueCode.invalidBrowserProbe,
    message: 'The AWS media browser returned an invalid readiness result.',
    suggestion: 'Check the bundled JavaScript bridge and browser console logs.',
  );

  static const insecureBrowserContext = AwsWindowsRuntimeDiagnostic(
    code: AwsWindowsRuntimeIssueCode.insecureBrowserContext,
    message: 'The local WebView2 media page is not running in a secure context.',
    suggestion: 'Check the virtual HTTPS host mapping; camera and microphone APIs require a secure origin.',
  );

  static const webRtcApiUnavailable = AwsWindowsRuntimeDiagnostic(
    code: AwsWindowsRuntimeIssueCode.webRtcApiUnavailable,
    message: 'WebRTC APIs are unavailable in the current WebView2 environment.',
    suggestion: 'Update/repair Edge WebView2 and check browser or enterprise policy restrictions.',
  );

  static const mediaApiUnavailable = AwsWindowsRuntimeDiagnostic(
    code: AwsWindowsRuntimeIssueCode.mediaApiUnavailable,
    message: 'Camera/microphone browser APIs are unavailable in WebView2.',
    suggestion: 'Check media-device access policy, secure context and WebView2 compatibility.',
  );

  static AwsWindowsRuntimeDiagnostic providerSdkUnavailable(String providerId) =>
      AwsWindowsRuntimeDiagnostic(
        code: AwsWindowsRuntimeIssueCode.providerSdkUnavailable,
        message: 'The bundled AWS $providerId JavaScript SDK did not initialize.',
        suggestion: 'Check the $providerId script in the Flutter asset bundle and its browser load errors.',
      );

  static const mediaBridgeUnavailable = AwsWindowsRuntimeDiagnostic(
    code: AwsWindowsRuntimeIssueCode.mediaBridgeUnavailable,
    message: 'The shared AWS media JavaScript bridge did not initialize.',
    suggestion: 'Check media-provider-bridge.js and the bundled provider SDK version.',
  );

  static const hostBridgeUnavailable = AwsWindowsRuntimeDiagnostic(
    code: AwsWindowsRuntimeIssueCode.hostBridgeUnavailable,
    message: 'The Windows AWS JavaScript message bridge did not initialize.',
    suggestion: 'Check windows_runtime.js, windows_host.js and WebView2 messaging.',
  );

  static const unexpectedError = AwsWindowsRuntimeDiagnostic(
    code: AwsWindowsRuntimeIssueCode.unexpectedError,
    message: 'An unexpected error occurred while checking AWS media readiness.',
    suggestion: 'Retry and inspect the Windows browser/runtime diagnostics.',
  );

  /// Diagnose a successful navigation that still lacks required capabilities.
  /// A missing SDK is distinct from a missing WebView2 installation.
  static AwsWindowsRuntimeDiagnostic? fromBrowserProbe({
    required String providerId,
    required String expectedOrigin,
    required Object? result,
  }) {
    if (result is! Map) return invalidBrowserProbe;
    if (result['origin'] != expectedOrigin || result['secure'] != true) {
      return insecureBrowserContext;
    }
    if (result['webrtc'] != true) return webRtcApiUnavailable;
    if (result['media'] != true || result['mediaEnumeration'] != true) {
      return mediaApiUnavailable;
    }
    if (result[providerId] != true) return providerSdkUnavailable(providerId);
    if (result['provider'] != true) return mediaBridgeUnavailable;
    if (result['transport'] != true || result['host'] != true) {
      return hostBridgeUnavailable;
    }
    return null;
  }
}

/// Enumeration cannot prove whether missing devices were unplugged, denied
/// by policy, or simply hidden before permission is granted.
String awsWindowsDeviceUnavailableMessage(String kind) =>
    'No $kind was detected (or WebView2 cannot access it). '
    'Connect a $kind and check Windows Settings > Privacy & security '
    '> $kind access.';

String awsWindowsDeviceEnumerationFailure(Object error) {
  final message = error.toString().toLowerCase();
  if (message.contains('notallowederror') ||
      message.contains('permission denied') ||
      message.contains('access denied') ||
      message.contains('securityerror')) {
    return 'Windows/WebView2 blocked media-device enumeration. '
        'Check camera and microphone privacy permissions and browser policy.';
  }
  if (message.contains('notfounderror') ||
      message.contains('device not found')) {
    return 'No usable camera or microphone was found by WebView2. '
        'Connect a device and check Windows privacy settings.';
  }
  return 'Could not enumerate media devices in WebView2. '
      'Check Windows device permissions and restart the app.';
}
