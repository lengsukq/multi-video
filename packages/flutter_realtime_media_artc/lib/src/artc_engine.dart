import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'artc_join_info.dart';

typedef ArtcEngineFactory = Future<ArtcEngine> Function();
typedef ArtcAvailabilityProbe = Future<bool> Function();

/// Returns whether the native ARTC runtime required by this platform is
/// actually available.
///
/// Android/iOS ship their provider dependency normally. macOS and Windows
/// require an optional native ARTC runtime; do not report those platforms
/// as available unless the native plugin explicitly confirms readiness.
Future<bool> probeNativeArtcAvailability() async {
  if (kIsWeb) return false;
  if (defaultTargetPlatform != TargetPlatform.macOS &&
      defaultTargetPlatform != TargetPlatform.windows) {
    return true;
  }
  try {
    return await _NativeArtcEngine._methodChannel.invokeMethod<bool>(
          'isAvailable',
        ) ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// Internal seam around the native ARTC engine. Fakes implement this for
/// offline adapter tests; app code normally uses [createNativeArtcEngine].
abstract interface class ArtcEngine {
  Future<void> join(ArtcJoinInfo info, ArtcEngineEvents events);
  Future<void> leave();
  Future<void> setMuted(bool muted);
  Future<void> setVideoEnabled(bool enabled);
  Future<void> setScreenShareEnabled(bool enabled);
  Future<void> switchCamera(MediaCameraPosition position);
  Future<void> sendMessage(String message, String topic);
  Future<void> dispose();
}

/// Optional Windows-only source interface. Android/iOS test engines remain
/// compatible without implementing desktop capture methods.
abstract interface class ArtcDesktopScreenCapture {
  Future<List<MediaScreenShareSource>> listDesktopScreenSources();
  Future<void> selectDesktopScreenSource(MediaScreenShareSource source);
}

/// Typed callbacks delivered to the session from ARTC notifications.
class ArtcEngineEvents {
  const ArtcEngineEvents({
    this.onError,
    this.onParticipantJoined,
    this.onParticipantLeft,
    this.onRemoteVideoChanged,
    this.onRemoteScreenChanged,
    this.onLocalScreenShareChanged,
    this.onRemoteAudioChanged,
    this.onMessage,
    this.onReconnecting,
    this.onRecovered,
    this.onAuthWillExpire,
  });

  final void Function(int code, String message)? onError;
  final void Function(String userId)? onParticipantJoined;
  final void Function(String userId)? onParticipantLeft;
  final void Function(String userId, bool available)? onRemoteVideoChanged;
  final void Function(String userId, bool available)? onRemoteScreenChanged;
  final void Function(bool available)? onLocalScreenShareChanged;
  final void Function(String userId, bool available)? onRemoteAudioChanged;
  final void Function(String userId, String data)? onMessage;
  final void Function()? onReconnecting;
  final void Function()? onRecovered;
  final void Function()? onAuthWillExpire;
}

/// Prevents Windows from opening an unimplemented native event stream.
Future<ArtcEngine> createNativeArtcEngine() async {
  if (defaultTargetPlatform == TargetPlatform.windows &&
      !await probeNativeArtcAvailability()) {
    throw const RealtimeException(
      code: RealtimeErrorCode.unsupportedPlatform,
      providerId: ArtcJoinInfo.providerIdValue,
      message: 'Alibaba ARTC Windows native engine is not installed or ready.',
    );
  }
  return _NativeArtcEngine();
}

class _NativeArtcEngine implements ArtcEngine, ArtcDesktopScreenCapture {
  static const MethodChannel _methodChannel = MethodChannel(
    'com.oneplusdream.flutter_realtime_media_artc/methods',
  );
  static const EventChannel _eventChannel = EventChannel(
    'com.oneplusdream.flutter_realtime_media_artc/events',
  );

  StreamSubscription<dynamic>? _eventSubscription;
  ArtcEngineEvents _handlers = const ArtcEngineEvents();
  MediaScreenShareSource? _selectedDesktopSource;

  @override
  Future<List<MediaScreenShareSource>> listDesktopScreenSources() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      throw const RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        providerId: ArtcJoinInfo.providerIdValue,
        message: 'ARTC desktop source selection requires Windows.',
      );
    }
    final raw = await _methodChannel.invokeListMethod<dynamic>(
      'listScreenShareSources',
    );
    return [
      for (final item in raw ?? const <dynamic>[])
        if (item is Map)
          MediaScreenShareSource(
            id: item['id']?.toString() ?? '',
            name: item['name']?.toString() ?? '',
            kind: item['kind'] == 'window'
                ? MediaScreenShareSourceKind.window
                : MediaScreenShareSourceKind.display,
          ),
    ];
  }

  @override
  Future<void> selectDesktopScreenSource(MediaScreenShareSource source) async {
    final sources = await listDesktopScreenSources();
    if (!sources.any((item) =>
        item.id == source.id && item.kind == source.kind)) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        providerId: ArtcJoinInfo.providerIdValue,
        message: 'The selected ARTC screen or window is no longer available.',
      );
    }
    _selectedDesktopSource = source;
  }

  @override
  Future<void> join(ArtcJoinInfo info, ArtcEngineEvents events) async {
    _handlers = events;
    _eventSubscription ??= _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) => _dispatch(Map<String, Object?>.from(event as Map)),
      onError: (Object error) => _handlers.onError?.call(-1, error.toString()),
    );
    await _invoke('join', {
      'appId': info.appId,
      'channelId': info.channelId,
      'userId': info.userId,
      'displayName': info.displayName,
      'authInfo': info.authInfo,
      'role': info.role.wireName,
      'roomMode': info.roomMode.name,
    });
  }

  @override
  Future<void> leave() => _invoke('leave');

  @override
  Future<void> setMuted(bool muted) => _invoke('setMuted', {'muted': muted});

  @override
  Future<void> setVideoEnabled(bool enabled) =>
      _invoke('setVideoEnabled', {'enabled': enabled});

  @override
  Future<void> setScreenShareEnabled(bool enabled) =>
      _invoke('setScreenShareEnabled', {
        'enabled': enabled,
        if (enabled && _selectedDesktopSource != null) ...{
          'sourceId': _selectedDesktopSource!.id,
          'sourceKind':
              _selectedDesktopSource!.kind == MediaScreenShareSourceKind.window
              ? 'window'
              : 'display',
        },
      });

  @override
  Future<void> switchCamera(MediaCameraPosition position) =>
      _invoke('switchCamera', {'position': position.name});

  @override
  Future<void> sendMessage(String message, String topic) =>
      _invoke('sendMessage', {'message': message, 'topic': topic});

  @override
  Future<void> dispose() async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await _invoke('dispose');
  }

  void _dispatch(Map<String, Object?> event) {
    final type = event['type']?.toString();
    final userId = event['userId']?.toString() ?? '';
    switch (type) {
      case 'participantJoined':
        if (userId.isNotEmpty) _handlers.onParticipantJoined?.call(userId);
        return;
      case 'localScreenChanged':
        _handlers.onLocalScreenShareChanged?.call(event['available'] == true);
        return;
      case 'screenChanged':
        if (userId.isNotEmpty) {
          _handlers.onRemoteScreenChanged?.call(
            userId,
            event['available'] == true,
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
      case 'message':
        if (userId.isNotEmpty) {
          _handlers.onMessage?.call(userId, event['data']?.toString() ?? '');
        }
        return;
      case 'reconnecting':
        _handlers.onReconnecting?.call();
        return;
      case 'recovered':
        _handlers.onRecovered?.call();
        return;
      case 'authWillExpire':
        _handlers.onAuthWillExpire?.call();
        return;
      case 'error':
        _handlers.onError?.call(
          (event['code'] as num?)?.toInt() ?? -1,
          event['message']?.toString() ?? 'ARTC SDK reported an error.',
        );
        return;
    }
  }

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    try {
      await _methodChannel.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      throw RealtimeException(
        code: switch (error.code) {
          'permission_denied' => RealtimeErrorCode.permissionDenied,
          'invalid_state' => RealtimeErrorCode.invalidState,
          'unsupported_platform' => RealtimeErrorCode.unsupportedPlatform,
          'unsupported_feature' => RealtimeErrorCode.unsupportedFeature,
          'invalid_join_info' => RealtimeErrorCode.invalidArgument,
          _ => RealtimeErrorCode.providerError,
        },
        message: error.message ?? 'ARTC native call failed (${error.code}).',
        details: error.details,
        providerId: ArtcJoinInfo.providerIdValue,
      );
    }
  }
}
