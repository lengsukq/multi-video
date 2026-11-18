import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_diagnostics.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_webview2_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    expect(
      AwsWindowsRuntimeDiagnostic.fromBrowserProbe(
        providerId: 'ivs',
        expectedOrigin: 'https://aws-ivs-local.invalid',
        result: {
          ...ready,
          'origin': 'https://aws-ivs-local.invalid',
          'ivs': true,
        },
      ),
      isNull,
    );
  });

  test('missing Runtime is distinct from a failed WebView2 startup', () {
    expect(
      AwsWindowsRuntimeDiagnostic.webView2Missing.code,
      AwsWindowsRuntimeIssueCode.webView2Missing,
    );
    expect(
      AwsWindowsRuntimeDiagnostic.webView2InitializationFailed.code,
      AwsWindowsRuntimeIssueCode.webView2InitializationFailed,
    );
    expect(AwsWindowsRuntimeDiagnostic.webView2Missing.isUnsupported, isTrue);
    expect(
      AwsWindowsRuntimeDiagnostic.webView2InitializationFailed.isUnsupported,
      isFalse,
    );
    expect(
      AwsWindowsRuntimeDiagnostic.assetLoadFailed.userMessage,
      contains('Rebuild/reinstall'),
    );
  });

  test('browser failures identify API, SDK and messaging separately', () {
    expect(
      AwsWindowsRuntimeDiagnostic.fromBrowserProbe(
        providerId: 'chime',
        expectedOrigin: origin,
        result: null,
      )?.code,
      AwsWindowsRuntimeIssueCode.invalidBrowserProbe,
    );
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
      expect(
        diagnose({...ready, entry.key: false}),
        entry.value,
        reason: entry.key,
      );
    }
    expect(
      diagnose({...ready, 'origin': 'https://other.invalid'}),
      AwsWindowsRuntimeIssueCode.insecureBrowserContext,
    );
  });

  test('a missing camera never means WebView2 itself is absent', () {
    expect(awsWindowsDeviceUnavailableMessage('camera'), contains('camera'));
    expect(awsWindowsDeviceUnavailableMessage('camera'), contains('Privacy'));
    expect(
      awsWindowsDeviceEnumerationFailure(
        StateError('NotAllowedError: Permission denied'),
      ),
      contains('blocked media-device enumeration'),
    );
    expect(
      awsWindowsDeviceEnumerationFailure(
        StateError('NotFoundError: device not found'),
      ),
      contains('No usable camera or microphone'),
    );
    expect(
      awsWindowsDeviceEnumerationFailure(StateError('Unknown error')),
      contains('Could not enumerate'),
    );
  });

  test(
    'Windows WebView2 runtime bridges processed frames with single-in-flight coalescing and propagates source errors',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        AwsWindowsWebView2Runtime.debugResetWindowsChannelHandler();
      });

      const windowsChannel = MethodChannel(
        'com.oneplusdream.flutter_realtime_media_aws_desktop/windows',
      );
      const effectsChannel = MethodChannel('flutter_realtime_video_effects');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      final sequence = <String>[];
      final nativeCalls = <MethodCall>[];
      final effectCalls = <MethodCall>[];
      final postedFrames = <Map<String, dynamic>>[];
      Completer<void>? inFlightFrameGate;

      late final AwsWindowsWebView2Runtime runtime;
      runtime = AwsWindowsWebView2Runtime.forTesting(
        'chime',
        probeOverride: () async => true,
        postWebMessageOverride: (encoded) async {
          final decoded = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
          if (decoded['kind'] == 'processedFrame') {
            postedFrames.add(decoded);
            final gate = inFlightFrameGate;
            if (gate != null) {
              await gate.future;
            }
            return;
          }
          sequence.add('js:${decoded['operation']}');
          runtime.debugHandleWebMessage({
            'channel': 'aws-windows-chime-v1',
            'kind': 'result',
            'id': decoded['id'],
            'success': true,
            'value': true,
          });
        },
      );
      addTearDown(runtime.dispose);

      messenger.setMockMethodCallHandler(windowsChannel, (call) async {
        nativeCalls.add(call);
        sequence.add('native:${call.method}');
        if (call.method == 'probeProcessedVideoInput') return true;
        return null;
      });
      messenger.setMockMethodCallHandler(effectsChannel, (call) async {
        effectCalls.add(call);
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowsChannel, null);
        messenger.setMockMethodCallHandler(effectsChannel, null);
      });

      expect(await runtime.probeProcessedVideoInput(), isTrue);
      sequence.clear();

      await runtime.attachProcessedVideoSource('win_effects_9');
      // JS canvas source must be attached BEFORE C++ FrameHub starts pushing frames.
      expect(sequence, [
        'js:attachProcessedVideo',
        'native:subscribeProcessedVideo',
      ]);

      inFlightFrameGate = Completer<void>();
      Future<void> pushFrame(int ts, String data) =>
          messenger.handlePlatformMessage(
            windowsChannel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('onProcessedFrame', {
                'sourceId': 'win_effects_9',
                'timestampNs': ts,
                'data': data,
              }),
            ),
            (_) {},
          );

      await pushFrame(100, 'data:image/jpeg;base64,FRAME1');
      await pushFrame(200, 'data:image/jpeg;base64,FRAME2_DROPPED');
      await pushFrame(300, 'data:image/jpeg;base64,FRAME3_LATEST');
      expect(postedFrames, hasLength(1));

      inFlightFrameGate.complete();
      inFlightFrameGate = null;
      await pumpEventQueue();
      expect(postedFrames.map((f) => f['timestampNs']).toList(), [100, 300]);

      // Simulate JS canvas decode error and confirm native + effects error forwarding.
      runtime.debugHandleWebMessage(
        jsonEncode({
          'kind': 'processedVideoError',
          'sourceId': 'win_effects_9',
          'message': 'corrupt jpeg frame',
        }),
      );
      await pumpEventQueue();
      expect(
        nativeCalls.any((c) => c.method == 'reportProcessedVideoError'),
        isTrue,
      );
      expect(
        effectCalls.any(
          (c) =>
              c.method == 'sourceError' &&
              (c.arguments as Map)['sourceId'] == 'win_effects_9',
        ),
        isTrue,
      );

      await runtime.detachProcessedVideoSource();
      expect(
        nativeCalls.any((c) => c.method == 'unsubscribeProcessedVideo'),
        isTrue,
      );
    },
  );
}
