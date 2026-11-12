import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/chime_exception.dart';
import 'chime_windows_webview2.dart';

typedef NativeCallHandler = FutureOr<void> Function(MethodCall call);

/// Internal transport for the single native Chime session supported per
/// Flutter engine.
class ChimeNativeChannel {
  ChimeNativeChannel._();

  static final ChimeNativeChannel instance = ChimeNativeChannel._();

  static const channelName = 'com.oneplusdream.aws.chime.methodChannel';
  final MethodChannel _channel = const MethodChannel(channelName);

  Object? _owner;
  NativeCallHandler? _eventHandler;
  ChimeWindowsWebview2Transport? _windowsTransport;

  void reserve(Object owner, NativeCallHandler eventHandler) {
    _ensureSupportedPlatform();
    if (_owner != null && !identical(_owner, owner)) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'Only one Chime meeting can be active per Flutter engine.',
      );
    }
    _owner = owner;
    _eventHandler = eventHandler;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      final transport = ChimeWindowsWebview2Transport(_handleNativeCall);
      transport.reserve();
      _windowsTransport = transport;
    } else {
      _channel.setMethodCallHandler(_handleNativeCall);
    }
  }

  void release(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _eventHandler = null;
    _windowsTransport?.release();
    _windowsTransport = null;
    if (defaultTargetPlatform != TargetPlatform.windows) {
      _channel.setMethodCallHandler(null);
    }
  }

  Future<Object?> invoke(String method, [Object? arguments]) async {
    _ensureSupportedPlatform();
    try {
      final raw = defaultTargetPlatform == TargetPlatform.windows
          ? await (_windowsTransport?.invoke(method, arguments) ??
              Future<Map<String, dynamic>>.value({
                'success': false,
                'code': 'invalid_state',
                'message': 'Chime Windows session is not reserved.',
              }))
          : await _channel.invokeMethod<Object?>(method, arguments);
      if (raw is! Map) {
        throw RealtimeException(
          code: RealtimeErrorCode.providerError,
          message: 'Native method "$method" returned an invalid response.',
          details: raw,
        );
      }

      final response = Map<String, dynamic>.from(raw);
      if (response['success'] != true) {
        throw RealtimeException(
          code: _errorCode(response['code']?.toString()),
          message:
              response['message']?.toString() ??
              'Native method "$method" failed.',
          details: response['details'],
        );
      }
      return response['data'];
    } on RealtimeException {
      rethrow;
    } on PlatformException catch (error) {
      throw RealtimeException(
        code: _errorCode(error.code),
        message: error.message ?? 'Native method "$method" failed.',
        details: error.details,
      );
    } on MissingPluginException {
      throw const RealtimeException(
        code: RealtimeErrorCode.unsupportedPlatform,
        message:
            'The AWS Chime native media bridge is not registered on this platform.',
      );
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    final handler = _eventHandler;
    if (handler != null) await handler(call);
  }

  /// Dispatches a platform event in unit tests without depending on a device.
  @visibleForTesting
  Future<void> debugDispatchNativeCall(MethodCall call) =>
      _handleNativeCall(call);

  void _ensureSupportedPlatform() {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.macOS &&
            !(defaultTargetPlatform == TargetPlatform.windows &&
                const bool.fromEnvironment(
                  'AWS_CHIME_WINDOWS_WEBVIEW2_EXPERIMENTAL',
                  defaultValue: true,
                )))) {
      throw const RealtimeException(
        code: RealtimeErrorCode.unsupportedPlatform,
        message:
            'AWS Chime is unavailable on this platform or its Windows WebView2 '
            'experiment was explicitly disabled at build time.',
      );
    }
  }

  RealtimeErrorCode _errorCode(String? value) => switch (value) {
    'invalid_join_info' => RealtimeErrorCode.invalidArgument,
    'invalid_argument' => RealtimeErrorCode.invalidArgument,
    'invalid_state' => RealtimeErrorCode.invalidState,
    'meeting_already_active' => RealtimeErrorCode.invalidState,
    'permission_denied' => RealtimeErrorCode.permissionDenied,
    'unsupported_platform' => RealtimeErrorCode.unsupportedPlatform,
    'session_not_found' => RealtimeErrorCode.invalidState,
    'method_not_implemented' => RealtimeErrorCode.unsupportedFeature,
    'native_error' || 'Failed' => RealtimeErrorCode.providerError,
    _ => RealtimeErrorCode.unknown,
  };
}
