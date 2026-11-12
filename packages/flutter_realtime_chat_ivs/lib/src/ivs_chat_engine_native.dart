import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_realtime_chat_core/flutter_realtime_chat_core.dart';

import 'ivs_chat_engine.dart';
import 'ivs_chat_join_info.dart';
import 'ivs_chat_engine_windows.dart';

Future<IvsChatEngine> createNativeIvsChatEngine() async =>
    _NativeIvsChatEngine();

Future<IvsChatEngine> createPlatformIvsChatEngine() async =>
    Platform.isWindows
        ? WindowsIvsChatEngine()
        : createNativeIvsChatEngine();

class _NativeIvsChatEngine implements IvsChatEngine {
  static const MethodChannel _methods = MethodChannel(
    'com.oneplusdream.flutter_realtime_chat_ivs/methods',
  );
  static const EventChannel _events = EventChannel(
    'com.oneplusdream.flutter_realtime_chat_ivs/events',
  );

  StreamSubscription<dynamic>? _subscription;
  IvsChatEngineEvents _handlers = const IvsChatEngineEvents();
  IvsChatTokenProvider? _tokenProvider;

  @override
  Future<void> connect(
    IvsChatJoinInfo info,
    IvsChatEngineEvents events, {
    IvsChatTokenProvider? tokenProvider,
  }) async {
    _handlers = events;
    _tokenProvider = tokenProvider;
    _methods.setMethodCallHandler(_handleNativeMethod);
    _subscription ??= _events.receiveBroadcastStream().listen(
      (dynamic value) => _dispatch(Map<String, Object?>.from(value as Map)),
      onError: (Object error) => _handlers.onError?.call(-1, error.toString()),
    );
    await _invoke('connect', _credentialMap(info));
  }

  Future<Object?> _handleNativeMethod(MethodCall call) async {
    if (call.method != 'requestToken') return null;
    final provider = _tokenProvider;
    if (provider == null) {
      throw PlatformException(
        code: 'token_provider_unavailable',
        message: 'No IVS Chat credential provider is configured.',
      );
    }
    return _credentialMap(await provider());
  }

  Map<String, Object?> _credentialMap(IvsChatJoinInfo info) => {
    'token': info.token,
    'tokenExpirationTimeMs': info.tokenExpirationTimeMs,
    'sessionExpirationTimeMs': info.sessionExpirationTimeMs,
    'region': info.region,
    'roomArn': info.roomArn,
  };

  @override
  Future<void> sendMessage(String message) =>
      _invoke('sendMessage', {'message': message});

  @override
  Future<void> deleteMessage(String messageId) =>
      _invoke('deleteMessage', {'messageId': messageId});

  @override
  Future<void> disconnectUser(String userId) =>
      _invoke('disconnectUser', {'userId': userId});

  @override
  Future<void> disconnect() => _invoke('disconnect');

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    _tokenProvider = null;
    _methods.setMethodCallHandler(null);
    await _invoke('dispose');
  }

  void _dispatch(Map<String, Object?> event) {
    switch (event['type']?.toString()) {
      case 'connecting':
        _handlers.onConnecting?.call(event['reconnecting'] == true);
        return;
      case 'connected':
        _handlers.onConnected?.call();
        return;
      case 'disconnected':
        _handlers.onDisconnected?.call(
          event['reason']?.toString() ?? 'unknown',
        );
        return;
      case 'message':
        _handlers.onMessage?.call(event);
        return;
      case 'messageDeleted':
        final messageId = event['messageId']?.toString() ?? '';
        if (messageId.isNotEmpty) _handlers.onMessageDeleted?.call(messageId);
        return;
      case 'userDisconnected':
        final userId = event['userId']?.toString() ?? '';
        if (userId.isNotEmpty) _handlers.onUserDisconnected?.call(userId);
        return;
      case 'error':
        _handlers.onError?.call(
          (event['code'] as num?)?.toInt() ?? -1,
          event['message']?.toString() ?? 'Amazon IVS Chat reported an error.',
        );
        return;
    }
  }

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    try {
      await _methods.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      throw RealtimeException(
        code: switch (error.code) {
          'invalid_state' => RealtimeErrorCode.invalidState,
          'forbidden' => RealtimeErrorCode.forbidden,
          'unauthorized' => RealtimeErrorCode.unauthorized,
          'unsupported_platform' => RealtimeErrorCode.unsupportedPlatform,
          _ => RealtimeErrorCode.providerError,
        },
        message:
            error.message ??
            'Amazon IVS Chat native call failed (${error.code}).',
        providerId: IvsChatJoinInfo.providerIdValue,
        details: error.details,
      );
    }
  }
}
