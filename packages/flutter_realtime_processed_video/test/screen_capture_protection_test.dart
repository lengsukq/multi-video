import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_processed_video/flutter_realtime_processed_video.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channelName =
      'flutter_realtime_processed_video/test_screen_capture_protection';
  const channel = MethodChannel(channelName);

  Future<void> emitNativeState(bool captured) async {
    final codec = const StandardMethodCodec();
    final data = codec.encodeMethodCall(
      MethodCall('screenCaptureStateChanged', <String, Object?>{
        'captured': captured,
      }),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channelName, data, (_) {});
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('enables native protection on iOS and tracks capture changes', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final calls = <MethodCall>[];
    var nativeCaptured = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'setProtectionEnabled') {
            return nativeCaptured;
          }
          if (call.method == 'isExternalScreenCaptured') {
            return nativeCaptured;
          }
          return null;
        });

    final service = SystemScreenCaptureProtection(channel: channel);
    final lease = await service.acquire();
    expect(lease.isCaptured, isTrue);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'setProtectionEnabled');
    expect(calls.single.arguments, <String, Object?>{
      'enabled': true,
      'suspendSecureWindow': false,
    });

    final observed = <bool>[];
    final sub = lease.changes.listen(observed.add);

    nativeCaptured = false;
    await emitNativeState(false);
    expect(lease.isCaptured, isFalse);
    expect(observed, <bool>[false]);

    nativeCaptured = true;
    await emitNativeState(true);
    expect(lease.isCaptured, isTrue);
    expect(observed, <bool>[false, true]);

    await sub.cancel();
    await lease.release();
    expect(calls.last.arguments, <String, Object?>{
      'enabled': false,
      'suspendSecureWindow': false,
    });
    expect(lease.isCaptured, isFalse);
  });

  test(
    'reference-counts overlapping leases and merges suspendSecureWindow on Android',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <Map<String, Object?>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'setProtectionEnabled') {
              calls.add(
                Map<String, Object?>.from(
                  call.arguments as Map<Object?, Object?>,
                ),
              );
              return false;
            }
            return false;
          });

      final service = SystemScreenCaptureProtection(channel: channel);
      final roomA = await service.acquire();
      final roomB = await service.acquire();
      expect(calls.last, <String, Object?>{
        'enabled': true,
        'suspendSecureWindow': false,
      });

      await roomB.setSuspendSecureWindow(true);
      expect(calls.last, <String, Object?>{
        'enabled': true,
        'suspendSecureWindow': true,
      });

      // Releasing Room A keeps protection active for Room B.
      await roomA.release();
      expect(calls.last, <String, Object?>{
        'enabled': true,
        'suspendSecureWindow': true,
      });

      await roomB.setSuspendSecureWindow(false);
      expect(calls.last, <String, Object?>{
        'enabled': true,
        'suspendSecureWindow': false,
      });

      await roomB.release();
      expect(calls.last, <String, Object?>{
        'enabled': false,
        'suspendSecureWindow': false,
      });
    },
  );

  test('operates as a safe no-op on macOS and Windows', () async {
    var invoked = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          invoked = true;
          return true;
        });

    for (final platform in <TargetPlatform>[
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      final service = SystemScreenCaptureProtection(channel: channel);
      expect(service.isSupportedPlatform, isFalse);
      final lease = await service.acquire();
      expect(lease.isCaptured, isFalse);
      expect(await lease.refresh(), isFalse);
      await lease.release();
    }
    expect(invoked, isFalse);
  });

  test(
    'tolerates MissingPluginException in headless test environments',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final service = SystemScreenCaptureProtection(channel: channel);
      final lease = await service.acquire();
      expect(lease.isCaptured, isFalse);
      expect(await lease.refresh(), isFalse);
      await lease.release();
    },
  );
}
