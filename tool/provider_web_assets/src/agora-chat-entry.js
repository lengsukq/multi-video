function parsePayload(value) {
  return typeof value === 'string' ? JSON.parse(value) : value;
}

function emit(root, session, type, payload = {}) {
  if (session.disposed) return;
  const callback = root.__flutterAgoraChatOnEvent;
  if (typeof callback === 'function') {
    callback(session.id, type, JSON.stringify(payload));
  }
}

function normalizeMessage(message, session) {
  const attributes = message?.ext && typeof message.ext === 'object'
    ? Object.fromEntries(
      Object.entries(message.ext).map(([key, value]) => [key, String(value)]),
    )
    : {};
  const providerUserId = String(message?.from || '');
  return {
    id: String(message?.id || message?.serverMsgId || ''),
    userId: attributes.userId || providerUserId,
    displayName: attributes.displayName || providerUserId,
    message: String(message?.msg || ''),
    timestampMs: Number(message?.time || Date.now()),
    attributes: {
      ...attributes,
      providerUserId,
    },
    type: 'message',
  };
}

export function createAgoraChatBridge(AC, root = globalThis) {
  let agoraChat = AC;
  for (let depth = 0; depth < 3; depth += 1) {
    if (
      typeof agoraChat?.connection === 'function' &&
      typeof agoraChat?.message?.create === 'function'
    ) {
      break;
    }
    agoraChat = agoraChat?.default;
  }
  if (
    typeof agoraChat?.connection !== 'function' ||
    typeof agoraChat?.message?.create !== 'function'
  ) {
    throw new TypeError(
      'The bundled Agora Chat SDK does not expose connection and message APIs.',
    );
  }

  const sessions = new Map();

  function requireSession(id) {
    const session = sessions.get(id);
    if (!session) throw new Error(`Unknown Agora Chat session ${id}.`);
    return session;
  }

  async function refreshToken(session) {
    if (session.disposed) return;
    if (session.refreshPromise) return session.refreshPromise;
    session.refreshPromise = (async () => {
      const callback = root.__flutterAgoraChatRequestToken;
      if (typeof callback !== 'function') {
        throw new Error('Agora Chat token refresh callback is unavailable.');
      }
      const refreshed = parsePayload(await callback(session.id));
      if (!refreshed?.token) {
        throw new Error('Agora Chat token refresh returned no token.');
      }
      if (session.disposed) return;
      await session.connection.renewToken(refreshed.token);
      session.token = refreshed.token;
    })().catch((error) => {
      emit(root, session, 'error', {
        code: 401,
        message: `Unable to refresh Agora Chat token: ${error?.message || error}`,
      });
      throw error;
    }).finally(() => {
      session.refreshPromise = null;
    });
    return session.refreshPromise;
  }

  function emitMessages(session, input) {
    if (session.disposed) return;
    const messages = Array.isArray(input) ? input : [input];
    for (const message of messages) {
      if (message?.type !== 'txt' || message?.chatType !== 'chatRoom') continue;
      if (String(message.to || '') !== session.chatRoomId) continue;
      const normalized = normalizeMessage(message, session);
      if (normalized.id && normalized.userId) {
        emit(root, session, 'message', normalized);
      }
    }
  }

  return {
    async create(id, serializedInfo) {
      if (sessions.has(id)) throw new Error(`Agora Chat session ${id} already exists.`);
      const info = parsePayload(serializedInfo);
      const chat = info?.chat;
      if (!chat?.appKey || !chat?.chatRoomId || !chat?.providerUserId || !chat?.token) {
        throw new Error('Agora Chat join information is incomplete.');
      }

      // The macOS plugin hosts this SDK in a file:// WKWebView. Agora Chat
      // otherwise treats that origin as non-HTTPS and picks ws:// endpoints.
      const connection = new agoraChat.connection({
        appKey: chat.appKey,
        https: true,
      });
      const session = {
        id,
        connection,
        chatRoomId: chat.chatRoomId,
        providerUserId: chat.providerUserId,
        token: chat.token,
        joined: false,
        disposed: false,
        refreshPromise: null,
        handlerId: `flutter-agora-chat-${id}`,
      };
      session.handler = {
        onConnected() {
          if (!session.disposed && session.joined) emit(root, session, 'connected');
        },
        onReconnecting() {
          if (!session.disposed) emit(root, session, 'connecting', { reconnecting: true });
        },
        onDisconnected(error) {
          if (session.disposed) return;
          const reason = error?.message || error?.type || 'connectionClosed';
          emit(root, session, 'disconnected', { reason: String(reason) });
        },
        onError(error) {
          if (session.disposed) return;
          emit(root, session, 'error', {
            code: Number(error?.type || -1),
            message: String(error?.message || 'Agora Chat reported an error.'),
          });
        },
        onTokenWillExpire() {
          if (!session.disposed) void refreshToken(session).catch(() => {});
        },
        onTokenExpired() {
          if (!session.disposed) void refreshToken(session).catch(() => {});
        },
        onMessage(message) {
          emitMessages(session, message);
        },
        onChatroomEvent(event) {
          if (session.disposed) return;
          if (String(event?.id || '') !== session.chatRoomId) return;
          if (event.operation === 'destroy') {
            session.joined = false;
            emit(root, session, 'disconnected', { reason: 'chatRoomDestroyed' });
          } else if (event.operation === 'removeMember') {
            const participant = String(event?.detail?.username || '');
            if (participant) emit(root, session, 'userDisconnected', { userId: participant });
            if (!participant || participant === session.providerUserId) {
              session.joined = false;
              emit(root, session, 'disconnected', { reason: 'removedFromChatRoom' });
            }
          }
        },
      };
      connection.addEventHandler(session.handlerId, session.handler);
      sessions.set(id, session);
    },

    async connect(id) {
      const session = requireSession(id);
      emit(root, session, 'connecting', { reconnecting: false });
      await session.connection.open({
        user: session.providerUserId,
        accessToken: session.token,
      });
      try {
        if (session.disposed) {
          throw new Error('Agora Chat session was disposed during connect.');
        }
        await session.connection.joinChatRoom({ roomId: session.chatRoomId });
      } catch (error) {
        try {
          session.connection.close();
        } catch (_) {
          // Preserve the original joinChatRoom error.
        }
        throw error;
      }
      session.joined = true;
      emit(root, session, 'connected');
    },

    async command(id, command, serializedArguments) {
      const session = requireSession(id);
      if (!session.joined) throw new Error('Agora Chat room is not connected.');
      const args = parsePayload(serializedArguments) || {};
      if (command !== 'sendMessage') {
        throw new Error(`Unsupported Agora Chat operation ${command}.`);
      }
      const message = agoraChat.message.create({
        chatType: 'chatRoom',
        type: 'txt',
        to: session.chatRoomId,
        msg: args.message,
        ext: {
          userId: args.userId,
          displayName: args.displayName,
          ...(args.avatarUrl ? { avatarUrl: args.avatarUrl } : {}),
          participantId: args.participantId,
        },
      });
      const result = await session.connection.send(message);
      const sent = result?.message || message;
      if (result?.serverMsgId) sent.id = result.serverMsgId;
      if (!sent.from) sent.from = session.providerUserId;
      if (!sent.time) sent.time = Date.now();
      emitMessages(session, sent);
    },

    async disconnect(id) {
      const session = sessions.get(id);
      if (!session) return;
      if (session.joined) {
        try {
          await session.connection.quitChatRoom({ roomId: session.chatRoomId });
        } finally {
          session.joined = false;
        }
      }
      session.connection.close();
      emit(root, session, 'disconnected', { reason: 'clientDisconnect' });
    },

    async dispose(id) {
      const session = sessions.get(id);
      if (!session) return;
      session.disposed = true;
      session.joined = false;
      try {
        session.connection.close();
      } finally {
        session.connection.removeEventHandler(session.handlerId);
        sessions.delete(id);
      }
    },
  };
}
