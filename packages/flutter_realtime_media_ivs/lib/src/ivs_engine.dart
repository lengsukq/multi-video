import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_webview2_runtime.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'ivs_join_info.dart';
import 'ivs_windows_webview2.dart';

typedef IvsEngineFactory = Future<IvsEngine> Function();
typedef IvsDeviceProbe = Future<IvsDeviceCounts> Function();
typedef IvsAvailabilityProbe = Future<bool> Function();

/// Windows Stage WebView2 is enabled by default but must pass a runtime probe.
///
/// IVS publishes Web, Android and iOS broadcast SDKs. A working Windows
/// implementation cannot be inferred merely because the Dart adapter exists.
Future<bool> probeNativeIvsAvailability() async {
  if (kIsWeb) return false;
  if (defaultTargetPlatform != TargetPlatform.windows) return true;
  // IVS Web Broadcast does not officially support embedded WebViews.
  // The experimental path is enabled for Windows testing by default, but
  // availability is never reported unless the browser/media probe succeeds.
  // Hosts may opt out at build time by setting the flag to false.
  if (!const bool.fromEnvironment(
    'AWS_IVS_WINDOWS_WEBVIEW2_EXPERIMENTAL',
    defaultValue: true,
  )) {
    return false;
  }
  try {
    return await AwsWindowsWebView2Runtime.ivs.probe();
  } on Exception {
    return false;
  }
}

class IvsDeviceCounts {
  const IvsDeviceCounts({required this.microphones, required this.cameras});

  final int microphones;
  final int cameras;
}

abstract interface class IvsEngine {
  Future<void> join(IvsJoinInfo info, IvsEngineEvents events);
  Future<void> exchangeToken(String token);
  Future<void> leave();
  Future<void> setMuted(bool muted);
  Future<void> setVideoEnabled(bool enabled);
  Future<void> switchCamera(MediaCameraPosition position);
  Future<void> requestStats();
  Future<void> dispose();
}

class IvsEngineEvents {
  const IvsEngineEvents({
    this.onError,
    this.onParticipantJoined,
    this.onParticipantLeft,
    this.onRemoteVideoChanged,
    this.onRemoteAudioChanged,
    this.onReconnecting,
    this.onRecovered,
    this.onStats,
  });

  final void Function(int code, String message)? onError;
  final void Function(String userId, String displayName)? onParticipantJoined;
  final void Function(String userId)? onParticipantLeft;
  final void Function(String userId, bool available)? onRemoteVideoChanged;
  final void Function(String userId, bool available)? onRemoteAudioChanged;
  final void Function()? onReconnecting;
  final void Function()? onRecovered;
  final void Function(Map<String, Object?> values)? onStats;
}

Future<IvsEngine> createNativeIvsEngine() async {
  if (defaultTargetPlatform == TargetPlatform.windows) {
    if (!await probeNativeIvsAvailability()) {
      final diagnostic = AwsWindowsWebView2Runtime.ivs.lastDiagnostic;
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedPlatform,
        providerId: 'ivs',
        message: diagnostic?.userMessage ??
            'Amazon IVS Stage Windows WebView2 is unavailable or disabled by '
                'build configuration. AWS does not support IVS WebViews.',
      );
    }
    return WindowsIvsWebView2Engine();
  }
  return _NativeIvsEngine();
}

Future<IvsDeviceCounts> probeNativeIvsDevices() async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    if (!await probeNativeIvsAvailability()) {
      throw const RealtimeException(
        code: RealtimeErrorCode.unsupportedPlatform,
        providerId: 'ivs',
        message: 'IVS Windows device probe requires the experimental runtime.',
      );
    }
    final result = await AwsWindowsWebView2Runtime.ivs.invoke('probeDevices');
    final devices =
        Map<String, dynamic>.from(result as Map<Object?, Object?>);
    return IvsDeviceCounts(
      microphones: (devices['microphones'] as num?)?.toInt() ?? 0,
      cameras: (devices['cameras'] as num?)?.toInt() ?? 0,
    );
  }
  const channel = MethodChannel(
    'com.oneplusdream.flutter_realtime_media_ivs/methods',
  );
  try {
    final raw = await channel.invokeMapMethod<String, Object?>('probeDevices');
    return IvsDeviceCounts(
      microphones: (raw?['microphones'] as num?)?.toInt() ?? 0,
      cameras: (raw?['cameras'] as num?)?.toInt() ?? 0,
    );
  } on PlatformException catch (error) {
    throw _mapPlatformError(error);
  }
}

class _NativeIvsEngine implements IvsEngine {
  static const MethodChannel _methods = MethodChannel(
    'com.oneplusdream.flutter_realtime_media_ivs/methods',
  );
  static const EventChannel _events = EventChannel(
    'com.oneplusdream.flutter_realtime_media_ivs/events',
  );

  StreamSubscription<dynamic>? _subscription;
  IvsEngineEvents _handlers = const IvsEngineEvents();

  @override
  Future<void> join(IvsJoinInfo info, IvsEngineEvents events) async {
    _handlers = events;
    _subscription ??= _events.receiveBroadcastStream().listen(
      (dynamic value) => _dispatch(Map<String, Object?>.from(value as Map)),
      onError: (Object error) => _handlers.onError?.call(-1, error.toString()),
    );
    await _invoke('join', {
      'token': info.token,
      'userId': info.participantId,
      'displayName': info.displayName,
      'role': info.role.wireName,
      'stageArn': info.stageArn,
      'tokenParticipantId': info.tokenParticipantId,
      'capabilities': info.capabilities,
      'expiresAtMs': info.expiresAtMs,
      if (info.region != null) 'region': info.region,
    });
  }

  @override
  Future<void> exchangeToken(String token) =>
      _invoke('exchangeToken', {'token': token});

  @override
  Future<void> leave() => _invoke('leave');

  @override
  Future<void> setMuted(bool muted) => _invoke('setMuted', {'muted': muted});

  @override
  Future<void> setVideoEnabled(bool enabled) =>
      _invoke('setVideoEnabled', {'enabled': enabled});

  @override
  Future<void> switchCamera(MediaCameraPosition position) =>
      _invoke('switchCamera', {'position': position.name});

  @override
  Future<void> requestStats() => _invoke('requestStats');

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _invoke('dispose');
  }

  void _dispatch(Map<String, Object?> event) {
    final type = event['type']?.toString();
    final userId = event['userId']?.toString() ?? '';
    switch (type) {
      case 'participantJoined':
        if (userId.isNotEmpty) {
          _handlers.onParticipantJoined?.call(
            userId,
            event['displayName']?.toString() ?? userId,
          );
        }
        return;
      case 'participantLeft':
        if (userId.isNotEmpty) _handlers.onParticipantLeft?.call(userId);
        return;
      case 'videoChanged':
        if (userId.isNotEmpty) {
          _handlers.onRemoteVideoChanged?.call(
            userId,
            event['available'] == true,
          );
        }
        return;
      case 'audioChanged':
        if (userId.isNotEmpty) {
          _handlers.onRemoteAudioChanged?.call(
            userId,
            event['available'] == true,
          );
        }
        return;
      case 'reconnecting':
        _handlers.onReconnecting?.call();
        return;
      case 'recovered':
        _handlers.onRecovered?.call();
        return;
      case 'stats':
        _handlers.onStats?.call(event);
        return;
      case 'error':
        _handlers.onError?.call(
          (event['code'] as num?)?.toInt() ?? -1,
          event['message']?.toString() ?? 'Amazon IVS SDK reported an error.',
        );
        return;
    }
  }

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    try {
      await _methods.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      throw _mapPlatformError(error);
    }
  }
}

RealtimeException _mapPlatformError(PlatformException error) =>
    RealtimeException(
      code: switch (error.code) {
        'permission_denied' => RealtimeErrorCode.permissionDenied,
        'invalid_state' => RealtimeErrorCode.invalidState,
        'unsupported_feature' => RealtimeErrorCode.unsupportedFeature,
        'invalid_join_info' => RealtimeErrorCode.invalidArgument,
        'unsupported_platform' => RealtimeErrorCode.unsupportedPlatform,
        _ => RealtimeErrorCode.providerError,
      },
      message:
          error.message ?? 'Amazon IVS native call failed (${error.code}).',
      details: error.details,
      providerId: IvsJoinInfo.providerIdValue,
    );
