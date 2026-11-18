import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multi_video/demo_provider_catalog.dart';

const _backendUrl = String.fromEnvironment('AWS_CHIME_TEST_BACKEND_URL');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'SDK example macOS AWS Chime joins using the actual backend',
    (tester) async {
      if (_backendUrl.isEmpty) {
        markTestSkipped('Set AWS_CHIME_TEST_BACKEND_URL to run the live test.');
        return;
      }
      final base = Uri.parse(_backendUrl);
      final http = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final code = 'aws${DateTime.now().millisecondsSinceEpoch % 100000000}';
      RealtimeConnection? connection;
      try {
        final request = await http.getUrl(base.resolve('/health'));
        final response = await request.close();
        final json =
            jsonDecode(await utf8.decoder.bind(response).join())
                as Map<String, dynamic>;
        if (json['activeProvider'] != 'aws') {
          markTestSkipped(
            'Test backend is not using AWS; leaving it unchanged.',
          );
          return;
        }
        final sdk = Realtime(
          backendUrl: _backendUrl,
          providers: createDemoProviders(),
        );
        debugPrint('[SDK AWS E2E] Creating AWS Chime meeting in SDK example');
        connection = await sdk
            .open(
              RealtimeRequest.create(
                type: RealtimeExperience.meeting,
                roomCode: code,
                user: const RealtimeUser(
                  id: 'sdk-test-local',
                  name: 'SDK local diagnostic',
                ),
              ),
            )
            .timeout(const Duration(seconds: 55));
        debugPrint(
          '[SDK AWS E2E] Joined provider=${connection.providerId} '
          'engine=${connection.mediaEngineProviderId}',
        );
        expect(connection.providerId, 'aws');
        expect(connection.mediaEngineProviderId, 'chime');
      } on RealtimeException catch (e) {
        debugPrint(
          '[SDK AWS E2E] code=${e.code} operation=${e.operation} '
          'provider=${e.providerId} message=${e.message}',
        );
        Object? cause = e.cause;
        for (var level = 0; level < 6 && cause != null; level++) {
          if (cause is RealtimeException) {
            debugPrint(
              '[SDK AWS E2E] cause level=$level '
              'code=${cause.code} message=${cause.message}',
            );
            cause = cause.cause;
          } else if (cause is PlatformException) {
            debugPrint(
              '[SDK AWS E2E] PlatformException '
              'code=${cause.code} message=${cause.message}',
            );
            break;
          } else {
            debugPrint(
              '[SDK AWS E2E] cause level=$level '
              'type=${cause.runtimeType}',
            );
            break;
          }
        }
        rethrow;
      } finally {
        try {
          await connection?.dispose().timeout(const Duration(seconds: 12));
        } catch (error) {
          debugPrint('[SDK AWS E2E] disposal error type=${error.runtimeType}');
        }
        try {
          final request = await http.deleteUrl(base.resolve('/rooms/$code'));
          final response = await request.close().timeout(
            const Duration(seconds: 15),
          );
          debugPrint(
            '[SDK AWS E2E] test room cleanup HTTP ${response.statusCode}',
          );
          await response.drain<void>();
        } catch (error) {
          debugPrint('[SDK AWS E2E] cleanup error type=${error.runtimeType}');
        }
        http.close(force: true);
      }
    },
    skip: _backendUrl.isEmpty,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
