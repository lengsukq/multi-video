import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_processed_video/flutter_realtime_processed_video.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(
    'flutter_realtime_processed_video/android_system_screen_capture',
  );
  final capture = AndroidSystemScreenCapture.instance;

  Map<String, Object?> source(String id) => {
    'id': id,
    'kind': 'nativeFrameHub',
    'platform': 'android',
    'width': 720,
    'height': 1280,
    'frameRate': 15.0,
  };

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() async {
    await capture.stop();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('Android runtime availability comes from native capture', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'androidScreenCaptureAvailable') return true;
          return null;
        });
    expect(await capture.isAvailable, isTrue);
  });

  test('successful Android capture returns a native FrameHub source', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'androidScreenCaptureStart') {
            return source('android-first');
          }
          return null;
        });
    final first = await capture.start();
    expect(first.id, 'android-first');
    expect(first.platform, ProcessedVideoPlatform.android);
    expect(capture.source, same(first));
    await expectLater(capture.start(), throwsA(isA<StateError>()));
  });

  test('Android capture handles pending cancellation cleanly', () async {
    final pending = Completer<Map<String, Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'androidScreenCaptureStart') return pending.future;
          return null;
        });
    final starting = capture.start();
    await Future<void>.delayed(Duration.zero);
    await capture.stop();
    pending.complete(source('stale'));
    await expectLater(starting, throwsA(isA<StateError>()));
    expect(capture.source, isNull);
  });
}
