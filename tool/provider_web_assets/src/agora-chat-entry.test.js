import assert from 'node:assert/strict';
import test from 'node:test';

import { createAgoraChatBridge } from './agora-chat-entry.js';

function setup() {
  const events = [];
  const calls = [];
  let connection;
  const root = {
    __flutterAgoraChatOnEvent: (id, type, payload) => {
      events.push({ id, type, payload: JSON.parse(payload) });
    },
    __flutterAgoraChatRequestToken: async () => JSON.stringify({ token: 'token-2' }),
  };
  class FakeConnection {
    constructor(options) {
      this.options = options;
      this.handlers = new Map();
      connection = this;
    }

    addEventHandler(id, handler) {
      calls.push(`add:${id}`);
      this.handlers.set(id, handler);
    }

    removeEventHandler(id) {
      calls.push(`remove:${id}`);
      this.handlers.delete(id);
    }

    async open(options) {
      calls.push('open');
      this.login = options;
    }

    async joinChatRoom(options) {
      calls.push('join');
      this.joined = options;
    }

    async send(message) {
      calls.push('send');
      this.lastMessage = message;
      return { serverMsgId: 'server-message-1', message };
    }

    async renewToken(token) {
      calls.push(`renew:${token}`);
    }

    async quitChatRoom(options) {
      calls.push('quit');
      this.quit = options;
    }

    close() {
      calls.push('close');
    }
  }
  const AC = {
    connection: FakeConnection,
    message: {
      create: (message) => ({ id: 'local-message-1', time: 1234, ...message }),
    },
  };
  const bridge = createAgoraChatBridge(AC, root);
  return { bridge, events, calls, getConnection: () => connection };
}

const credentials = JSON.stringify({
  chat: {
    appKey: 'org#app',
    chatRoomId: 'room-1',
    providerUserId: 'provider-user',
    token: 'token-1',
  },
});

test('logs into the room, sends normalized text, refreshes token, and tears down', async () => {
  const { bridge, events, calls, getConnection } = setup();
  await bridge.create('s1', credentials);
  const connection = getConnection();
  assert.deepEqual(connection.options, { appKey: 'org#app', https: true });

  await bridge.connect('s1');
  assert.deepEqual(connection.login, {
    user: 'provider-user',
    accessToken: 'token-1',
  });
  assert.deepEqual(connection.joined, { roomId: 'room-1' });
  assert.deepEqual(events.map(({ type }) => type), ['connecting', 'connected']);

  await bridge.command('s1', 'sendMessage', JSON.stringify({
    message: 'hello',
    userId: 'logical-user',
    displayName: 'Ada',
    avatarUrl: 'https://avatar.test/ada.png',
    participantId: 'participant-1',
  }));
  assert.equal(connection.lastMessage.chatType, 'chatRoom');
  assert.equal(connection.lastMessage.to, 'room-1');
  assert.equal(connection.lastMessage.ext.userId, 'logical-user');
  const sent = events.find(({ type }) => type === 'message').payload;
  assert.equal(sent.id, 'server-message-1');
  assert.equal(sent.userId, 'logical-user');
  assert.equal(sent.displayName, 'Ada');
  assert.equal(sent.attributes.avatarUrl, 'https://avatar.test/ada.png');
  assert.equal(sent.message, 'hello');

  const handler = [...connection.handlers.values()][0];
  handler.onMessage({
    id: 'incoming-1',
    chatType: 'chatRoom',
    type: 'txt',
    to: 'room-1',
    from: 'other-provider-user',
    msg: 'from another participant',
    time: 5678,
    ext: { userId: 'other-user', displayName: 'Grace' },
  });
  const incoming = events.find(({ payload }) => payload.id === 'incoming-1').payload;
  assert.equal(incoming.userId, 'other-user');
  assert.equal(incoming.displayName, 'Grace');
  assert.equal(incoming.timestampMs, 5678);

  handler.onTokenWillExpire();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.ok(calls.includes('renew:token-2'));

  await bridge.disconnect('s1');
  assert.ok(calls.includes('quit'));
  assert.ok(calls.includes('close'));
  assert.equal(events.at(-1).payload.reason, 'clientDisconnect');
  await bridge.dispose('s1');
  assert.equal(connection.handlers.size, 0);
  assert.ok(calls.some((call) => call.startsWith('remove:')));
});

test('rejects operations for unsupported management APIs', async () => {
  const { bridge } = setup();
  await bridge.create('s2', credentials);
  await bridge.connect('s2');
  await assert.rejects(
    bridge.command('s2', 'deleteMessage', JSON.stringify({ messageId: 'm1' })),
    /Unsupported Agora Chat operation/,
  );
  await bridge.dispose('s2');
});

test('closes opened Agora Chat socket immediately when joinChatRoom rejects', async () => {
  const { bridge, calls, getConnection } = setup();
  await bridge.create('s3', credentials);
  const connection = getConnection();
  connection.joinChatRoom = async () => {
    calls.push('join:failed');
    throw new Error('chatroom permission denied');
  };
  await assert.rejects(bridge.connect('s3'), /chatroom permission denied/);
  assert.deepEqual(calls.slice(1), ['open', 'join:failed', 'close']);
  await bridge.dispose('s3');
});
