import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_processed_video/flutter_realtime_processed_video.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(
    'flutter_realtime_processed_video/ios_system_screen_capture',
  );
  final capture = IosSystemScreenCapture.instance;

  Map<String, Object?> source(String id) => {
    'id': id,
    'kind': 'nativeFrameHub',
    'platform': 'ios',
    'width': 1170,
    'height': 2532,
    'frameRate': 30.0,
  };

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });

  tearDown(() async {
    await capture.stop();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('iOS runtime availability comes from the native picker', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'iosScreenCaptureKitAvailable') return true;
          return null;
        });
    expect(await capture.isAvailable, isTrue);
  });

  test('successful capture returns a native FrameHub source', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'iosScreenCaptureKitStart') return source('first');
          return null;
        });
    final first = await capture.start();
    expect(first.id, 'first');
    expect(capture.source, same(first));
    await expectLater(capture.start(), throwsA(isA<StateError>()));
  });

  test(
    'a pending system picker cannot resurrect an already stopped source',
    () async {
      final selected = Completer<Map<String, Object?>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'iosScreenCaptureKitStart') {
              return selected.future;
            }
            return null;
          });
      final starting = capture.start();
      await Future<void>.delayed(Duration.zero);
      await capture.stop();
      selected.complete(source('stale'));
      await expectLater(starting, throwsA(isA<StateError>()));
      expect(capture.source, isNull);
    },
  );

  test('native start failure leaves capture available for retry', () async {
    var attempts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'iosScreenCaptureKitStart') {
            attempts++;
            if (attempts == 1) {
              throw PlatformException(code: 'screen_capture_cancelled');
            }
            return source('retry');
          }
          return null;
        });
    await expectLater(capture.start(), throwsA(isA<PlatformException>()));
    expect(capture.source, isNull);
    expect((await capture.start()).id, 'retry');
  });
}
