/* Agora Chat Windows WebView2 message bridge.
 * The bundled AgoraChatBridge is the same provider used by Flutter Web/macOS.
 * No app key or chat token is stored on disk or logged.
 */
(function installAgoraWindowsChatHost(global) {
  'use strict';
  const host = global.chrome && global.chrome.webview;
  const channel = 'agora-chat-windows-v1';
  if (!host || global.location.origin !== 'https://agora-chat-local.invalid') return;
  let nextTokenId = 0;
  const pendingTokens = new Map();

  global.__flutterAgoraChatOnEvent = function(sessionId, type, payload) {
    let body;
    try { body = JSON.parse(String(payload)); } catch (_) { return; }
    host.postMessage({
      channel, kind: 'event', sessionId: String(sessionId),
      eventType: String(type), payload: body,
    });
  };
  global.__flutterAgoraChatRequestToken = function(sessionId) {
    return new Promise((resolve, reject) => {
      const id = ++nextTokenId;
      const timeout = global.setTimeout(() => {
        pendingTokens.delete(id);
        reject(new Error('Agora Chat token refresh timed out.'));
      }, 30000);
      pendingTokens.set(id, {resolve, reject, timeout});
      host.postMessage({
        channel, kind: 'tokenRequest', sessionId: String(sessionId), id,
      });
    });
  };

  host.addEventListener('message', async function(event) {
    const request = event.data;
    if (!request || request.channel !== channel ||
        !Number.isSafeInteger(request.id) || request.id < 1) return;
    if (request.operation === 'tokenResult') {
      const waiter = pendingTokens.get(request.id);
      if (!waiter) return;
      pendingTokens.delete(request.id);
      global.clearTimeout(waiter.timeout);
      if (request.success === true && typeof request.token === 'string') {
        waiter.resolve(JSON.stringify({token: request.token}));
      } else {
        waiter.reject(new Error('Agora Chat token refresh failed.'));
      }
      return;
    }
    const bridge = global.AgoraChatBridge;
    try {
      if (!bridge) throw new Error('Agora Chat JavaScript SDK bridge is unavailable.');
      const sessionId = String(request.sessionId || '');
      if (!sessionId || !sessionId.startsWith('agora-windows-')) {
        throw new Error('Agora Chat Windows session identifier is invalid.');
      }
      let value;
      switch (request.operation) {
        case 'create':
          value = await bridge.create(sessionId, JSON.stringify(request.payload || {}));
          break;
        case 'connect':
          value = await bridge.connect(sessionId);
          break;
        case 'command':
          value = await bridge.command(sessionId, String(request.name || ''),
            JSON.stringify(request.payload || {}));
          break;
        case 'disconnect':
          value = await bridge.disconnect(sessionId);
          break;
        case 'dispose':
          value = await bridge.dispose(sessionId);
          break;
        default:
          throw new Error('Unsupported Agora Chat Windows operation.');
      }
      host.postMessage({channel, kind: 'result', id: request.id, success: true,
        value: value == null ? null : value});
    } catch (error) {
      host.postMessage({channel, kind: 'result', id: request.id, success: false,
        message: String(error && error.message || error)});
    }
  });
  global.__agoraWindowsChatHost = channel;
})(globalThis);
