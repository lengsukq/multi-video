import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import 'aws_windows_diagnostics.dart';

enum _AwsWindowsStartupStep {
  runtimeDetection,
  assets,
  browserInitialization,
  pageNavigation,
  browserProbe,
}

/// Experimental transport equivalent to the macOS WebKit JS runtime.
///
/// Embedded WebView2 is not an AWS-supported IVS Web Broadcast host.
/// The Windows bridge is enabled by default but needs runtime checks and
/// real-device E2E validation; a JS probe is not production certification.
class AwsWindowsWebView2Runtime {
  AwsWindowsWebView2Runtime._(this.providerId);

  static final instance = AwsWindowsWebView2Runtime._('chime');
  static final ivs = AwsWindowsWebView2Runtime._('ivs');
  final String providerId;
  String get _origin => 'https://aws-$providerId-local.invalid';
  String get _channel => 'aws-windows-$providerId-v1';
  String get _sessionId => 'aws-desktop-$providerId';

  WebviewController? _controller;
  Directory? _temporaryAssets;
  StreamSubscription<dynamic>? _subscription;
  Future<bool>? _initializing;
  bool _ready = false;
  String? lastError;
  AwsWindowsRuntimeDiagnostic? lastDiagnostic;
  Map<String, dynamic> lastProbe = const {};
  int _nextCallId = 0;
  final _pending = <int, Completer<dynamic>>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _frames = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get events => _events.stream;
  Stream<Map<String, dynamic>> get frames => _frames.stream;
  bool get isReady => _ready;

  void _diagnose(AwsWindowsRuntimeDiagnostic diagnostic) {
    lastDiagnostic = diagnostic;
    lastError = diagnostic.userMessage;
  }

  /// Checks the actual Windows Chromium runtime and loads the same bundled
  /// Chime JS/media bridge that is used by the macOS desktop implementation.
  ///
  /// This is a transport readiness probe, NOT a passed Chime media-call E2E.
  Future<bool> probe() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      _diagnose(AwsWindowsRuntimeDiagnostic.unsupportedPlatform);
      return Future<bool>.value(false);
    }
    if (_ready) return Future<bool>.value(true);
    return _initializing ??= _initialize().whenComplete(() {
      _initializing = null;
    });
  }

  Future<bool> _initialize() async {
    WebviewController? browser;
    var step = _AwsWindowsStartupStep.runtimeDetection;
    lastError = null;
    lastDiagnostic = null;
    lastProbe = const {};
    try {
      if (await WebviewController.getWebViewVersion() == null) {
        _diagnose(AwsWindowsRuntimeDiagnostic.webView2Missing);
        return false;
      }
      step = _AwsWindowsStartupStep.assets;
      final files = await Directory.systemTemp.createTemp('aws-$providerId-wv2-');
      _temporaryAssets = files;

      final sdkFile = providerId == 'ivs'
          ? 'amazon-ivs-web-broadcast.js' : 'chime-sdk.js';
      final resources = {
        sdkFile: 'packages/flutter_realtime_provider_aws/assets/$sdkFile',
        'media-provider-bridge.js':
            'packages/flutter_realtime_media_web/assets/media-provider-bridge.js',
        'windows_runtime.js':
            'packages/flutter_realtime_media_aws_desktop/assets/windows_runtime.js',
        'windows_host.js':
            'packages/flutter_realtime_media_aws_desktop/assets/windows_host.js',
      };
      for (final entry in resources.entries) {
        final source = await rootBundle.loadString(entry.value);
        await File('${files.path}${Platform.pathSeparator}${entry.key}')
            .writeAsString(source, flush: true);
      }
      await File('${files.path}${Platform.pathSeparator}index.html')
          .writeAsString('''
<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy"
 content="default-src 'self' https: wss: data: blob:; script-src 'self' 'unsafe-eval' 'unsafe-inline' https:; connect-src 'self' https: wss:; img-src 'self' data: blob: https:; media-src 'self' blob: https:; style-src 'self' 'unsafe-inline';">
</head><body><script src="windows_runtime.js"></script>
<script src="$sdkFile"></script>
<script src="media-provider-bridge.js"></script>
<script src="windows_host.js"></script></body></html>
''', flush: true);

      step = _AwsWindowsStartupStep.browserInitialization;
      browser = WebviewController();
      await browser.initialize();
      await browser.setSize(const Size(960, 540));
      await browser.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await browser.addVirtualHostNameMapping(
        'aws-$providerId-local.invalid',
        files.path,
        WebviewHostResourceAccessKind.deny,
      );
      _subscription = browser.webMessage.listen(_handleWebMessage);
      step = _AwsWindowsStartupStep.pageNavigation;
      final navigation = browser.loadingState
          .firstWhere((state) => state == LoadingState.navigationCompleted)
          .timeout(const Duration(seconds: 30));
      await browser.loadUrl('$_origin/index.html');
      await navigation;

      step = _AwsWindowsStartupStep.browserProbe;
      final state = await browser.executeScript('''JSON.stringify({
        origin: location.origin,
        secure: isSecureContext,
        webrtc: typeof RTCPeerConnection === 'function',
        media: !!(navigator.mediaDevices &&
                  navigator.mediaDevices.getUserMedia),
        mediaEnumeration: !!(navigator.mediaDevices &&
                             navigator.mediaDevices.enumerateDevices),
        chime: typeof ChimeSDK !== 'undefined',
        ivs: !!(globalThis.IVSBroadcastClient &&
                globalThis.IVSBroadcastClient.Stage),
        provider: typeof MediaProviderBridge !== 'undefined',
        transport: typeof AwsDesktopRuntime !== 'undefined',
        host: globalThis.__awsWindowsHostChannel === '$_channel'
      })''');
      final decoded = state is String ? jsonDecode(state) : state;
      lastProbe = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : {'raw': decoded?.toString()};
      final failure = AwsWindowsRuntimeDiagnostic.fromBrowserProbe(
        providerId: providerId,
        expectedOrigin: _origin,
        result: decoded,
      );
      if (failure != null) {
        _diagnose(failure);
        await browser.dispose();
        await _subscription?.cancel();
        _subscription = null;
        try {
          await _temporaryAssets?.delete(recursive: true);
        } catch (_) {}
        _temporaryAssets = null;
        return false;
      }
      _controller = browser;
      _ready = true;
      lastError = null;
      lastDiagnostic = null;
      return true;
    } catch (error) {
      _diagnose(switch (step) {
        _AwsWindowsStartupStep.runtimeDetection =>
          AwsWindowsRuntimeDiagnostic.webView2DetectionFailed,
        _AwsWindowsStartupStep.assets =>
          AwsWindowsRuntimeDiagnostic.assetLoadFailed,
        _AwsWindowsStartupStep.browserInitialization =>
          AwsWindowsRuntimeDiagnostic.webView2InitializationFailed,
        _AwsWindowsStartupStep.pageNavigation =>
          AwsWindowsRuntimeDiagnostic.pageLoadFailed,
        _AwsWindowsStartupStep.browserProbe =>
          AwsWindowsRuntimeDiagnostic.invalidBrowserProbe,
      });
      // The raw exception may contain paths or network details; keep the
      // user-visible diagnosis actionable without exposing those values.
      assert(() {
        debugPrint('AWS $providerId WebView2 [${step.name}]: $error');
        return true;
      }());
      if (browser != null) {
        try { await browser.dispose(); } catch (_) {}
      }
      await _subscription?.cancel();
      _subscription = null;
      _ready = false;
      try {
        await _temporaryAssets?.delete(recursive: true);
      } catch (_) {}
      _temporaryAssets = null;
      return false;
    }
  }

  Future<dynamic> invoke(String operation, {
    String name = '',
    Map<String, dynamic> payload = const {},
    String trackId = '',
    String viewKey = '',
  }) async {
    // Unbinding after a route is disposed must never restart WebView2 merely
    // to detach an already-gone tile.
    if (operation == 'unbind' && !_ready) return null;
    if (!await probe()) {
      throw StateError(lastDiagnostic?.userMessage ??
          'Windows WebView2 $providerId transport is unavailable.');
    }
    final browser = _controller!;
    final id = ++_nextCallId;
    final completion = Completer<dynamic>();
    _pending[id] = completion;
    try {
      await browser.postWebMessage(jsonEncode({
        'channel': _channel,
        'id': id,
        'operation': operation,
        'providerId': providerId,
        'sessionId': _sessionId,
        'name': name,
        'payload': payload,
        'trackId': trackId,
        'viewKey': viewKey,
      }));
      return await completion.future.timeout(const Duration(seconds: 35));
    } finally {
      _pending.remove(id);
    }
  }

  void _handleWebMessage(dynamic data) {
    if (data is! Map) return;
    final body = Map<String, dynamic>.from(data);
    if (body['channel'] == _channel && body['kind'] == 'result') {
      final id = body['id'];
      final waiter = _pending[id];
      if (waiter == null || waiter.isCompleted) return;
      if (body['success'] == true) {
        waiter.complete(body['value']);
      } else {
        waiter.completeError(StateError(
          body['message']?.toString() ?? '$providerId JavaScript bridge failed.',
        ));
      }
      return;
    }
    if (body['kind'] == 'event' &&
        body['sessionId'] == _sessionId &&
        body['event'] is Map) {
      _events.add(Map<String, dynamic>.from(body['event'] as Map));
    } else if (body['kind'] == 'frame') {
      _frames.add(body);
    }
  }

  Future<void> dispose() async {
    _ready = false;
    for (final result in _pending.values) {
      if (!result.isCompleted) {
        result.completeError(StateError('$providerId WebView2 was disposed.'));
      }
    }
    _pending.clear();
    await _subscription?.cancel();
    _subscription = null;
    await _controller?.dispose();
    _controller = null;
    try {
      await _temporaryAssets?.delete(recursive: true);
    } catch (_) {}
    _temporaryAssets = null;
  }
}
