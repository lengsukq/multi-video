import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_webview2_runtime.dart';
import 'package:flutter_realtime_media_ivs/flutter_realtime_media_ivs.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('experimental IVS WebView2 isolates and loads the Stage SDK', (
    WidgetTester tester,
  ) async {
    expect(defaultTargetPlatform, TargetPlatform.windows);
    // No --dart-define is necessary for the experimental Windows IVS bridge.
    expect(await probeNativeIvsAvailability(), isTrue);
    final runtime = AwsWindowsWebView2Runtime.ivs;
    try {
      final ready = await runtime.probe();
      expect(ready, isTrue, reason: runtime.lastError);
      expect(runtime.lastDiagnostic, isNull,
          reason: 'A healthy IVS host must not report missing WebView2.');
      expect(runtime.lastProbe['origin'], 'https://aws-ivs-local.invalid');
      expect(runtime.lastProbe['secure'], isTrue);
      expect(runtime.lastProbe['mediaEnumeration'], isTrue);
      expect(runtime.lastProbe['host'], isTrue);
      expect(runtime.lastProbe['ivs'], isTrue);
      expect(runtime.lastProbe['chime'], isFalse);
      expect(runtime.lastProbe['provider'], isTrue);
      final devices = await runtime.invoke('probeDevices');
      expect(devices, isA<Map<Object?, Object?>>());
      // Join without a created Stage must reject through the JS bridge,
      // never fabricate a successful native session or call AWS.
      await expectLater(
        runtime.invoke('invoke', name: 'join'),
        throwsA(isA<StateError>()),
      );
    } finally {
      await runtime.dispose();
    }
  });
}
