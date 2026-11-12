import 'package:flutter_realtime_media_aws_desktop/aws_windows_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const origin = 'https://aws-chime-local.invalid';
  final ready = <String, Object?>{
    'origin': origin,
    'secure': true,
    'webrtc': true,
    'media': true,
    'mediaEnumeration': true,
    'chime': true,
    'provider': true,
    'transport': true,
    'host': true,
  };
  AwsWindowsRuntimeIssueCode? diagnose(Map<String, Object?> values) =>
      AwsWindowsRuntimeDiagnostic.fromBrowserProbe(
        providerId: 'chime',
        expectedOrigin: origin,
        result: values,
      )?.code;

  test('healthy WebView2 host is not diagnosed as missing', () {
    expect(diagnose(ready), isNull);
    expect(AwsWindowsRuntimeDiagnostic.fromBrowserProbe(
      providerId: 'ivs',
      expectedOrigin: 'https://aws-ivs-local.invalid',
      result: {...ready, 'origin': 'https://aws-ivs-local.invalid', 'ivs': true},
    ), isNull);
  });

  test('missing Runtime is distinct from a failed WebView2 startup', () {
    expect(AwsWindowsRuntimeDiagnostic.webView2Missing.code,
        AwsWindowsRuntimeIssueCode.webView2Missing);
    expect(AwsWindowsRuntimeDiagnostic.webView2InitializationFailed.code,
        AwsWindowsRuntimeIssueCode.webView2InitializationFailed);
    expect(AwsWindowsRuntimeDiagnostic.webView2Missing.isUnsupported, isTrue);
    expect(AwsWindowsRuntimeDiagnostic.webView2InitializationFailed.isUnsupported,
        isFalse);
    expect(AwsWindowsRuntimeDiagnostic.assetLoadFailed.userMessage,
        contains('Rebuild/reinstall'));
  });

  test('browser failures identify API, SDK and messaging separately', () {
    expect(AwsWindowsRuntimeDiagnostic.fromBrowserProbe(
      providerId: 'chime', expectedOrigin: origin, result: null,
    )?.code, AwsWindowsRuntimeIssueCode.invalidBrowserProbe);
    final cases = <String, AwsWindowsRuntimeIssueCode>{
      'secure': AwsWindowsRuntimeIssueCode.insecureBrowserContext,
      'webrtc': AwsWindowsRuntimeIssueCode.webRtcApiUnavailable,
      'media': AwsWindowsRuntimeIssueCode.mediaApiUnavailable,
      'mediaEnumeration': AwsWindowsRuntimeIssueCode.mediaApiUnavailable,
      'chime': AwsWindowsRuntimeIssueCode.providerSdkUnavailable,
      'provider': AwsWindowsRuntimeIssueCode.mediaBridgeUnavailable,
      'transport': AwsWindowsRuntimeIssueCode.hostBridgeUnavailable,
      'host': AwsWindowsRuntimeIssueCode.hostBridgeUnavailable,
    };
    for (final entry in cases.entries) {
      expect(diagnose({...ready, entry.key: false}), entry.value,
          reason: entry.key);
    }
    expect(diagnose({...ready, 'origin': 'https://other.invalid'}),
        AwsWindowsRuntimeIssueCode.insecureBrowserContext);
  });

  test('a missing camera never means WebView2 itself is absent', () {
    expect(awsWindowsDeviceUnavailableMessage('camera'), contains('camera'));
    expect(awsWindowsDeviceUnavailableMessage('camera'), contains('Privacy'));
    expect(awsWindowsDeviceEnumerationFailure(
      StateError('NotAllowedError: Permission denied'),
    ), contains('blocked media-device enumeration'));
    expect(awsWindowsDeviceEnumerationFailure(
      StateError('NotFoundError: device not found'),
    ), contains('No usable camera or microphone'));
    expect(awsWindowsDeviceEnumerationFailure(
      StateError('Unknown error'),
    ), contains('Could not enumerate'));
  });
}
