import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_webview2_runtime.dart';
import 'package:flutter_realtime_media_chime/flutter_realtime_media_chime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows WebView2 loads bundled Chime JS with secure origin', (
    WidgetTester tester,
  ) async {
    expect(defaultTargetPlatform, TargetPlatform.windows);
    // No --dart-define is necessary for Windows Chime.
    expect(await probeNativeChimeAvailability(), isTrue);
    final runtime = AwsWindowsWebView2Runtime.instance;
    final available = await runtime.probe();
    expect(available, isTrue, reason: runtime.lastError);
    expect(runtime.lastDiagnostic, isNull,
        reason: 'A healthy Chime WebView2 host must not report missing runtime.');
    expect(runtime.lastProbe['secure'], isTrue);
    expect(runtime.lastProbe['webrtc'], isTrue);
    expect(runtime.lastProbe['mediaEnumeration'], isTrue);
    expect(runtime.lastProbe['host'], isTrue);
    expect(runtime.lastProbe['chime'], isTrue);
    expect(runtime.lastProbe['provider'], isTrue);
    // An unauthenticated join must fail via the real JavaScript RPC channel,
    // not hang or report a false successful native session.
    await expectLater(
      runtime.invoke('invoke', name: 'join'),
      throwsA(isA<StateError>()),
    );
    await runtime.dispose();
  });
}
