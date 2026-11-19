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

  @visibleForTesting
  AwsWindowsWebView2Runtime.forTesting(
    this.providerId, {
    this._probeOverride,
    this._postWebMessageOverride,
  });

  static final instance = AwsWindowsWebView2Runtime._('chime');
  static final ivs = AwsWindowsWebView2Runtime._('ivs');
  static Future<void>? _environmentInitialization;

  static Future<void> _ensureWebViewEnvironment() {
    return _environmentInitialization ??=
        WebviewController.initializeEnvironment(
          additionalArguments:
              '--use-fake-ui-for-media-stream '
              '--autoplay-policy=no-user-gesture-required',
        ).catchError((Object error) {
          if (error is PlatformException &&
              error.code == 'environment_already_initialized') {
            return;
          }
          _environmentInitialization = null;
        });
  }

  final String providerId;
  String get _origin => 'https://aws-$providerId-local.invalid';
  String get _channel => 'aws-windows-$providerId-v1';
  String get _sessionId => 'aws-desktop-$providerId';

  WebviewController? _controller;
  Future<bool> Function()? _probeOverride;
  Future<void> Function(String jsonMessage)? _postWebMessageOverride;
  Directory? _temporaryAssets;
  StreamSubscription<dynamic>? _subscription;
  Future<bool>? _initializing;
  bool _ready = false;
  String? lastError;
  AwsWindowsRuntimeDiagnostic? lastDiagnostic;
  Map<String, dynamic> lastProbe = const {};
  int _nextCallId = 0;
  int _processedGeneration = 0;
  int _screenCaptureGeneration = 0;
  String? _attachedProcessedSourceId;
  bool _postingProcessedFrame = false;
  Map<String, Object?>? _queuedProcessedFrame;
  String? _selectedScreenSourceId;
  String? _activeScreenCaptureSourceId;
  bool _postingScreenFrame = false;
  Map<String, Object?>? _queuedScreenFrame;
  final Set<String> _reportedProcessedFailures = <String>{};
  final _pending = <int, Completer<dynamic>>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _frames = StreamController<Map<String, dynamic>>.broadcast();
  final _viewFrames = <String, StreamController<Map<String, dynamic>>>{};

  static const MethodChannel _windowsChannel = MethodChannel(
    'com.oneplusdream.flutter_realtime_media_aws_desktop/windows',
  );
  static const MethodChannel _effectsChannel = MethodChannel(
    'flutter_realtime_video_effects',
  );
  static final Set<AwsWindowsWebView2Runtime> _processedRuntimes =
      <AwsWindowsWebView2Runtime>{};
  static final Set<AwsWindowsWebView2Runtime> _screenCaptureRuntimes =
      <AwsWindowsWebView2Runtime>{};
  static bool _windowsChannelBound = false;

  bool get _canPostWebMessage =>
      _ready && (_controller != null || _postWebMessageOverride != null);

  Future<void> _postWebMessage(String encoded) {
    final override = _postWebMessageOverride;
    if (override != null) return override(encoded);
    return _controller!.postWebMessage(encoded);
  }

  @visibleForTesting
  void debugConfigureForTesting({
    Future<bool> Function()? probeOverride,
    Future<void> Function(String jsonMessage)? postWebMessageOverride,
  }) {
    _probeOverride = probeOverride;
    _postWebMessageOverride = postWebMessageOverride;
    _ready = false;
  }

  @visibleForTesting
  void debugHandleWebMessage(dynamic data) => _handleWebMessage(data);

  @visibleForTesting
  static void debugResetWindowsChannelHandler() {
    if (_windowsChannelBound) {
      _windowsChannel.setMethodCallHandler(null);
      _windowsChannelBound = false;
    }
    _processedRuntimes.clear();
    _screenCaptureRuntimes.clear();
  }

  static void _ensureWindowsChannelHandler() {
    if (_windowsChannelBound) return;
    _windowsChannelBound = true;
    _windowsChannel.setMethodCallHandler((call) async {
      if (call.arguments is! Map) return;
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      final sourceId = args['sourceId']?.toString() ?? '';
      if (sourceId.isEmpty) return;

      if (call.method == 'onProcessedFrame') {
        final data = args['data']?.toString() ?? '';
        if (data.isEmpty) return;
        final timestampNs = (args['timestampNs'] as num?)?.toInt() ?? 0;
        for (final runtime in List<AwsWindowsWebView2Runtime>.of(
          _processedRuntimes,
        )) {
          if (runtime._attachedProcessedSourceId?.toLowerCase() ==
              sourceId.toLowerCase()) {
            runtime._pushProcessedFrame(
              sourceId: sourceId,
              timestampNs: timestampNs,
              data: data,
            );
          }
        }
        return;
      }

      if (call.method == 'onScreenFrame') {
        final data = args['data']?.toString() ?? '';
        if (data.isEmpty) return;
        final timestampNs = (args['timestampNs'] as num?)?.toInt() ?? 0;
        for (final runtime in List<AwsWindowsWebView2Runtime>.of(
          _screenCaptureRuntimes,
        )) {
          if (runtime._activeScreenCaptureSourceId?.toLowerCase() ==
              sourceId.toLowerCase()) {
            runtime._pushScreenFrame(
              sourceId: sourceId,
              timestampNs: timestampNs,
              data: data,
            );
          }
        }
        return;
      }

      if (call.method == 'onScreenCaptureStopped') {
        final reason = args['reason']?.toString() ?? 'stopped';
        for (final runtime in List<AwsWindowsWebView2Runtime>.of(
          _screenCaptureRuntimes,
        )) {
          if (runtime._activeScreenCaptureSourceId?.toLowerCase() ==
              sourceId.toLowerCase()) {
            unawaited(
              runtime._handleNativeScreenCaptureStopped(sourceId, reason),
            );
          }
        }
      }
    });
  }

  /// Enumerates shareable Windows displays and application windows through the
  /// native desktop plugin.
  Future<List<Map<String, dynamic>>> listScreenShareSources() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return const <Map<String, dynamic>>[];
    }
    final raw = await _windowsChannel.invokeListMethod<dynamic>(
      'listScreenShareSources',
    );
    final results = <Map<String, dynamic>>[];
    for (final item in raw ?? const <dynamic>[]) {
      if (item is! Map) continue;
      final id = item['id']?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      final kind = item['kind']?.toString() == 'window' ? 'window' : 'display';
      final rawName = item['name']?.toString().trim() ?? '';
      results.add({
        'id': id,
        'name': rawName.isEmpty
            ? (kind == 'window' ? 'Application window' : 'Entire display')
            : rawName,
        'kind': kind,
      });
    }
    return List.unmodifiable(results);
  }

  /// Stores the chosen display or window ID for the next screen-share start.
  void selectScreenShareSource(String sourceId) {
    final trimmed = sourceId.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        sourceId,
        'sourceId',
        'Screen share source id is required.',
      );
    }
    _selectedScreenSourceId = trimmed;
  }

  /// Clears any previously selected screen-share target on session teardown.
  void clearSelectedScreenShareSource() {
    _selectedScreenSourceId = null;
  }

  /// Starts native Windows display/window capture and binds a dedicated canvas
  /// MediaStreamTrack in WebView2 (`RealtimeScreenCaptureBridge`).
  Future<String> startScreenShareCapture() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      throw UnsupportedError(
        'Windows WebView2 screen capture requires Windows.',
      );
    }
    await stopScreenShareCapture();
    _ensureWindowsChannelHandler();
    final sourceId = 'aws-screen-$providerId-${++_screenCaptureGeneration}';
    _reportedProcessedFailures.remove(sourceId.toLowerCase());
    _activeScreenCaptureSourceId = sourceId;
    _screenCaptureRuntimes.add(this);
    try {
      await invoke('startScreenCaptureSource', payload: {'sourceId': sourceId});
      await _windowsChannel.invokeMethod<void>('startScreenCapture', {
        'sourceId': sourceId,
        if (_selectedScreenSourceId != null &&
            _selectedScreenSourceId!.isNotEmpty)
          'targetId': _selectedScreenSourceId,
      });
      return sourceId;
    } catch (_) {
      await stopScreenShareCapture();
      rethrow;
    }
  }

  /// Stops active native Windows screen capture and releases the WebView2
  /// screen-capture track.
  Future<void> stopScreenShareCapture({bool notifyJsSession = false}) async {
    final previousSourceId = _activeScreenCaptureSourceId;
    _activeScreenCaptureSourceId = null;
    _queuedScreenFrame = null;
    _screenCaptureRuntimes.remove(this);
    if (previousSourceId == null && !notifyJsSession) return;

    if (previousSourceId != null) {
      try {
        await _windowsChannel.invokeMethod<void>('stopScreenCapture', {
          'sourceId': previousSourceId,
        });
      } on MissingPluginException {
        // Ignore when native Windows plugin is absent in unit tests.
      } on PlatformException {
        // Best-effort cleanup.
      }
    }

    if (_ready) {
      if (notifyJsSession) {
        try {
          await invoke(
            'invoke',
            name: 'command',
            payload: {
              'name': 'setScreenShareEnabled',
              'args': const {'enabled': false},
            },
          );
        } catch (_) {
          // Ignore teardown errors when session already ended.
        }
      }
      if (previousSourceId != null) {
        try {
          await invoke(
            'stopScreenCaptureSource',
            payload: {'sourceId': previousSourceId},
          );
        } catch (_) {
          // Ignore detach RPC errors during teardown.
        }
      }
    }
  }

  Future<void> _handleNativeScreenCaptureStopped(
    String sourceId,
    String reason,
  ) async {
    if (_activeScreenCaptureSourceId?.toLowerCase() != sourceId.toLowerCase()) {
      return;
    }
    await stopScreenShareCapture(notifyJsSession: true);
    if (!_events.isClosed) {
      _events.add({
        'type': 'screenCaptureStopped',
        'sourceId': sourceId,
        'reason': reason,
      });
    }
  }

  void _pushScreenFrame({
    required String sourceId,
    required int timestampNs,
    required String data,
  }) {
    if (!_canPostWebMessage) return;
    final payload = <String, Object?>{
      'channel': _channel,
      'kind': 'screenFrame',
      'sourceId': sourceId,
      'timestampNs': timestampNs,
      'data': data,
    };
    if (_postingScreenFrame) {
      _queuedScreenFrame = payload;
      return;
    }
    _postingScreenFrame = true;
    unawaited(_drainScreenFrames(payload));
  }

  Future<void> _drainScreenFrames(Map<String, Object?> initial) async {
    Map<String, Object?>? current = initial;
    try {
      while (current != null &&
          _canPostWebMessage &&
          _activeScreenCaptureSourceId != null) {
        await _postWebMessage(jsonEncode(current));
        current = _queuedScreenFrame;
        _queuedScreenFrame = null;
      }
    } catch (_) {
      // Dropped frame cleanly when WebView2 is closing.
    } finally {
      _postingScreenFrame = false;
    }
  }

  /// Checks whether Windows WebView2 and the native processed-video FrameHub
  /// can both exchange processed frames safely. Always fails closed when absent.
  Future<bool> probeProcessedVideoInput() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return false;
    try {
      final hasNativeSymbols =
          await _windowsChannel.invokeMethod<bool>(
            'probeProcessedVideoInput',
          ) ??
          false;
      if (!hasNativeSymbols) return false;
      return await probe();
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> attachProcessedVideoSource(String sourceId) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      throw UnsupportedError(
        'Windows WebView2 processed video requires Windows.',
      );
    }
    _ensureWindowsChannelHandler();
    final generation = ++_processedGeneration;
    _reportedProcessedFailures.remove(sourceId.toLowerCase());
    _attachedProcessedSourceId = sourceId;
    _processedRuntimes.add(this);
    try {
      await invoke(
        'attachProcessedVideo',
        payload: {'sourceId': sourceId, 'generation': generation},
      );
      await _windowsChannel.invokeMethod<void>('subscribeProcessedVideo', {
        'sourceId': sourceId,
      });
    } catch (_) {
      await detachProcessedVideoSource();
      rethrow;
    }
  }

  Future<void> detachProcessedVideoSource() async {
    final previousSourceId = _attachedProcessedSourceId;
    _attachedProcessedSourceId = null;
    _queuedProcessedFrame = null;
    _processedRuntimes.remove(this);
    final generation = ++_processedGeneration;
    try {
      if (_ready) {
        await invoke(
          'detachProcessedVideo',
          payload: {
            if (previousSourceId != null) 'sourceId': previousSourceId,
            'generation': generation,
          },
        );
      }
    } catch (_) {
      // Ignore detach RPC errors during teardown.
    }
    final stillInUse = _processedRuntimes.any(
      (runtime) =>
          previousSourceId != null &&
          runtime._attachedProcessedSourceId?.toLowerCase() ==
              previousSourceId.toLowerCase(),
    );
    if (!stillInUse) {
      try {
        await _windowsChannel.invokeMethod<void>('unsubscribeProcessedVideo');
      } on MissingPluginException {
        // Ignore when native Windows plugin is absent in unit tests.
      } on PlatformException {
        // Best-effort cleanup.
      }
    }
  }

  void _pushProcessedFrame({
    required String sourceId,
    required int timestampNs,
    required String data,
  }) {
    if (!_canPostWebMessage) return;
    final payload = <String, Object?>{
      'channel': _channel,
      'kind': 'processedFrame',
      'sourceId': sourceId,
      'timestampNs': timestampNs,
      'data': data,
    };
    if (_postingProcessedFrame) {
      _queuedProcessedFrame = payload;
      return;
    }
    _postingProcessedFrame = true;
    unawaited(_drainProcessedFrames(payload));
  }

  Future<void> _drainProcessedFrames(Map<String, Object?> initial) async {
    Map<String, Object?>? current = initial;
    try {
      while (current != null &&
          _canPostWebMessage &&
          _attachedProcessedSourceId != null) {
        await _postWebMessage(jsonEncode(current));
        current = _queuedProcessedFrame;
        _queuedProcessedFrame = null;
      }
    } catch (_) {
      // Dropped frame cleanly when WebView2 is closing.
    } finally {
      _postingProcessedFrame = false;
    }
  }

  void _reportProcessedVideoError(String sourceId, String message) {
    final key = sourceId.trim().toLowerCase();
    if (key.isEmpty) return;
    if (_activeScreenCaptureSourceId?.toLowerCase() == key) {
      unawaited(_handleNativeScreenCaptureStopped(sourceId, message));
      return;
    }
    if (!_reportedProcessedFailures.add(key)) return;
    unawaited(
      _windowsChannel
          .invokeMethod<void>('reportProcessedVideoError', {
            'sourceId': sourceId,
            'message': message,
          })
          .catchError((Object _) {}),
    );
    unawaited(
      _effectsChannel
          .invokeMethod<void>('sourceError', {
            'sourceId': sourceId,
            'message': message,
          })
          .catchError((Object _) {}),
    );
  }

  Stream<Map<String, dynamic>> get events => _events.stream;
  Stream<Map<String, dynamic>> get frames => _frames.stream;
  bool get isReady => _ready;

  /// Per-view frame stream avoiding O(N^2) broadcast fan-out across tiles.
  Stream<Map<String, dynamic>> framesForView(String viewKey) {
    final existing = _viewFrames[viewKey];
    if (existing != null) return existing.stream;
    late final StreamController<Map<String, dynamic>> controller;
    controller = StreamController<Map<String, dynamic>>.broadcast(
      onCancel: () {
        if (!controller.hasListener) {
          _viewFrames.remove(viewKey);
          unawaited(controller.close());
        }
      },
    );
    _viewFrames[viewKey] = controller;
    return controller.stream;
  }

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
    final override = _probeOverride;
    if (override != null) {
      return _initializing ??= override()
          .then((ok) {
            _ready = ok;
            if (!ok && lastDiagnostic == null) {
              _diagnose(AwsWindowsRuntimeDiagnostic.webView2Missing);
            }
            return ok;
          })
          .whenComplete(() {
            _initializing = null;
          });
    }
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
      final files = await Directory.systemTemp.createTemp(
        'aws-$providerId-wv2-',
      );
      _temporaryAssets = files;

      final sdkFile = providerId == 'ivs'
          ? 'amazon-ivs-web-broadcast.js'
          : 'chime-sdk.js';
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
        await File(
          '${files.path}${Platform.pathSeparator}${entry.key}',
        ).writeAsString(source, flush: true);
      }
      await File(
        '${files.path}${Platform.pathSeparator}index.html',
      ).writeAsString('''
<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy"
 content="default-src 'self' https: wss: data: blob:; script-src 'self' 'unsafe-eval' 'wasm-unsafe-eval' 'unsafe-inline' blob: https:; worker-src 'self' blob:; connect-src 'self' https: wss: data: blob:; img-src 'self' data: blob: https:; media-src 'self' data: blob: https:; style-src 'self' 'unsafe-inline';">
</head><body><script>globalThis.global = globalThis;</script>
<script src="windows_runtime.js"></script>
<script src="$sdkFile"></script>
<script src="media-provider-bridge.js"></script>
<script src="windows_host.js"></script></body></html>
''', flush: true);

      step = _AwsWindowsStartupStep.browserInitialization;
      await _ensureWebViewEnvironment();
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
        try {
          await browser.dispose();
        } catch (_) {}
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

  Future<dynamic> invoke(
    String operation, {
    String name = '',
    Map<String, dynamic> payload = const {},
    String trackId = '',
    String viewKey = '',
  }) async {
    // Unbinding after a route is disposed must never restart WebView2 merely
    // to detach an already-gone tile.
    if (operation == 'unbind' && !_ready) return null;
    if (!await probe()) {
      throw StateError(
        lastDiagnostic?.userMessage ??
            'Windows WebView2 $providerId transport is unavailable.',
      );
    }
    final id = ++_nextCallId;
    final completion = Completer<dynamic>();
    _pending[id] = completion;
    try {
      await _postWebMessage(
        jsonEncode({
          'channel': _channel,
          'id': id,
          'operation': operation,
          'providerId': providerId,
          'sessionId': _sessionId,
          'name': name,
          'payload': payload,
          'trackId': trackId,
          'viewKey': viewKey,
        }),
      );
      return await completion.future.timeout(const Duration(seconds: 35));
    } finally {
      _pending.remove(id);
    }
  }

  void _handleWebMessage(dynamic rawData) {
    dynamic data = rawData;
    if (data is String && data.trimLeft().startsWith('{')) {
      try {
        data = jsonDecode(data);
      } catch (_) {
        return;
      }
    }
    if (data is! Map) return;
    final body = Map<String, dynamic>.from(data);
    if (body['channel'] == _channel && body['kind'] == 'result') {
      final id = body['id'];
      final waiter = _pending[id];
      if (waiter == null || waiter.isCompleted) return;
      if (body['success'] == true) {
        waiter.complete(body['value']);
      } else {
        waiter.completeError(
          StateError(
            body['message']?.toString() ??
                '$providerId JavaScript bridge failed.',
          ),
        );
      }
      return;
    }
    if (body['kind'] == 'processedVideoError') {
      final sourceId = body['sourceId']?.toString() ?? '';
      final message =
          body['message']?.toString() ??
          'Windows WebView2 processed video failed.';
      _reportProcessedVideoError(sourceId, message);
      return;
    }
    if (body['kind'] == 'event' &&
        body['sessionId'] == _sessionId &&
        body['event'] is Map) {
      _events.add(Map<String, dynamic>.from(body['event'] as Map));
    } else if (body['kind'] == 'frame') {
      final viewKey = body['viewKey']?.toString();
      if (viewKey != null) {
        _viewFrames[viewKey]?.add(body);
      }
      if (_frames.hasListener) {
        _frames.add(body);
      }
    }
  }

  Future<void> dispose() async {
    await stopScreenShareCapture();
    await detachProcessedVideoSource();
    _selectedScreenSourceId = null;
    _ready = false;
    _initializing = null;
    _reportedProcessedFailures.clear();
    for (final result in _pending.values) {
      if (!result.isCompleted) {
        result.completeError(StateError('$providerId WebView2 was disposed.'));
      }
    }
    _pending.clear();
    final activeViewStreams = _viewFrames.values.toList(growable: false);
    _viewFrames.clear();
    for (final controller in activeViewStreams) {
      await controller.close();
    }
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
