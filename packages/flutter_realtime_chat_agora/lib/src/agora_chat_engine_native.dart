import 'dart:async';
import 'dart:io';

import 'package:agora_chat_sdk/agora_chat_sdk.dart';
import 'package:flutter_realtime_chat_core/flutter_realtime_chat_core.dart'
    show RealtimeException, RealtimeErrorCode;

import 'agora_chat_engine.dart';
import 'agora_chat_engine_macos.dart' as macos;
import 'agora_chat_engine_windows.dart' as windows;
import 'agora_chat_join_info.dart';

Future<AgoraChatEngine> createPlatformAgoraChatEngine() async =>
    Platform.isMacOS
    ? macos.createMacOSAgoraChatEngine()
    : Platform.isWindows
    ? windows.createWindowsAgoraChatEngine()
    : AgoraSdkChatEngine();

// Internal implementation; not exported by the package entrypoint.
class AgoraSdkChatEngine implements AgoraChatEngine {
  static int _nextHandlerId = 0;
  final String _handlerId = 'flutter_realtime_chat_agora_${_nextHandlerId++}';
  static AgoraSdkChatEngine? _owner;

  AgoraChatEngineEvents _events = const AgoraChatEngineEvents();
  AgoraChatTokenProvider? _tokenProvider;
  AgoraChatJoinInfo? _info;
  bool _connected = false;
  bool _disposed = false;
  bool _refreshing = false;
  bool _loggedIn = false;
  bool _roomJoinAttempted = false;
  bool _connecting = false;
  bool _disconnectRequested = false;
  final Map<String, Completer<void>> _pendingSends = {};
  Duration sendTimeout = const Duration(seconds: 15);

  ChatClient get _client => ChatClient.getInstance;

  @override
  Future<void> connect(
    AgoraChatJoinInfo info,
    AgoraChatEngineEvents events, {
    AgoraChatTokenProvider? tokenProvider,
  }) async {
    if (_disposed) throw StateError('Agora Chat engine is disposed.');
    if (_connecting || _loggedIn || _connected) {
      throw StateError('Agora Chat engine is already active.');
    }
    if (_owner != null && !identical(_owner, this)) {
      throw StateError('Another native Agora Chat session is already active.');
    }
    // ChatClient is a process-wide singleton. Reserve it before any await so
    // another room cannot replace its handlers or log out an active session.
    _owner = this;
    _connecting = true;
    _disconnectRequested = false;
    try {
      await _connect(info, events, tokenProvider: tokenProvider);
    } catch (_) {
      try {
        await disconnect();
      } catch (_) {
        // Preserve the original login/join failure. A later cleanup can retry.
      }
      rethrow;
    } finally {
      _connecting = false;
      _releaseIfIdle();
    }
  }

  Future<void> _connect(
    AgoraChatJoinInfo info,
    AgoraChatEngineEvents events, {
    AgoraChatTokenProvider? tokenProvider,
  }) async {
    _events = events;
    _tokenProvider = tokenProvider;
    _info = info;
    _events.onConnecting?.call(false);

    await _client.init(
      ChatOptions.withAppKey(
        info.appKey,
        autoLogin: false,
        messagesReceiveCallbackIncludeSend: false,
      ),
    );
    _ensureConnecting();
    await _client.startCallback();
    _ensureConnecting();
    _client.addConnectionEventHandler(
      _handlerId,
      ConnectionEventHandler(
        onConnected: () {
          if (_connected) _events.onConnected?.call();
        },
        onDisconnected: () {
          if (_connected) _events.onConnecting?.call(true);
        },
        onUserAuthenticationFailed: () =>
            _events.onError?.call(401, 'Agora Chat authentication failed.'),
        onUserDidForbidByServer: () =>
            _events.onError?.call(403, 'Agora Chat user was forbidden.'),
        onUserDidRemoveFromServer: () {
          _connected = false;
          _events.onDisconnected?.call('userRemoved');
        },
        onUserKickedByOtherDevice: () {
          _connected = false;
          _events.onDisconnected?.call('kickedByOtherDevice');
        },
        onTokenWillExpire: () => unawaited(_refreshToken()),
        onTokenDidExpire: () => unawaited(_refreshToken()),
      ),
    );
    _client.chatManager.addEventHandler(
      _handlerId,
      ChatEventHandler(
        onMessagesReceived: (messages) {
          for (final message in messages) {
            // Local sends are emitted only by their server-confirmed success
            // callback. Some SDK versions also echo them into this listener.
            if (message.from == _info?.providerUserId) continue;
            _emitMessage(message);
          }
        },
        onMessagesRecalled: (messages) {
          for (final message in messages) {
            final id = message.msgId.trim();
            if (id.isNotEmpty) _events.onMessageDeleted?.call(id);
          }
        },
      ),
    );
    _client.chatManager.addMessageEvent(
      _handlerId,
      ChatMessageEvent(
        onSuccess: (localId, message) {
          final pending = _pendingSends.remove(localId);
          if (pending == null || pending.isCompleted) return;
          _emitMessage(message);
          pending.complete();
        },
        onError: (localId, _, error) {
          final pending = _pendingSends.remove(localId);
          if (pending == null || pending.isCompleted) return;
          pending.completeError(error);
        },
      ),
    );
    _client.chatRoomManager.addEventHandler(
      _handlerId,
      ChatRoomEventHandler(
        onRemovedFromChatRoom: (roomId, _, participant, __) {
          if (roomId != info.chatRoomId) return;
          final removed = participant?.trim();
          if (removed != null && removed.isNotEmpty) {
            _events.onUserDisconnected?.call(removed);
          }
          if (removed == null || removed == info.providerUserId) {
            _connected = false;
            _events.onDisconnected?.call('removedFromChatRoom');
          }
        },
        onChatRoomDestroyed: (roomId, _) {
          if (roomId != info.chatRoomId) return;
          _connected = false;
          _events.onDisconnected?.call('chatRoomDestroyed');
        },
      ),
    );

    // Native login can outlive a Dart hot restart or an older failed join.
    // Only stale login is cleared here; active adapter sessions are guarded
    // by _owner above. Reauthenticate using this room's credentials.
    final staleLogin = await _client.isLoginBefore();
    _ensureConnecting();
    if (staleLogin) {
      await _client.logout(false);
      _ensureConnecting();
    }
    await _client.loginWithToken(info.providerUserId, info.token);
    _loggedIn = true;
    _ensureConnecting();
    _roomJoinAttempted = true;
    await _client.chatRoomManager.joinChatRoom(info.chatRoomId);
    _ensureConnecting();
    _connected = true;
    _events.onConnected?.call();
  }

  @override
  Future<void> sendMessage(String message) async {
    final info = _requireInfo();
    final outgoing = ChatMessage.createTxtSendMessage(
      targetId: info.chatRoomId,
      content: message,
      chatType: ChatType.ChatRoom,
    );
    outgoing.attributes = <String, dynamic>{
      'userId': info.userId,
      'displayName': info.displayName,
      if (info.avatarUrl != null) 'avatarUrl': info.avatarUrl,
      'participantId': info.participantId,
    };
    final localId = outgoing.msgId;
    final pending = Completer<void>();
    _pendingSends[localId] = pending;
    try {
      // The vendor send future only acknowledges native enqueueing; its
      // original object still carries a temporary local ID. The success
      // callback above carries the canonical server message ID.
      await Future.wait<void>([
        _client.chatManager.sendMessage(outgoing).then((_) {}),
        pending.future.timeout(
          sendTimeout,
          onTimeout: () {
            throw const RealtimeException(
              code: RealtimeErrorCode.timeout,
              providerId: AgoraChatJoinInfo.providerIdValue,
              message: 'Agora Chat message delivery was not confirmed in time.',
            );
          },
        ),
      ], eagerError: true);
    } finally {
      _pendingSends.remove(localId);
      if (!pending.isCompleted) pending.complete();
    }
  }

  @override
  Future<void> deleteMessage(String messageId) async =>
      throw UnsupportedError('Agora Chat moderation is not enabled.');

  @override
  Future<void> disconnectUser(String userId) async =>
      throw UnsupportedError('Agora Chat moderation is not enabled.');

  @override
  Future<void> disconnect() async {
    _disconnectRequested = true;
    for (final pending in _pendingSends.values) {
      if (!pending.isCompleted) {
        pending.completeError(
          const RealtimeException(
            code: RealtimeErrorCode.cancelled,
            providerId: AgoraChatJoinInfo.providerIdValue,
            message: 'Agora Chat message delivery was cancelled by disconnect.',
          ),
        );
      }
    }
    _pendingSends.clear();
    if (!identical(_owner, this)) return;
    final info = _info;
    if (_roomJoinAttempted && info != null) {
      try {
        await _client.chatRoomManager.leaveChatRoom(info.chatRoomId);
      } catch (_) {
        // Logout below still closes this local session.
      }
      _roomJoinAttempted = false;
    }
    try {
      if (_loggedIn) {
        await _client.logout(false);
        _loggedIn = false;
      }
    } finally {
      _connected = false;
      _events.onDisconnected?.call('clientDisconnect');
      _releaseIfIdle();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    try {
      await disconnect();
    } finally {
      _client.chatManager.removeEventHandler(_handlerId);
      _client.chatManager.removeMessageEvent(_handlerId);
      _client.chatRoomManager.removeEventHandler(_handlerId);
      _client.removeConnectionEventHandler(_handlerId);
      _disposed = true;
      _tokenProvider = null;
      _info = null;
      _releaseIfIdle();
    }
  }

  void _ensureConnecting() {
    if (_disposed || _disconnectRequested) {
      throw StateError('Agora Chat connection was cancelled.');
    }
  }

  void _releaseIfIdle() {
    if (identical(_owner, this) && !_connecting && (!_loggedIn || _disposed)) {
      _owner = null;
    }
  }

  Future<void> _refreshToken() async {
    if (_refreshing ||
        _disposed ||
        _disconnectRequested ||
        !_loggedIn ||
        !identical(_owner, this)) {
      return;
    }
    final provider = _tokenProvider;
    if (provider == null) {
      _events.onError?.call(401, 'Agora Chat token expired.');
      return;
    }
    _refreshing = true;
    try {
      final refreshed = await provider();
      if (_disposed || _disconnectRequested || !identical(_owner, this)) return;
      _info = refreshed;
      await _client.renewAgoraToken(refreshed.token);
      _events.onConnected?.call();
    } catch (error) {
      _events.onError?.call(401, error.toString());
    } finally {
      _refreshing = false;
    }
  }

  void _emitMessage(ChatMessage message) {
    final info = _info;
    if (info == null || message.chatType != ChatType.ChatRoom) return;
    if (message.conversationId != null &&
        message.conversationId != info.chatRoomId &&
        message.to != info.chatRoomId) {
      return;
    }
    final body = message.body;
    if (body is! ChatTextMessageBody) return;
    final id = message.msgId.trim();
    if (id.isEmpty) return;
    final attributes = message.attributes ?? const <String, dynamic>{};
    final logicalUserId =
        attributes['userId']?.toString().trim() ?? message.from?.trim() ?? '';
    if (logicalUserId.isEmpty) return;
    _events.onMessage?.call({
      'id': id,
      'userId': logicalUserId,
      'displayName':
          attributes['displayName']?.toString().trim() ?? logicalUserId,
      'message': body.content,
      'timestampMs': message.serverTime > 0
          ? message.serverTime
          : DateTime.now().millisecondsSinceEpoch,
      'attributes': <String, String>{
        'providerUserId': message.from ?? '',
        if (attributes['avatarUrl'] != null)
          'avatarUrl': attributes['avatarUrl'].toString(),
        if (attributes['participantId'] != null)
          'participantId': attributes['participantId'].toString(),
      },
    });
  }

  AgoraChatJoinInfo _requireInfo() {
    final info = _info;
    if (!_connected || info == null) {
      throw StateError('Agora Chat engine is not connected.');
    }
    return info;
  }
}
