import 'package:flutter/foundation.dart';
import 'package:flutter_realtime_chat_agora/src/agora_chat_engine_windows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows Agora Chat loads bundled SDK and isolated WebView2 RPC',
      (tester) async {
    expect(defaultTargetPlatform, TargetPlatform.windows);
    final engine = WindowsAgoraChatEngine();
    try {
      expect(await engine.probe(), isTrue,
          reason: 'Agora Chat Windows browser or JavaScript bridge not ready.');
      expect(
        () => engine.sendMessage('cannot send before room join'),
        throwsStateError,
      );
    } finally {
      await engine.dispose();
    }
  });
}
