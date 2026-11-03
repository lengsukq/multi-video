import 'package:flutter/foundation.dart';
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'missing browser script reports a typed asset-loading failure',
    () async {
      if (!kIsWeb) return;

      await expectLater(
        loadRealtimeBundledWebScript(
          'assets/__flutter_realtime_sdk_deliberately_missing_test__.js',
        ),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.webSdkUnavailable,
          ),
        ),
      );
    },
  );

  test('legacy all-provider asset helper remains a safe no-op', () async {
    if (!kIsWeb) return;
    await ensureRealtimeProviderWebAssets(includeProductChat: true);
  });
}
