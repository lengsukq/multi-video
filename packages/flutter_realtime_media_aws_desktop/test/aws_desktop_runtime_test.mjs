import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const runtimeSource = await readFile(
  new URL('../macos/Resources/aws_desktop_runtime.js', import.meta.url),
  'utf8',
);

function createRuntime() {
  const messages = [];
  const context = {
    webkit: {
      messageHandlers: {
        awsDesktop: { postMessage: (message) => messages.push(message) },
      },
    },
    setTimeout,
    clearTimeout,
  };
  context.globalThis = context;
  vm.runInNewContext(runtimeSource, context);
  return { context, messages };
}

function createVideoRuntime(options = {}) {
  const runtime = createRuntime();
  const tracks = [];
  const nativeCommands = [];
  let frameRequestCount = 0;

  class FakeCanvas {
    constructor() {
      this.width = 300;
      this.height = 150;
      this.context = {
        fillStyle: '',
        fillRect() {},
        drawImage() {},
        getImageData() { return { data: [0, 255, 0, 255] }; },
      };
    }

    getContext() { return this.context; }
    toDataURL() { return 'data:image/png;base64,AA=='; }

    captureStream() {
      const track = {
        enabled: true,
        readyState: 'live',
        requestFrame() {},
        stop() { this.readyState = 'ended'; },
      };
      tracks.push(track);
      return {
        getVideoTracks() { return [track]; },
        getTracks() { return [track]; },
      };
    }
  }

  class FakeImage {
    naturalWidth = 0;
    naturalHeight = 0;
    onload = null;
    onerror = null;

    set src(url) {
      this.url = url;
      if (!url) return;
      setTimeout(() => {
        if (url.includes('/probe/')) {
          this.naturalWidth = 1;
          this.naturalHeight = 1;
          this.onload?.();
          return;
        }
        frameRequestCount += 1;
        if (options.failFrames) {
          this.onerror?.();
          return;
        }
        this.naturalWidth = options.frameWidth || 640;
        this.naturalHeight = options.frameHeight || 360;
        this.onload?.();
      }, 0);
    }
  }

  runtime.context.document = {
    createElement(name) {
      if (name !== 'canvas') throw new Error('Unexpected element: ' + name);
      return new FakeCanvas();
    },
  };
  runtime.context.Image = FakeImage;
  runtime.context.MediaProviderBridge = {
    async command(providerId, sessionId, name, serializedArgs) {
      nativeCommands.push({ providerId, sessionId, name, args: JSON.parse(serializedArgs) });
    },
  };

  return {
    ...runtime,
    tracks,
    nativeCommands,
    get frameRequestCount() { return frameRequestCount; },
  };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

async function waitFor(predicate, description) {
  const deadline = Date.now() + 1000;
  while (!predicate() && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 2));
  }
  assert.ok(predicate(), 'Timed out waiting for ' + description);
}

test('dispatches IVS Chat operations to the bundled provider bridge', async () => {
  const { context } = createRuntime();
  const operations = [];
  context.IvsChatMessagingBridge = {
    async create(id, payload) {
      operations.push(['create', id, JSON.parse(payload)]);
    },
    async connect(id) {
      operations.push(['connect', id]);
    },
    async command(id, name, payload) {
      operations.push(['command', id, name, JSON.parse(payload)]);
    },
    async dispose(id) {
      operations.push(['dispose', id]);
    },
  };

  await context.AwsDesktopChatRuntime.invoke('create', 'session-1', {
    chat: { region: 'us-west-2', token: 'token-1' },
  });
  await context.AwsDesktopChatRuntime.invoke('connect', 'session-1', {});
  await context.AwsDesktopChatRuntime.invoke('command', 'session-1', {
    name: 'sendMessage',
    arguments: { message: 'hello' },
  });
  await context.AwsDesktopChatRuntime.invoke('dispose', 'session-1', {});

  assert.deepEqual(operations, [
    ['create', 'session-1', { chat: { region: 'us-west-2', token: 'token-1' } }],
    ['connect', 'session-1'],
    ['command', 'session-1', 'sendMessage', { message: 'hello' }],
    ['dispose', 'session-1'],
  ]);
});

test('forwards Chat events and completes token refresh requests', async () => {
  const { context, messages } = createRuntime();
  context.__flutterIvsChatOnEvent(
    'session-2',
    'message',
    JSON.stringify({ id: 'message-1', userId: 'user-1' }),
  );
  assert.deepEqual(
    JSON.parse(JSON.stringify(messages.at(-1))),
    {
      kind: 'chatEvent',
      sessionId: 'session-2',
      event: { type: 'message', id: 'message-1', userId: 'user-1' },
    },
  );

  const tokenPromise = context.__flutterIvsChatRequestToken('session-2');
  const request = messages.at(-1);
  assert.equal(request.kind, 'chatTokenRequest');
  assert.equal(request.sessionId, 'session-2');
  const token = {
    token: 'refreshed-token',
    tokenExpirationTimeMs: 2000,
    sessionExpirationTimeMs: 3000,
  };
  assert.equal(
    context.AwsDesktopChatRuntime.resolveToken(request.requestId, token, null),
    true,
  );
  assert.deepEqual(await tokenPromise, token);
});

test('rejects token refresh and reports a missing IVS Chat bridge', async () => {
  const { context } = createRuntime();
  const tokenPromise = context.__flutterIvsChatRequestToken('session-3');
  await context.AwsDesktopChatRuntime.resolveToken(
    'ivs-chat-token-1',
    null,
    'backend token refresh failed',
  );
  await assert.rejects(tokenPromise, /backend token refresh failed/);
  await assert.rejects(
    context.AwsDesktopChatRuntime.invoke('connect', 'session-3', {}),
    /bundled Amazon IVS Chat bridge is unavailable/,
  );
});

test('keeps a shared native processed source alive until both providers detach', async () => {
  const { context, tracks, nativeCommands } = createVideoRuntime();
  await context.AwsDesktopRuntime.attachProcessedVideo('chime', 'chime-session', 'shared-source', 1);
  const track = context.RealtimeVideoEffectsBridge.getTrack('shared-source');
  await context.AwsDesktopRuntime.attachProcessedVideo('ivs', 'ivs-session', 'shared-source', 1);
  assert.strictEqual(context.RealtimeVideoEffectsBridge.getTrack('shared-source'), track);

  await context.AwsDesktopRuntime.detachProcessedVideo('chime', 'chime-session', 'shared-source', 2);
  assert.equal(track.readyState, 'live');
  await context.AwsDesktopRuntime.detachProcessedVideo('ivs', 'ivs-session', 'shared-source', 2);
  assert.equal(track.readyState, 'ended');
  assert.equal(tracks.filter((value) => value.readyState === 'ended').length, 3);
  assert.deepEqual(nativeCommands.map((value) => [value.providerId, value.name]), [
    ['chime', 'attachProcessedVideoSource'],
    ['ivs', 'attachProcessedVideoSource'],
    ['chime', 'detachProcessedVideoSource'],
    ['ivs', 'detachProcessedVideoSource'],
  ]);
});

test('cancels an attach that is still waiting for WebKit capability checks', async () => {
  const { context, nativeCommands } = createVideoRuntime();
  const capability = deferred();
  context.AwsDesktopRuntime.canConsumeProcessedVideo = () => capability.promise;
  const attaching = context.AwsDesktopRuntime.attachProcessedVideo('chime', 'session', 'late-source', 1);
  await context.AwsDesktopRuntime.detachProcessedVideo('chime', 'session', null, 2);
  capability.resolve(true);
  assert.equal(await attaching, false);
  assert.deepEqual(nativeCommands.map((value) => value.name), ['detachProcessedVideoSource']);
  assert.throws(() => context.RealtimeVideoEffectsBridge.getTrack('late-source'), /Unknown native processed video source/);
});

test('serializes attach and detach when leave races with a native attach command', async () => {
  const { context, tracks, nativeCommands } = createVideoRuntime();
  const pendingAttach = deferred();
  const attachStarted = deferred();
  context.MediaProviderBridge.command = async (providerId, sessionId, name, serializedArgs) => {
    nativeCommands.push({ providerId, sessionId, name, args: JSON.parse(serializedArgs) });
    if (name === 'attachProcessedVideoSource') {
      attachStarted.resolve();
      await pendingAttach.promise;
    }
  };

  const attaching = context.AwsDesktopRuntime.attachProcessedVideo('chime', 'racing-session', 'racing-source', 1);
  await attachStarted.promise;
  const track = context.RealtimeVideoEffectsBridge.getTrack('racing-source');
  const detaching = context.AwsDesktopRuntime.detachProcessedVideo('chime', 'racing-session', 'racing-source', 2);
  assert.equal(track.readyState, 'ended');
  pendingAttach.resolve();
  await Promise.all([attaching, detaching]);
  assert.deepEqual(nativeCommands.map((value) => value.name), [
    'attachProcessedVideoSource',
    'detachProcessedVideoSource',
  ]);
  assert.equal(tracks[1].readyState, 'ended');
});

test('reports native image decoding failures and stops the captured track', async () => {
  const { context, messages, tracks, nativeCommands } = createVideoRuntime({ failFrames: true });
  await context.AwsDesktopRuntime.attachProcessedVideo('chime', 'failing-session', 'broken-source', 1);
  await waitFor(
    () => messages.some((message) => message.kind === 'processedVideoError'),
    'processed-video sourceError',
  );
  const track = context.RealtimeVideoEffectsBridge.getTrack('broken-source');
  assert.equal(track.readyState, 'ended');
  assert.equal(track.enabled, false);
  assert.equal(messages.at(-1).sourceId, 'broken-source');
  assert.equal(context.AwsDesktopRuntime.snapshot('failing-session'), null);
  assert.equal(nativeCommands[0].name, 'attachProcessedVideoSource');
  await assert.rejects(context.RealtimeVideoEffectsBridge.setEnabled('broken-source', true), /failed/);
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(tracks[1].readyState, 'ended');
});

test('native frame notifications replace fixed polling and coalesce decode backlog', async () => {
  const h = createVideoRuntime();
  const runtime = h.context.AwsDesktopRuntime;
  await runtime.attachProcessedVideo('chime', 'meeting', 'shared-frames', 1);
  await waitFor(() => h.frameRequestCount === 1, 'initial native frame');
  await new Promise(resolve => setTimeout(resolve, 60));
  assert.equal(h.frameRequestCount, 1);
  runtime.notifyProcessedFrame('shared-frames', '100000001');
  runtime.notifyProcessedFrame('SHARED-FRAMES', '100000001');
  runtime.notifyProcessedFrame('shared-frames', '100000002');
  runtime.notifyProcessedFrame('shared-frames', '100000003');
  await waitFor(() => h.frameRequestCount === 3, 'current plus newest pending frame');
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(h.frameRequestCount, 3);
  runtime.notifyProcessedFrame('shared-frames', '100000003');
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(h.frameRequestCount, 3);
  await h.context.RealtimeVideoEffectsBridge.setEnabled('shared-frames', false);
  runtime.notifyProcessedFrame('shared-frames', '100000004');
  runtime.notifyProcessedFrame('shared-frames', '100000005');
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(h.frameRequestCount, 3);
  await h.context.RealtimeVideoEffectsBridge.setEnabled('shared-frames', true);
  await waitFor(() => h.frameRequestCount === 4, 'newest muted frame on resume');
  await runtime.detachProcessedVideo('chime', 'meeting', 'shared-frames', 2);
  runtime.notifyProcessedFrame('shared-frames', '100000006');
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(h.frameRequestCount, 4);
});

test('desktop video display follows decoded frames up to 30 fps and cancels on detach', async () => {
  const h = createRuntime();
  const video = {readyState:2, videoWidth:1280, videoHeight:720,
    requestVideoFrameCallback(callback) {this.callback=callback; return 1;},
    cancelVideoFrameCallback() {this.callback=null;}};
  const canvas = {width:0,height:0,getContext(){return {drawImage(){}};},
    toDataURL(){return 'data:image/jpeg;base64,AA==';}};
  const container = {querySelector(){return video;},remove(){}};
  h.context.document = {body:{appendChild(){}},
    createElement(name){return name==='canvas'?canvas:container;}};
  h.context.MediaProviderBridge = {async attachVideo(){},detachVideo(){}};
  const runtime=h.context.AwsDesktopRuntime;
  await runtime.bindTrack('chime','session','remote','view');
  for(let index=0;index<30;index++) video.callback(index*1000/30,{mediaTime:index/30});
  assert.equal(h.messages.filter(value=>value.kind==='frame').length,30);
  assert.equal(canvas.width,960); assert.equal(canvas.height,540);
  video.callback(1100,{mediaTime:29/30});
  assert.equal(h.messages.filter(value=>value.kind==='frame').length,30);
  const staleCallback=video.callback;
  runtime.unbindTrack('view');
  assert.equal(video.callback,null);
  staleCallback(1200,{mediaTime:1.2});
  assert.equal(h.messages.filter(value=>value.kind==='frame').length,30);
});

test('desktop video display advances on presentedFrames when WebKit keeps mediaTime at zero', async () => {
  const h = createRuntime();
  const video = {
    readyState: 2,
    videoWidth: 960,
    videoHeight: 540,
    requestVideoFrameCallback(callback) { this.callback = callback; return 1; },
    cancelVideoFrameCallback() { this.callback = null; },
  };
  const canvas = {
    width: 0,
    height: 0,
    getContext() { return { drawImage() {} }; },
    toDataURL() { return 'data:image/jpeg;base64,AA=='; },
  };
  const container = { querySelector() { return video; }, remove() {} };
  h.context.document = {
    body: { appendChild() {} },
    createElement(name) { return name === 'canvas' ? canvas : container; },
  };
  h.context.MediaProviderBridge = { async attachVideo() {}, detachVideo() {} };
  const runtime = h.context.AwsDesktopRuntime;
  await runtime.bindTrack('chime', 'session', 'remote', 'view');

  for (let index = 1; index <= 5; index++) {
    video.callback(index * 1000 / 30, { mediaTime: 0, presentedFrames: index });
  }
  assert.equal(h.messages.filter((value) => value.kind === 'frame').length, 5);
  video.callback(400, { mediaTime: 0, presentedFrames: 5 });
  assert.equal(h.messages.filter((value) => value.kind === 'frame').length, 5);
  runtime.unbindTrack('view');
});

test('async toBlob + awsDesktopFrame reply enforces single-frame backpressure and dynamic target sizing', async () => {
  const messages = [];
  const framePosts = [];
  let pendingReplyResolve = null;
  const context = {
    webkit: {
      messageHandlers: {
        awsDesktop: { postMessage: (msg) => messages.push(msg) },
        awsDesktopFrame: {
          postMessage: (msg) => {
            framePosts.push(msg);
            return new Promise((resolve) => {
              pendingReplyResolve = resolve;
            });
          },
        },
      },
    },
    setTimeout,
    clearTimeout,
  };
  context.globalThis = context;
  vm.runInNewContext(runtimeSource, context);

  let drawCount = 0;
  const video = {
    readyState: 2,
    videoWidth: 1920,
    videoHeight: 1080,
    requestVideoFrameCallback(callback) { this.callback = callback; return 1; },
    cancelVideoFrameCallback() { this.callback = null; },
  };
  const canvas = {
    width: 0,
    height: 0,
    getContext() { return { drawImage() { drawCount += 1; } }; },
    toBlob(callback) {
      callback({ dataUrl: 'data:image/jpeg;base64,/9j/4AAQSkZJRg==' });
    },
  };
  const container = { style: {}, querySelector() { return video; }, remove() {} };
  context.document = {
    body: { appendChild() {} },
    createElement(name) { return name === 'canvas' ? canvas : container; },
  };
  context.MediaProviderBridge = { async attachVideo() {}, detachVideo() {} };

  await context.AwsDesktopRuntime.bindTrack('chime', 'session', 'remote', 'tile-1', {
    maxDimension: 480,
  });
  video.callback(40, { mediaTime: 0, presentedFrames: 1 });
  await waitFor(() => framePosts.length === 1, 'first async frame post');
  assert.equal(canvas.width, 480);
  assert.equal(canvas.height, 270);
  assert.equal(drawCount, 1);

  // While native decode has not replied yet, incoming frames must skip GPU readback.
  video.callback(80, { mediaTime: 0, presentedFrames: 2 });
  video.callback(120, { mediaTime: 0, presentedFrames: 3 });
  assert.equal(drawCount, 1);
  assert.equal(framePosts.length, 1);

  // Resolve native reply and dynamically upgrade target bucket to 1280p.
  assert.equal(
    context.AwsDesktopRuntime.configureTrackView('tile-1', { maxDimension: 1280 }),
    true,
  );
  pendingReplyResolve(true);
  await new Promise((resolve) => setTimeout(resolve, 5));

  video.callback(160, { mediaTime: 0, presentedFrames: 4 });
  await waitFor(() => framePosts.length === 2, 'second async frame after ack');
  assert.equal(canvas.width, 1280);
  assert.equal(canvas.height, 720);
  assert.equal(drawCount, 2);

  pendingReplyResolve(true);
  context.AwsDesktopRuntime.unbindTrack('tile-1');
});

test('Windows WebView2 host binds both local and remote IVS participant tracks without collision', async () => {
  const windowsRuntimeSource = await readFile(
    new URL('../assets/windows_runtime.js', import.meta.url),
    'utf8',
  );
  const windowsHostSource = await readFile(
    new URL('../assets/windows_host.js', import.meta.url),
    'utf8',
  );
  const posted = [];
  let messageHandler = null;
  const boundTrackIds = [];

  const video = {
    readyState: 2,
    videoWidth: 1280,
    videoHeight: 720,
    requestVideoFrameCallback() { return 1; },
    cancelVideoFrameCallback() {},
  };
  const canvas = {
    width: 0,
    height: 0,
    getContext() { return { drawImage() {} }; },
    toDataURL() { return 'data:image/jpeg;base64,AA=='; },
  };
  const makeContainer = () => ({
    id: '',
    style: {},
    querySelector() { return video; },
    remove() {},
  });

  const context = {
    chrome: {
      webview: {
        postMessage: (msg) => posted.push(msg),
        addEventListener: (event, fn) => {
          if (event === 'message') messageHandler = fn;
        },
      },
    },
    location: { hostname: 'aws-ivs-local.invalid' },
    navigator: {
      mediaDevices: {
        enumerateDevices: async () => [
          { kind: 'audioinput', deviceId: 'mic-1', label: 'Mic 1' },
          { kind: 'videoinput', deviceId: 'cam-1', label: 'Cam 1' },
        ],
      },
    },
    document: {
      body: { appendChild() {} },
      createElement(name) { return name === 'canvas' ? canvas : makeContainer(); },
    },
    MediaProviderBridge: {
      async attachVideo(_providerId, _sessionId, trackId) {
        boundTrackIds.push(trackId);
      },
      detachVideo() {},
    },
    setTimeout,
    clearTimeout,
  };
  context.globalThis = context;

  vm.runInNewContext(windowsRuntimeSource, context, { filename: 'windows_runtime.js' });
  vm.runInNewContext(windowsHostSource, context, { filename: 'windows_host.js' });
  assert.equal(context.__awsWindowsHostChannel, 'aws-windows-ivs-v1');

  context.__flutterMediaProviderOnEvent(
    'aws-desktop-ivs',
    JSON.stringify({
      type: 'snapshot',
      tracks: [
        { id: 'ivs:local:stream-self', participantId: 'host-user', isLocal: true, isScreenShare: false },
        { id: 'ivs:remote-user:stream-peer', participantId: 'remote-user', isLocal: false, isScreenShare: false },
      ],
    }),
  );

  await messageHandler({
    data: {
      channel: 'aws-windows-ivs-v1',
      id: 1,
      operation: 'bind',
      trackId: 'ivs:local-participant:host-user',
      viewKey: 'ivs-view-local',
    },
  });
  await messageHandler({
    data: {
      channel: 'aws-windows-ivs-v1',
      id: 2,
      operation: 'bind',
      trackId: 'ivs:participant:remote-user',
      viewKey: 'ivs-view-remote',
    },
  });

  const results = posted.filter((m) => m.kind === 'result');
  assert.equal(results.length, 2);
  assert.equal(results[0].success, true, results[0].message);
  assert.equal(results[1].success, true, results[1].message);
  assert.deepEqual(boundTrackIds, ['ivs:local:stream-self', 'ivs:remote-user:stream-peer']);

  await messageHandler({
    data: {
      channel: 'aws-windows-ivs-v1',
      id: 3,
      operation: 'unbind',
      viewKey: 'ivs-view-local',
    },
  });
  await messageHandler({
    data: {
      channel: 'aws-windows-ivs-v1',
      id: 4,
      operation: 'unbind',
      viewKey: 'ivs-view-remote',
    },
  });
});

test('exposes RealtimeProcessedVideoBridge and non-cloning track for MediaProviderBridge', async () => {
  const { context } = createVideoRuntime();
  assert.strictEqual(context.RealtimeProcessedVideoBridge, context.RealtimeVideoEffectsBridge);
  await context.AwsDesktopRuntime.attachProcessedVideo('chime', 'chime-session', 'blur-source', 1);
  const track = context.RealtimeProcessedVideoBridge.getTrack('blur-source');
  assert.equal(track.clone(), track);
  await context.AwsDesktopRuntime.detachProcessedVideo('chime', 'chime-session', 'blur-source', 2);
});

test('exposes RealtimeScreenCaptureBridge for native macOS screen capture lifecycle', async () => {
  const { context } = createVideoRuntime();
  await context.AwsDesktopRuntime.startScreenCaptureSource('aws-screen-chime-1');
  const track = context.RealtimeScreenCaptureBridge.getTrack('aws-screen-chime-1');
  assert.equal(track.readyState, 'live');
  context.AwsDesktopRuntime.stopScreenCaptureSource('aws-screen-chime-1');
  assert.equal(track.readyState, 'ended');
});


