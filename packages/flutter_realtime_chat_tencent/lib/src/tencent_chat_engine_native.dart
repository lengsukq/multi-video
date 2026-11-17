import 'dart:async';
import 'dart:convert';

import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimSDKListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/log_level_enum.dart';
import 'package:tencent_cloud_chat_sdk/tencent_im_sdk_plugin.dart';

import 'tencent_chat_engine.dart';
import 'tencent_chat_join_info.dart';

Future<TencentChatEngine> createPlatformTencentChatEngine() async =>
    _TencentSdkChatEngine();

class _TencentSdkChatEngine implements TencentChatEngine {
  /// Tracks the globally initialized SDKAppID across the process so disposing a
  /// single room session does not tear down Tencent IM's process-wide singleton
  /// while another room or immediate rejoin is active.
  static int? _initializedSdkAppId;

  TencentChatEngineEvents _events = const TencentChatEngineEvents();
  TencentChatTokenProvider? _tokenProvider;
  TencentChatJoinInfo? _info;
  V2TimAdvancedMsgListener? _messageListener;
  bool _loggedIn = false;
  bool _joinedGroup = false;
  bool _connected = false;
  bool _disposed = false;
  bool _refreshing = false;

  dynamic get _manager => TencentImSDKPlugin.v2TIMManager;

  @override
  Future<void> connect(
    TencentChatJoinInfo info,
    TencentChatEngineEvents events, {
    TencentChatTokenProvider? tokenProvider,
  }) async {
    if (_disposed) throw StateError('Tencent Chat engine is disposed.');
    _events = events;
    _tokenProvider = tokenProvider;
    _info = info;
    _events.onConnecting?.call(false);

    if (_initializedSdkAppId != null && _initializedSdkAppId != info.sdkAppId) {
      try {
        await _manager.unInitSDK();
      } catch (_) {
        // Proceed with fresh initSDK when switching SDKAppIDs.
      }
      _initializedSdkAppId = null;
    }

    final initResult = await _manager.initSDK(
      sdkAppID: info.sdkAppId,
      loglevel: LogLevelEnum.V2TIM_LOG_INFO,
      listener: V2TimSDKListener(
        onConnecting: () {
          if (!_disposed) _events.onConnecting?.call(true);
        },
        onConnectSuccess: () {
          if (!_disposed && _connected) _events.onConnected?.call();
        },
        onConnectFailed: (code, message) {
          if (!_disposed) _events.onError?.call(code, message);
        },
        onKickedOffline: () {
          if (_disposed) return;
          _connected = false;
          _events.onDisconnected?.call('kickedOffline');
        },
        onUserSigExpired: () {
          if (!_disposed) unawaited(_refreshToken());
        },
      ),
    );
    _requireSuccess(initResult, 'initialize Tencent Chat');
    _initializedSdkAppId = info.sdkAppId;

    final loginResult = await _manager.login(
      userID: info.providerUserId,
      userSig: info.userSig,
    );
    _requireSuccess(loginResult, 'log in to Tencent Chat');
    _loggedIn = true;

    try {
      _messageListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (message) {
          if (!_disposed) _emitMessage(message);
        },
        onRecvMessageRevoked: (messageId) {
          if (_disposed) return;
          final id = messageId.toString().trim();
          if (id.isNotEmpty) _events.onMessageDeleted?.call(id);
        },
      );
      await _manager.getMessageManager().addAdvancedMsgListener(
        listener: _messageListener!,
      );

      final joinResult = await _manager.joinGroup(
        groupID: info.groupId,
        message: 'Join realtime media chat',
        groupType: 'Meeting',
      );
      // 10013 means the user is already in the group. Treat that as success.
      if ((joinResult.code ?? -1) != 0 && (joinResult.code ?? -1) != 10013) {
        _requireSuccess(joinResult, 'join Tencent Chat group');
      }
      _joinedGroup = true;
      _connected = true;
      _events.onConnected?.call();
    } catch (_) {
      await _cleanupSessionState(emitDisconnected: false);
      rethrow;
    }
  }

  @override
  Future<void> sendMessage(String message) async {
    final info = _requireInfo();
    final messageManager = _manager.getMessageManager();
    final created = await messageManager.createTextMessage(text: message);
    _requireSuccess(created, 'create Tencent Chat message');
    final id = created.data?.id?.toString().trim() ?? '';
    if (id.isEmpty) {
      throw StateError('Tencent Chat returned an empty message creation id.');
    }
    final metadata = jsonEncode({
      'userId': info.userId,
      'displayName': info.displayName,
      if (info.avatarUrl != null) 'avatarUrl': info.avatarUrl,
      'participantId': info.participantId,
    });
    final result = await messageManager.sendMessage(
      id: id,
      receiver: '',
      groupID: info.groupId,
      cloudCustomData: metadata,
    );
    _requireSuccess(result, 'send Tencent Chat message');
    final sent = result.data;
    if (sent != null) _emitMessage(sent);
  }

  @override
  Future<void> deleteMessage(String messageId) async =>
      throw UnsupportedError('Tencent Chat moderation is not enabled.');

  @override
  Future<void> disconnectUser(String userId) async =>
      throw UnsupportedError('Tencent Chat moderation is not enabled.');

  @override
  Future<void> disconnect() => _cleanupSessionState(emitDisconnected: true);

  Future<void> _cleanupSessionState({required bool emitDisconnected}) async {
    final info = _info;
    if (_joinedGroup && info != null) {
      try {
        await _manager.quitGroup(groupID: info.groupId);
      } catch (_) {
        // Group cleanup is best-effort. Logging out below is authoritative
        // for this client session.
      }
      _joinedGroup = false;
    }
    final listener = _messageListener;
    if (listener != null) {
      try {
        await _manager.getMessageManager().removeAdvancedMsgListener(
          listener: listener,
        );
      } catch (_) {
        // Continue cleanup even if the native listener was already removed.
      }
      _messageListener = null;
    }
    if (_loggedIn) {
      try {
        await _manager.logout();
      } catch (_) {
        // A failed join can leave the native SDK in a partially logged-in
        // state. Disposal must still continue so the next attempt starts
        // cleanly.
      }
      _loggedIn = false;
    }
    if (_connected || info != null) {
      final wasConnected = _connected;
      _connected = false;
      if (emitDisconnected && (wasConnected || info != null)) {
        _events.onDisconnected?.call('clientDisconnect');
      }
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;
    _events = const TencentChatEngineEvents();
    _tokenProvider = null;
    _info = null;
  }

  Future<void> _refreshToken() async {
    if (_refreshing || _disposed) return;
    final provider = _tokenProvider;
    final current = _info;
    if (provider == null || current == null) {
      _events.onError?.call(401, 'Tencent Chat UserSig expired.');
      return;
    }
    _refreshing = true;
    try {
      _events.onConnecting?.call(true);
      final refreshed = await provider();
      if (_disposed) return;
      _info = refreshed;
      final result = await _manager.login(
        userID: refreshed.providerUserId,
        userSig: refreshed.userSig,
      );
      _requireSuccess(result, 'refresh Tencent Chat UserSig');
      if (!_disposed) _events.onConnected?.call();
    } catch (error) {
      if (!_disposed) _events.onError?.call(401, error.toString());
    } finally {
      _refreshing = false;
    }
  }

  void _emitMessage(dynamic message) {
    final groupId = message.groupID?.toString().trim() ?? '';
    final info = _info;
    if (info == null || groupId != info.groupId) return;
    final id =
        message.msgID?.toString().trim() ?? message.id?.toString().trim() ?? '';
    if (id.isEmpty) return;
    final text = message.textElem?.text?.toString() ?? '';
    if (text.isEmpty) return;
    final metadata = _decodeMetadata(message.cloudCustomData?.toString());
    final timestamp = _timestampMs(message.timestamp);
    _events.onMessage?.call({
      'id': id,
      'userId': metadata['userId'] ?? message.sender?.toString() ?? '',
      'displayName':
          metadata['displayName'] ??
          message.nameCard?.toString() ??
          message.nickName?.toString() ??
          message.sender?.toString() ??
          '',
      'message': text,
      'timestampMs': timestamp,
      'attributes': <String, String>{
        if (metadata['avatarUrl'] != null) 'avatarUrl': metadata['avatarUrl']!,
        'providerUserId': message.sender?.toString() ?? '',
        if (metadata['participantId'] != null)
          'participantId': metadata['participantId']!,
      },
    });
  }

  Map<String, String> _decodeMetadata(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
      );
    } catch (_) {
      return const {};
    }
  }

  int _timestampMs(dynamic raw) {
    final value = raw is num
        ? raw.toInt()
        : int.tryParse(raw?.toString() ?? '');
    if (value == null || value <= 0) {
      return DateTime.now().millisecondsSinceEpoch;
    }
    return value < 100000000000 ? value * 1000 : value;
  }

  TencentChatJoinInfo _requireInfo() {
    final info = _info;
    if (!_connected || info == null) {
      throw StateError('Tencent Chat engine is not connected.');
    }
    return info;
  }

  void _requireSuccess(dynamic result, String operation) {
    final code = result?.code;
    if (code == 0) return;
    final desc = result?.desc?.toString().trim();
    throw StateError(
      '$operation failed (${code ?? 'unknown'}): '
      '${desc == null || desc.isEmpty ? 'unknown error' : desc}',
    );
  }
}
