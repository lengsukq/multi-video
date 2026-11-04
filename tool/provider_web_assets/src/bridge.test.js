import { build } from 'esbuild';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

async function createChimeHarness(browserGlobals = {}) {
  const calls = [];
  const events = [];
  let observer;
  let presenceObserver;
  let dataObserver;

  const audioVideo = {
    bindAudioElement(element) {
      assert.equal(element.autoplay, true);
      calls.push('bindRemoteAudio');
    },
    unbindAudioElement() {
      calls.push('unbindRemoteAudio');
    },
    addObserver(value) {
      observer = value;
      calls.push('addObserver');
    },
    removeObserver(value) {
      assert.equal(value, observer);
      calls.push('removeObserver');
    },
    realtimeSubscribeToAttendeeIdPresence(value) {
      presenceObserver = value;
      calls.push('subscribePresence');
    },
    realtimeUnsubscribeToAttendeeIdPresence(value) {
      assert.equal(value, presenceObserver);
      calls.push('unsubscribePresence');
    },
    realtimeSubscribeToReceiveDataMessage(topic, value) {
      assert.equal(topic, 'chat');
      dataObserver = value;
      calls.push('subscribeData');
    },
    realtimeUnsubscribeFromReceiveDataMessage(topic) {
      assert.equal(topic, 'chat');
      calls.push('unsubscribeData');
    },
    async listAudioInputDevices() {
      calls.push('listAudioInputs');
      return [{ deviceId: 'mic-1', label: 'Mic', groupId: 'g1' }];
    },
    async listVideoInputDevices() {
      calls.push('listVideoInputs');
      return [{ deviceId: 'cam-1', label: 'Camera', groupId: 'g2' }];
    },
    async listAudioOutputDevices() {
      calls.push('listAudioOutputs');
      return [{ deviceId: 'speaker-1', label: 'Speaker', groupId: 'g3' }];
    },
    async startAudioInput(deviceId) {
      calls.push(`startAudioInput:${deviceId}`);
    },
    async startVideoInput(deviceId) {
      calls.push(`startVideoInput:${deviceId}`);
    },
    start() {
      calls.push('start');
      observer?.audioVideoDidStart?.();
    },
    startLocalVideoTile() {
      calls.push('startLocalVideoTile');
    },
    stopLocalVideoTile() {
      calls.push('stopLocalVideoTile');
    },
    getAllVideoTiles() {
      return [];
    },
    realtimeMuteLocalAudio() {
      calls.push('mute');
    },
    async realtimeUnmuteLocalAudio() {
      calls.push('unmute');
    },
    async chooseAudioOutput(deviceId) {
      calls.push(`chooseAudioOutput:${deviceId}`);
    },
    realtimeSendDataMessage(topic, message, lifetimeMs) {
      calls.push(`message:${topic}:${message}:${lifetimeMs}`);
    },
    stop() {
      calls.push('stop');
    },
    bindVideoElement() {},
    unbindVideoElement() {},
  };

  class DefaultDeviceController {
    async destroy() {
      calls.push('destroyDeviceController');
    }
  }

  class DefaultMeetingSession {
    constructor() {
      this.audioVideo = audioVideo;
    }
  }

  const context = vm.createContext({
    console,
    TextDecoder,
    Blob,
    document: {
      createElement: (tag) => {
        assert.equal(tag, 'audio');
        return {
          style: {},
          play: async () => { calls.push('playRemoteAudio'); },
          remove: () => { calls.push('removeRemoteAudio'); },
        };
      },
      body: { append: () => { calls.push('appendRemoteAudio'); } },
    },
    setTimeout,
    clearTimeout,
    setInterval: () => 1,
    clearInterval: () => {},
    ...browserGlobals,
    __flutterMediaProviderOnEvent: (sessionId, serializedEvent) => {
      events.push({ sessionId, event: JSON.parse(serializedEvent) });
    },
    ChimeSDK: {
      ConsoleLogger: class {},
      LogLevel: { WARN: 'warn' },
      DefaultDeviceController,
      MeetingSessionConfiguration: class {},
      DefaultMeetingSession,
      MeetingSessionStatusCode: { Left: 'Left' },
    },
  });
  const source = (await build({ entryPoints: [new URL('./bridge.js', import.meta.url).pathname], bundle: true, write: false, format: 'iife', platform: 'browser' })).outputFiles[0].text;
  const effectsSource = await readFile(new URL('../../../packages/flutter_realtime_video_effects/web/video-effects-bridge.js', import.meta.url), 'utf8');
  vm.runInContext(effectsSource, context, {filename: 'video-effects-bridge.js'});
  vm.runInContext(source, context, { filename: 'bridge.js' });
  return {
    bridge: context.MediaProviderBridge,
    audioVideo,
    calls,
    events,
    stopChime: (status) => observer?.audioVideoDidStop?.(status),
    getDataObserver: () => dataObserver,
  };
}

const chimePayload = {
  participantId: 'attendee-1',
  displayName: 'Ada',
  role: 'participant',
  meeting: {
    MeetingId: 'meeting-1',
    ExternalMeetingId: 'external-1',
    MediaRegion: 'us-east-1',
    MediaPlacement: {
      AudioHostUrl: 'https://audio.example',
      AudioFallbackUrl: 'https://fallback.example',
      SignalingUrl: 'wss://signal.example',
      TurnControlUrl: 'https://turn.example',
    },
  },
  attendee: {
    AttendeeId: 'attendee-1',
    ExternalUserId: 'Ada',
    JoinToken: 'token',
  },
};

test('Chime bridge uses the current 3.32 media input APIs', async () => {
  const { bridge, calls } = await createChimeHarness();

  await bridge.create('chime', 'meeting-1', JSON.stringify(chimePayload));
  await bridge.join('chime', 'meeting-1');

  assert.ok(calls.includes('startAudioInput:mic-1'));
  assert.ok(calls.includes('bindRemoteAudio'));
  assert.ok(calls.includes('playRemoteAudio'));
  assert.ok(calls.includes('mute'));
  assert.ok(!calls.includes('startVideoInput:cam-1'));
  assert.ok(calls.includes('start'));
  assert.ok(!calls.includes('startLocalVideoTile'));

  await bridge.command(
    'chime',
    'meeting-1',
    'selectDevice',
    JSON.stringify({
      device: { id: 'mic-2', label: 'Mic 2', kind: 'microphone' },
    }),
  );
  await bridge.command(
    'chime',
    'meeting-1',
    'selectDevice',
    JSON.stringify({
      device: { id: 'cam-2', label: 'Camera 2', kind: 'camera' },
    }),
  );
  await bridge.command(
    'chime',
    'meeting-1',
    'selectAudioOutput',
    JSON.stringify({ id: 'speaker-2', label: 'Speaker 2', kind: 'audioOutput' }),
  );

  assert.ok(calls.includes('startAudioInput:mic-2'));
  assert.ok(calls.includes('startVideoInput:cam-2'));
  assert.ok(calls.includes('chooseAudioOutput:speaker-2'));

  await bridge.dispose('chime', 'meeting-1');
  assert.ok(calls.includes('unsubscribePresence'));
  assert.ok(calls.includes('unsubscribeData'));
  assert.ok(calls.includes('destroyDeviceController'));
  assert.ok(calls.includes('unbindRemoteAudio'));
  assert.ok(calls.includes('removeRemoteAudio'));
});

test('Chime Web does not claim an unmuted microphone when capture is blocked', async () => {
  const { bridge, audioVideo, events } = await createChimeHarness();
  audioVideo.listAudioInputDevices = async () => {
    throw new Error('Microphone permission denied');
  };
  await bridge.create('chime', 'blocked-mic', JSON.stringify(chimePayload));
  await bridge.join('chime', 'blocked-mic');
  assert.equal(events.filter(({ event }) => event.type === 'snapshot').at(-1).event.localMuted, true);
  await assert.rejects(
    bridge.command('chime', 'blocked-mic', 'setMuted', JSON.stringify({ muted: false })),
    /Microphone permission denied/,
  );
  await bridge.dispose('chime', 'blocked-mic');
});

test('Chime bridge rejects an unsuccessful signaling handshake instead of reporting connected', async () => {
  const { bridge, calls, audioVideo, stopChime, events } = await createChimeHarness();
  audioVideo.start = () => {
    calls.push('start');
    queueMicrotask(() => stopChime({ statusCode: () => 17 }));
  };
  await bridge.create('chime', 'handshake-failure', JSON.stringify(chimePayload));
  await assert.rejects(bridge.join('chime', 'handshake-failure'), /stopped before joining.*17/);
  assert.ok(calls.includes('start'));
  assert.ok(!events.some(({ event }) => event.type === 'state' && event.state === 'connected'));
  await bridge.dispose('chime', 'handshake-failure');
});

test('Chime meeting join remains available when WKWebView blocks device enumeration', async () => {
  const { bridge, calls, audioVideo } = await createChimeHarness();
  audioVideo.listAudioInputDevices = async () => {
    throw new Error('NotAllowedError: WebKit capture blocked');
  };
  audioVideo.listVideoInputDevices = async () => {
    throw new Error('NotFoundError: No camera');
  };
  await bridge.create('chime', 'meeting-no-devices', JSON.stringify(chimePayload));
  await bridge.join('chime', 'meeting-no-devices');
  assert.ok(calls.includes('start'), 'Chime signaling must start without device permission');
  assert.ok(!calls.some((call) => call.startsWith('startAudioInput:')));
  assert.ok(!calls.includes('listVideoInputs'), 'camera probing must not block joining');
  await bridge.dispose('chime', 'meeting-no-devices');
});

test('Chime meeting join remains available if microphone capture initialization fails', async () => {
  const { bridge, calls, audioVideo } = await createChimeHarness();
  audioVideo.startAudioInput = async () => {
    throw new Error('NotReadableError: device in use');
  };
  await bridge.create('chime', 'meeting-mic-busy', JSON.stringify(chimePayload));
  await bridge.join('chime', 'meeting-mic-busy');
  assert.ok(calls.includes('start'), 'capture failure must not block meeting signaling');
  await bridge.dispose('chime', 'meeting-mic-busy');
});

test('Chime bridge sends and receives normalized data messages', async () => {
  const { bridge, calls, events, getDataObserver } =
    await createChimeHarness();
  await bridge.create('chime', 'meeting-2', JSON.stringify(chimePayload));
  await bridge.join('chime', 'meeting-2');
  await bridge.command(
    'chime',
    'meeting-2',
    'sendMessage',
    JSON.stringify({ topic: 'chat', message: 'hello', lifetimeMs: 300000 }),
  );
  assert.ok(calls.includes('message:chat:hello:300000'));

  const dataObserver = getDataObserver();
  assert.equal(typeof dataObserver, 'function');
  dataObserver({
    senderAttendeeId: 'attendee-2',
    senderExternalUserId: 'Grace',
    topic: 'chat',
    timestampMs: 1234,
    throttled: false,
    text: () => 'incoming',
  });
  const messageEvent = events.find(({ event }) => event.type === 'message');
  assert.deepEqual(messageEvent, {
    sessionId: 'meeting-2',
    event: {
      type: 'message',
      participantId: 'attendee-2',
      displayName: 'Grace',
      message: 'incoming',
      topic: 'chat',
      timestampMs: 1234,
      throttled: false,
    },
  });

  await bridge.dispose('chime', 'meeting-2');
});

async function createIvsHarness() {
  const calls = [];
  const events = [];
  let stage;
  let mediaSequence = 0;

  function track(kind, id) {
    return {
      kind,
      id,
      stop: () => calls.push(`stop:${id}`),
      addEventListener: () => {},
    };
  }

  class LocalStageStream {
    constructor(mediaStreamTrack) {
      this.mediaStreamTrack = mediaStreamTrack;
      this.id = mediaStreamTrack.id;
      this.streamType = mediaStreamTrack.kind === 'video' ? 'video' : 'audio';
    }

    setMuted(muted) {
      calls.push(`mute:${this.mediaStreamTrack.id}:${muted}`);
    }

    async requestQualityStats() {
      return [{ packetsLost: 1, packetsSent: 100 }];
    }
  }

  class Stage {
    constructor(token, strategy) {
      this.token = token;
      this.strategy = strategy;
      this.handlers = new Map();
      stage = this;
    }

    on(name, handler) {
      this.handlers.set(name, handler);
    }

    async join() {
      calls.push('stage.join');
    }

    leave() {
      calls.push('stage.leave');
    }

    refreshStrategy() {
      calls.push('stage.refreshStrategy');
    }

    removeAllListeners() {
      calls.push('stage.removeAllListeners');
    }
  }

  const mediaDevices = {
    async getUserMedia(constraints) {
      mediaSequence += 1;
      calls.push(`getUserMedia:${JSON.stringify(constraints)}`);
      if (constraints.audio === true && constraints.video === true) {
        const tracks = [
          track('audio', `audio-${mediaSequence}`),
          track('video', `video-${mediaSequence}`),
        ];
        return {
          getTracks: () => tracks,
          getVideoTracks: () => tracks.filter((item) => item.kind === 'video'),
        };
      }
      const kind = constraints.video ? 'video' : 'audio';
      const selected = track(kind, `${kind}-${mediaSequence}`);
      return {
        getTracks: () => [selected],
        getVideoTracks: () => kind === 'video' ? [selected] : [],
      };
    },
    async enumerateDevices() {
      return [];
    },
    async getDisplayMedia() {
      calls.push('getDisplayMedia');
      const video = track('video', 'screen-1');
      return {
        getVideoTracks: () => [video],
        getTracks: () => [video],
      };
    },
  };

  const context = vm.createContext({
    console,
    setInterval: () => 1,
    clearInterval: () => {},
    navigator: { mediaDevices },
    document: {
      createElement: () => ({
        remove: () => {},
        play: () => Promise.resolve(),
      }),
      body: { append: () => {} },
    },
    MediaStream: class {
      constructor(tracks) {
        this.tracks = tracks;
      }
    },
    __flutterMediaProviderOnEvent: (sessionId, serializedEvent) => {
      events.push({ sessionId, event: JSON.parse(serializedEvent) });
    },
    IVSBroadcastClient: {
      Stage,
      LocalStageStream,
      StageConnectionState: {
        CONNECTED: 'connected',
        CONNECTING: 'connecting',
        DISCONNECTED: 'disconnected',
      },
      SubscribeType: { AUDIO_VIDEO: 'audio-video', NONE: 'none' },
      StreamType: { VIDEO: 'video', AUDIO: 'audio' },
    },
  });
  const source = (await build({ entryPoints: [new URL('./bridge.js', import.meta.url).pathname], bundle: true, write: false, format: 'iife', platform: 'browser' })).outputFiles[0].text;
  const effectsSource = await readFile(new URL('../../../packages/flutter_realtime_video_effects/web/video-effects-bridge.js', import.meta.url), 'utf8');
  vm.runInContext(effectsSource, context, {filename: 'video-effects-bridge.js'});
  vm.runInContext(source, context, { filename: 'bridge.js' });
  return {
    bridge: context.MediaProviderBridge,
    calls,
    events,
    getStage: () => stage,
  };
}

test('IVS bridge publishes only with publisher credentials and refreshes strategy', async () => {
  const { bridge, calls, getStage } = await createIvsHarness();
  const payload = {
    participantId: 'host-1',
    displayName: 'Host',
    role: 'host',
    ivs: {
      token: 'publisher-token',
      capabilities: ['PUBLISH', 'SUBSCRIBE'],
    },
  };

  await bridge.create('ivs', 'stage-1', JSON.stringify(payload));
  const stage = getStage();
  assert.equal(stage.strategy.shouldPublishParticipant(), true);
  assert.equal(
    stage.strategy.shouldSubscribeToParticipant({
      capabilities: new Set(['subscribe']),
    }),
    'audio-video',
  );

  await bridge.join('ivs', 'stage-1');
  assert.ok(calls.some((call) => call.startsWith('getUserMedia:')));
  assert.ok(calls.includes('stage.join'));
  assert.ok(calls.some((call) => call.startsWith('mute:audio-') && call.endsWith(':true')),
    'IVS joins with muted microphone, matching the iOS adapter');

  await bridge.command(
    'ivs',
    'stage-1',
    'setMuted',
    JSON.stringify({ muted: false }),
  );
  assert.ok(calls.some((call) => call.startsWith('mute:audio-') && call.endsWith(':false')));

  await bridge.command(
    'ivs',
    'stage-1',
    'setMuted',
    JSON.stringify({ muted: true }),
  );
  assert.ok(calls.some((call) => call.startsWith('mute:audio-') && call.endsWith(':true')));

  await bridge.command(
    'ivs',
    'stage-1',
    'selectDevice',
    JSON.stringify({
      device: { id: 'camera-2', kind: 'camera', label: 'Camera 2' },
    }),
  );
  assert.ok(calls.includes('stage.refreshStrategy'));

  await bridge.dispose('ivs', 'stage-1');
  assert.ok(calls.includes('stage.leave'));
  assert.ok(calls.includes('stage.removeAllListeners'));
});

test('IVS viewer never requests local media or publishes', async () => {
  const { bridge, calls, getStage } = await createIvsHarness();
  const payload = {
    participantId: 'viewer-1',
    displayName: 'Viewer',
    role: 'viewer',
    ivs: {
      token: 'viewer-token',
      capabilities: ['SUBSCRIBE'],
    },
  };

  await bridge.create('ivs', 'stage-viewer', JSON.stringify(payload));
  assert.equal(getStage().strategy.shouldPublishParticipant(), false);
  await bridge.join('ivs', 'stage-viewer');
  await assert.rejects(
    bridge.command('ivs', 'stage-viewer', 'setScreenShareEnabled', JSON.stringify({enabled: true})),
    /Viewers cannot publish/,
  );
  assert.equal(calls.some((call) => call.startsWith('getUserMedia:')), false);
  assert.ok(calls.includes('stage.join'));
  await bridge.dispose('ivs', 'stage-viewer');
});

test('IVS browser sharing reports the track, ignores duplicate starts and releases on stop', async () => {
  const {bridge, calls, events, getStage} = await createIvsHarness();
  const payload = {
    participantId: 'host-screen', role: 'host',
    ivs: {token: 'publisher-token', capabilities: ['PUBLISH', 'SUBSCRIBE']},
  };
  await bridge.create('ivs', 'stage-screen', JSON.stringify(payload));
  await bridge.join('ivs', 'stage-screen');
  await bridge.command('ivs', 'stage-screen', 'selectDevice', JSON.stringify({
    device: {kind: 'camera', id: 'cam-1'},
  }));
  const publishedVideos = () => getStage().strategy.stageStreamsToPublish()
    .filter(stream => stream.streamType === 'video');
  assert.equal(publishedVideos().length, 1);
  const oldCameraId = publishedVideos()[0].id;
  const command = (enabled) => bridge.command(
    'ivs', 'stage-screen', 'setScreenShareEnabled', JSON.stringify({enabled}),
  );
  await command(true);
  assert.equal(publishedVideos().length, 1);
  assert.equal(publishedVideos()[0].id, 'screen-1');
  await bridge.command('ivs', 'stage-screen', 'selectDevice', JSON.stringify({
    device: {kind: 'camera', id: 'cam-2'},
  }));
  assert.equal(publishedVideos().length, 1);
  assert.equal(publishedVideos()[0].id, 'screen-1');
  await command(true);
  assert.equal(publishedVideos().length, 1);
  assert.equal(publishedVideos()[0].id, 'screen-1');
  assert.equal(calls.filter(c => c === 'getDisplayMedia').length, 1);
  assert.ok(events.some(({event}) =>
    event.type === 'snapshot' && event.tracks?.some(t => t.isScreenShare && t.isLocal)));
  await command(false);
  assert.ok(calls.includes('stop:screen-1'));
  assert.equal(publishedVideos().length, 1);
  assert.notEqual(publishedVideos()[0].id, oldCameraId);
  const finalSnapshot = events.filter(({event}) => event.type === 'snapshot').at(-1)?.event;
  assert.ok(finalSnapshot);
  assert.ok(finalSnapshot.tracks.every(t => !t.isScreenShare));
  await bridge.dispose('ivs', 'stage-screen');
});

test('IVS leaving while sharing releases both screen and paused camera', async () => {
  const {bridge, calls, getStage} = await createIvsHarness();
  await bridge.create('ivs', 'stage-share-dispose', JSON.stringify({
    participantId: 'host', role: 'host',
    ivs: {token: 'publisher-token', capabilities: ['PUBLISH', 'SUBSCRIBE']},
  }));
  await bridge.join('ivs', 'stage-share-dispose');
  await bridge.command('ivs', 'stage-share-dispose', 'selectDevice', JSON.stringify({
    device: {kind: 'camera', id: 'cam-a'},
  }));
  const camera = getStage().strategy.stageStreamsToPublish()
    .find(stream => stream.streamType === 'video');
  await bridge.command('ivs', 'stage-share-dispose', 'setScreenShareEnabled', JSON.stringify({enabled: true}));
  await bridge.dispose('ivs', 'stage-share-dispose');
  assert.ok(calls.includes(`stop:${camera.id}`));
  assert.ok(calls.includes('stop:screen-1'));
});

async function createAgoraHarness() {
  const calls = [];
  const events = [];
  let mediaSequence = 0;

  function mediaTrack(kind, id) {
    return {
      kind,
      id,
      enabled: true,
      clone() { const copy = mediaTrack(kind, id); copy.origin = this.origin || this; copy.isClone = true; copy.enabled = this.enabled; return copy; },
      stop() {
        calls.push(`stop:${id}${this.isClone ? ':clone' : ''}`);
      },
      getSettings() {
        return kind === 'video' ? { width: 1280, height: 720 } : {};
      },
    };
  }

  const mediaDevices = {
    async getUserMedia(constraints) {
      mediaSequence += 1;
      calls.push(`getUserMedia:${JSON.stringify(constraints)}`);
      const track = mediaTrack(constraints.video ? 'video' : 'audio', `camera-${mediaSequence}`);
      return {
        getTracks: () => [track],
        getVideoTracks: () => track.kind === 'video' ? [track] : [],
      };
    },
    async enumerateDevices() {
      return [
        { deviceId: 'cam-1', label: 'Camera 1', groupId: 'g1', kind: 'videoinput' },
        { deviceId: 'cam-2', label: 'Camera 2', groupId: 'g2', kind: 'videoinput' },
      ];
    },
  };

  const canvasTrack = mediaTrack('video', 'sdk-processed-video');
  canvasTrack.requestFrame = () => {};
  const canvasContext = {
    save() {},
    restore() {},
    clearRect() {},
    drawImage() {},
    fillRect() {},
    putImageData() {},
    set filter(_) {},
    set globalCompositeOperation(_) {},
  };
  const createCanvas = () => ({
    width: 0,
    height: 0,
    getContext: () => canvasContext,
    captureStream: () => ({
      getVideoTracks: () => [canvasTrack],
      getTracks: () => [canvasTrack],
    }),
  });
  const createVideo = () => ({
    autoplay: false,
    muted: false,
    playsInline: false,
    readyState: 2,
    videoWidth: 1280,
    videoHeight: 720,
    srcObject: null,
    async play() {},
    requestVideoFrameCallback() {
      return 1;
    },
    cancelVideoFrameCallback() {},
  });

  const client = {
    remoteUsers: [],
    handlers: new Map(),
    on(name, handler) {
      this.handlers.set(name, handler);
    },
    async setClientRole(role) {
      calls.push(`role:${role}`);
    },
    async join(appId, channelName, token, uid) {
      calls.push(`join:${appId}:${channelName}:${token}:${uid}`);
    },
    async publish(track) {
      const tracks = Array.isArray(track) ? track : [track];
      for (const item of tracks) calls.push(`publish:${item.id}`);
    },
    async unpublish(track) {
      calls.push(`unpublish:${track.id}`);
    },
    async subscribe() {},
    async leave() {
      calls.push('client.leave');
    },
    removeAllListeners() {},
    getRTCStats() {
      return {};
    },
  };

  const audioTrack = {
    id: 'agora-audio',
    play() {},
    async setEnabled(enabled) {
      calls.push(`audio-enabled:${enabled}`);
    },
    close() {},
  };
  const customVideoTrack = {
    id: 'agora-custom-video',
    play(element) {calls.push(['video.play', element]);},
    stop() {},
    close() {
      calls.push('custom-video.close');
    },
  };
  const imageSegmenter = {
    segmentForVideo() {
      return { confidenceMasks: [], close() {} };
    },
    close() {
      calls.push('segmenter.close');
    },
  };

  const context = vm.createContext({
    console,
    URL,
    TextDecoder,
    performance: { now: () => 1 },
    navigator: { mediaDevices },
    requestAnimationFrame: () => 1,
    cancelAnimationFrame: () => {},
    document: {
      baseURI: 'https://example.test/',
      createElement(tag) {
        if (tag === 'audio') {
          return {autoplay: false, playsInline: false, style: {}, play: async () => {}, remove() {}};
        }
        return tag === 'video' ? createVideo() : createCanvas();
      },
      body: {append() {}},
      getElementById: () => null,
    },
    ImageData: class {
      constructor(data, width, height) {
        this.data = data;
        this.width = width;
        this.height = height;
      }
    },
    MediaStream: class {
      constructor(tracks) {
        this.tracks = tracks;
      }
    },
    SdkVideoEffectsVision: {
      FaceDetector: {async createFromOptions(){return {detectForVideo(){return {detections:[]};},close(){}};}},
      FilesetResolver: {
        async forVisionTasks(path) {
          calls.push(`vision.fileset:${path}`);
          return { path };
        },
      },
      ImageSegmenter: {
        async createFromOptions(_fileset, options) {
          calls.push(`segmenter.create:${options.runningMode}`);
          return imageSegmenter;
        },
      },
    },
    AgoraRTC: {
      createClient() {
        return client;
      },
      async createCameraVideoTrack(options) {
        calls.push(`createCameraVideoTrack:${JSON.stringify(options)}`);
        return {...customVideoTrack, async setDevice(id){calls.push(`camera.setDevice:${id}`);}};
      },
      async createMicrophoneAudioTrack() {
        calls.push('createMicrophoneAudioTrack');
        return audioTrack;
      },
      createCustomVideoTrack({ mediaStreamTrack }) {
        calls.push(`createCustomVideoTrack:${mediaStreamTrack.id}`);
        context.supplierInputs?.push({provider: 'agora', track: mediaStreamTrack});
        return customVideoTrack;
      },
      async createScreenVideoTrack() {
        throw new Error('screen share not expected');
      },
      async getCameras() {
        return [
          { deviceId: 'cam-1', label: 'Camera 1' },
          { deviceId: 'cam-2', label: 'Camera 2' },
        ];
      },
    },
    setInterval: () => 1,
    clearInterval: () => {},
    __flutterMediaProviderOnEvent: (sessionId, serializedEvent) => {
      events.push({ sessionId, event: JSON.parse(serializedEvent) });
    },
  });
  const source = (await build({ entryPoints: [new URL('./bridge.js', import.meta.url).pathname], bundle: true, write: false, format: 'iife', platform: 'browser' })).outputFiles[0].text;
  const effectsSource = await readFile(new URL('../../../packages/flutter_realtime_video_effects/web/video-effects-bridge.js', import.meta.url), 'utf8');
  vm.runInContext(effectsSource, context, {filename: 'video-effects-bridge.js'});
  vm.runInContext(source, context, { filename: 'bridge.js' });
  return {
    bridge: context.MediaProviderBridge,
    effectsBridge: context.RealtimeVideoEffectsBridge,
    context,
    calls,
    events,
  };
}

const agoraPayload = {
  participantId: '42',
  displayName: 'Ada',
  role: 'participant',
  agora: {
    appId: 'app-id',
    channelName: 'channel-a',
    token: 'token',
    uid: 42,
  },
};

test('Agora Web defers camera publication until SDK effects are configured', async () => {
  const { bridge, calls } = await createAgoraHarness();

  await bridge.create('agora', 'agora-1', JSON.stringify(agoraPayload));
  await bridge.join('agora', 'agora-1');

  assert.equal(calls.includes('createMicrophoneAudioTrack'), false);
  assert.equal(calls.includes('publish:agora-audio'), false);
  assert.equal(
    calls.some((call) => call.startsWith('getUserMedia:')),
    false,
  );
  assert.equal(
    calls.some((call) => call.startsWith('createCustomVideoTrack:')),
    false,
  );

  await bridge.command('agora', 'agora-1', 'setMuted', JSON.stringify({muted: false}));
  assert.ok(calls.includes('createMicrophoneAudioTrack'));
  assert.ok(calls.includes('publish:agora-audio'));
  await bridge.command('agora', 'agora-1', 'setMuted', JSON.stringify({muted: true}));
  assert.ok(calls.includes('audio-enabled:false'));

  await bridge.command(
    'agora',
    'agora-1',
    'setBackgroundEffect',
    JSON.stringify({ type: 'blur', blurStrength: 'medium' }),
  );
  assert.equal(
    calls.some((call) => call.startsWith('getUserMedia:')),
    false,
  );

  await bridge.command(
    'agora',
    'agora-1',
    'setVideoEnabled',
    JSON.stringify({ enabled: true }),
  );

  assert.ok(
    calls.some((call) => call.startsWith('vision.fileset:')),
  );
  assert.ok(calls.includes('segmenter.create:VIDEO'));
  assert.ok(calls.includes('createCustomVideoTrack:sdk-processed-video'));
  assert.ok(calls.includes('publish:agora-custom-video'));

  await bridge.dispose('agora', 'agora-1');
});

test('Agora Web without effects selects the native camera without a canvas pipeline', async () => {
  const { bridge, calls } = await createAgoraHarness();

  await bridge.create('agora', 'agora-2', JSON.stringify(agoraPayload));
  await bridge.join('agora', 'agora-2');
  await bridge.command(
    'agora',
    'agora-2',
    'setVideoEnabled',
    JSON.stringify({ enabled: true }),
  );
  await bridge.command(
    'agora',
    'agora-2',
    'selectDevice',
    JSON.stringify({
      device: { id: 'cam-2', label: 'Camera 2', kind: 'camera' },
    }),
  );

  assert.ok(calls.includes('camera.setDevice:cam-2'));
  assert.ok(calls.some(call=>call.startsWith('createCameraVideoTrack:')));
  assert.equal(calls.some(call=>call.startsWith('createCustomVideoTrack:')), false);
  assert.equal(calls.some(call=>call.startsWith('vision.fileset:')), false);

  await bridge.dispose('agora', 'agora-2');
});

test('Agora screen-picker cancellation does not unpublish the existing camera', async () => {
  const {bridge, context, calls} = await createAgoraHarness();
  await bridge.create('agora', 'agora-cancel-screen', JSON.stringify(agoraPayload));
  await bridge.join('agora', 'agora-cancel-screen');
  await bridge.command('agora', 'agora-cancel-screen', 'setVideoEnabled', JSON.stringify({enabled: true}));
  const priorUnpublish = calls.filter(c => c.startsWith('unpublish:')).length;
  context.AgoraRTC.createScreenVideoTrack = async () => {
    throw new Error('The user cancelled choosing a screen.');
  };
  await assert.rejects(bridge.command(
    'agora', 'agora-cancel-screen', 'setScreenShareEnabled', JSON.stringify({enabled: true}),
  ), /cancelled/);
  assert.equal(calls.filter(c => c.startsWith('unpublish:')).length, priorUnpublish);
  await bridge.dispose('agora', 'agora-cancel-screen');
});

test('Agora screen share switches camera video back on after stop', async () => {
  const {bridge, context, calls, events} = await createAgoraHarness();
  await bridge.create('agora', 'agora-screen', JSON.stringify(agoraPayload));
  await bridge.join('agora', 'agora-screen');
  await bridge.command('agora', 'agora-screen', 'setVideoEnabled', JSON.stringify({enabled: true}));
  const hooks = new Map();
  context.AgoraRTC.createScreenVideoTrack = async () => ({
    id: 'test-screen', close() {calls.push('screen.close');},
    on(name, handler) {hooks.set(name, handler);},
  });
  await bridge.command('agora', 'agora-screen', 'setScreenShareEnabled', JSON.stringify({enabled: true}));
  assert.ok(calls.includes('publish:test-screen'));
  assert.ok(events.some(({event}) => event.type === 'snapshot' &&
    event.tracks?.some(t => t.isScreenShare && t.isLocal)));
  assert.equal(typeof hooks.get('track-ended'), 'function');
  await bridge.command('agora', 'agora-screen', 'setScreenShareEnabled', JSON.stringify({enabled: false}));
  assert.ok(calls.includes('screen.close'));
  assert.ok(calls.includes('unpublish:test-screen'));
  assert.equal(calls.filter(c => c === 'publish:agora-custom-video').length, 2);
  await bridge.dispose('agora', 'agora-screen');
});

test('Agora Web recognizes native screen-share state without leaking it into chat', async () => {
  const {bridge, context, events} = await createAgoraHarness();
  await bridge.create('agora', 'agora-remote-screen', JSON.stringify(agoraPayload));
  await bridge.join('agora', 'agora-remote-screen');
  const client = context.AgoraRTC.createClient();
  const remote = {uid: 889, videoTrack: {play() {}, stop() {}}};
  client.remoteUsers.push(remote);
  await client.handlers.get('user-published')(remote, 'video');
  await Promise.resolve();

  const snapshot = () => events.filter(({event}) => event.type === 'snapshot').at(-1)?.event;
  assert.ok(snapshot().tracks.some(t => t.id === 'agora:video:889' && !t.isScreenShare));
  const signal = (state) => client.handlers.get('stream-message')(
    889, new TextEncoder().encode(JSON.stringify({
      topic: '_flutter_realtime.screen_share.v1', message: state,
    })),
  );
  signal('started');
  await Promise.resolve();
  await Promise.resolve();
  assert.ok(snapshot().tracks.some(t => t.id === 'agora:screen:889' && t.isScreenShare));
  assert.equal(snapshot().tracks.some(t => t.id === 'agora:video:889'), false);
  assert.equal(events.filter(({event}) => event.type === 'message').length, 0);

  signal('stopped');
  await Promise.resolve();
  await Promise.resolve();
  assert.ok(snapshot().tracks.some(t => t.id === 'agora:video:889' && !t.isScreenShare));
  assert.equal(snapshot().tracks.some(t => t.id === 'agora:screen:889'), false);
  client.handlers.get('user-unpublished')(remote, 'video');
  assert.equal(snapshot().tracks.some(t => t.participantId === '889'), false);
  await bridge.dispose('agora', 'agora-remote-screen');
});

test('Pre-Join bridge creates no capture until camera is explicitly enabled', async () => {
  const { bridge, calls } = await createAgoraHarness();
  await bridge.createLocalPreview('agora', 'prejoin-off', JSON.stringify({ role: 'participant' }));
  await bridge.command('agora', 'prejoin-off', 'setBackgroundEffect', JSON.stringify({ type: 'blur' }));
  await bridge.command('agora', 'prejoin-off', 'selectDevice', JSON.stringify({ kind: 'camera', id: 'camera-two' }));
  assert.equal(calls.some(call => call.startsWith('getUserMedia:')), false);
  await bridge.command('agora', 'prejoin-off', 'setVideoEnabled', JSON.stringify({ enabled: true }));
  assert.equal(calls.filter(call => call.startsWith('getUserMedia:')).length, 1);
  assert.equal(calls.some(call => call.startsWith('join:') || call.startsWith('publish:')), false);
  await bridge.dispose('agora', 'prejoin-off');
  assert.ok(calls.includes('stop:sdk-processed-video'));
});

test('canceling an untouched Pre-Join bridge never opens camera or microphone', async () => {
  const { bridge, calls } = await createAgoraHarness();
  await bridge.createLocalPreview('agora', 'prejoin-cancel', JSON.stringify({ role: 'participant' }));
  await bridge.dispose('agora', 'prejoin-cancel');
  assert.equal(calls.some(call => call.startsWith('getUserMedia:')), false);
});

test('SDK local preview applies blur without joining or publishing to Agora', async () => {
  const { effectsBridge, calls } = await createAgoraHarness();

  await effectsBridge.createSource(
    'preview-1',
    JSON.stringify({
      effect: { type: 'none', blurStrength: 'medium' },
    }),
  );

  assert.ok(calls.some((call) => call.startsWith('getUserMedia:')));
  assert.equal(calls.some((call) => call.startsWith('join:')), false);
  assert.equal(calls.some((call) => call.startsWith('publish:')), false);

  await effectsBridge.setEffect(
    'preview-1',
    JSON.stringify({ type: 'blur', blurStrength: 'medium' }),
  );

  assert.ok(calls.includes('segmenter.create:VIDEO'));
  assert.equal(
    calls.some((call) => call.startsWith('createCustomVideoTrack:')),
    false,
  );

  effectsBridge.disposeSource('preview-1');
  assert.ok(calls.includes('stop:sdk-processed-video'));
});

test('Agora Web publishes an attached SDK processed source without recapturing camera', async () => {
  const { bridge, effectsBridge, calls } = await createAgoraHarness();

  await effectsBridge.createSource(
    'effects-source-1',
    JSON.stringify({
      effect: { type: 'blur', blurStrength: 'medium' },
    }),
  );
  const captureCallsAfterEffectsSource = calls.filter((call) =>
    call.startsWith('getUserMedia:')
  ).length;

  await bridge.create('agora', 'agora-sink-1', JSON.stringify(agoraPayload));
  await bridge.join('agora', 'agora-sink-1');
  await bridge.command(
    'agora',
    'agora-sink-1',
    'attachProcessedVideoSource',
    JSON.stringify({ sourceId: 'effects-source-1' }),
  );
  await bridge.command(
    'agora',
    'agora-sink-1',
    'setVideoEnabled',
    JSON.stringify({ enabled: true }),
  );

  assert.equal(
    calls.filter((call) => call.startsWith('getUserMedia:')).length,
    captureCallsAfterEffectsSource,
  );
  assert.ok(calls.includes('createCustomVideoTrack:sdk-processed-video'));
  assert.ok(calls.includes('publish:agora-custom-video'));

  await bridge.dispose('agora', 'agora-sink-1');
  effectsBridge.disposeSource('effects-source-1');
});


test('all five Web suppliers consume clones of one processed source and camera switching never recaptures in suppliers', async () => {
  const h = await createAgoraHarness();
  h.context.setTimeout = setTimeout;
  h.context.clearTimeout = clearTimeout;
  const inputs = [];
  const audioActions = [];
  h.context.supplierInputs = inputs;
  const receive = (provider, track) => { if (track) inputs.push({provider,track}); };
  const trtc = {
    on(){}, async enterRoom(){}, async startLocalAudio(){}, async stopLocalVideo(){},
    async updateLocalAudio({mute}){ audioActions.push(`trtc:${mute}`); },
    async startLocalVideo({option}){assert.ok(option.videoTrack); receive('trtc', option.videoTrack);},
    getVideoTrack(){return inputs.find(i=>i.provider==='trtc')?.track;},
    async updateLocalVideo({option}){assert.ok(option.videoTrack);receive('trtc',option.videoTrack);},
    async exitRoom(){}, destroy(){},
  };
  h.context.TRTC = {create:()=>trtc, TYPE:{SCENE_RTC:'rtc'}};
  const artc = {
    publisher:{streamManager:{cameraCaptureDisabled:true}}, on(){}, setChannelProfile(){},
    async enableLocalVideo(enabled){assert.equal(enabled,false,'ARTC must never open its own raw camera'); this.publisher.streamManager.cameraCaptureDisabled=true;},
    async publishLocalVideoStream(){}, async publishLocalAudioStream(enabled){audioActions.push(`artc:${enabled}`);return 0;}, async joinChannel(){}, async muteLocalCamera(){},
    async muteLocalMic(){},
    async switchCamera(deviceId, track){assert.equal(deviceId,undefined); assert.equal(this.publisher.streamManager.cameraCaptureDisabled,false);receive('artc',track);},
    async leaveChannel(){}, async destroy(){},
  };
  h.context.AliRtcEngine = {createInstance:()=>artc, AliRtcSdkChannelProfile:{AliRtcSdkCommunication:'rtc'},
    AliRtcSdkClientRole:{}, AliRtcVideoTrack:{AliRtcVideoTrackCamera:0,AliRtcVideoTrackScreen:1}, AliRtcConnectionStatus:{}};
  h.context.IVSBroadcastClient = {
    Stage:class {constructor(_token,strategy){this.strategy=strategy;} on(){} async join(){} refreshStrategy(){} leave(){} removeAllListeners(){}},
    LocalStageStream:class {constructor(track){this.mediaStreamTrack=track;this.id=track.id;if(track.kind==='video')receive('ivs',track);}setMuted(){}},
    StageConnectionState:{},StreamType:{AUDIO:'audio',VIDEO:'video'},SubscribeType:{NONE:0,AUDIO_VIDEO:1},
  };
  const audioVideo = {addObserver(observer){this.observer=observer;},removeObserver(){}, realtimeSubscribeToAttendeeIdPresence(){},realtimeUnsubscribeToAttendeeIdPresence(){},
    bindAudioElement(){},unbindAudioElement(){},realtimeMuteLocalAudio(){},
    realtimeSubscribeToReceiveDataMessage(){},realtimeUnsubscribeFromReceiveDataMessage(){},
    async listAudioInputDevices(){return [];},async listVideoInputDevices(){return [];},
    async startVideoInput(stream){assert.ok(stream.tracks);receive('chime',stream.tracks[0]);},async stopVideoInput(){},
    start(){this.observer?.audioVideoDidStart?.();},stop(){},startLocalVideoTile(){},stopLocalVideoTile(){},getAllVideoTiles(){return [];}};
  h.context.ChimeSDK = {ConsoleLogger:class {},LogLevel:{WARN:1},MeetingSessionConfiguration:class {},
    DefaultDeviceController:class {async destroy(){}}, DefaultMeetingSession:class {constructor(){this.audioVideo=audioVideo;}},MeetingSessionStatusCode:{Left:0}};
  await h.effectsBridge.createSource('shared-output', {effect:{type:'blur'}});
  const output = h.effectsBridge.getTrack('shared-output');
  for (const provider of ['agora','trtc','artc','ivs','chime']) {
    const payload = {participantId:'publisher',displayName:'Publisher',role:'participant',
      agora:agoraPayload.agora,trtc:{sdkAppId:1,strRoomId:'room',userId:'publisher',userSig:'test'},
      artc:{authInfo:'test',userId:'publisher'},ivs:{token:'test',capabilities:['PUBLISH','SUBSCRIBE']},
      meeting:chimePayload.meeting,attendee:chimePayload.attendee};
    await h.bridge.create(provider,provider,payload);await h.bridge.join(provider,provider);
    if (provider === 'trtc' || provider === 'artc') {
      assert.ok(audioActions.includes(`${provider}:${provider === 'trtc'}`),
        `${provider} must join muted like its native iOS adapter`);
      await h.bridge.command(provider,provider,'setMuted',{muted:false});
      assert.ok(audioActions.includes(`${provider}:${provider !== 'trtc'}`),
        `${provider} must actually enable audio publication on unmute`);
    }
    await h.bridge.command(provider,provider,'attachProcessedVideoSource',{sourceId:'shared-output'});
    await h.bridge.command(provider,provider,'setVideoEnabled',{enabled:true});
    const input = inputs.find(i=>i.provider===provider)?.track;
    assert.ok(input,`${provider} received input`);assert.notEqual(input,output);assert.equal(input.origin,output);
    await h.bridge.command(provider,provider,'selectDevice',{device:{id:'cam-2',kind:'camera'}});
    await h.bridge.command(provider,provider,'detachProcessedVideoSource',{});
    await h.bridge.dispose(provider,provider);
  }
  // One initial camera plus the five SDK-controlled selections; IVS requests audio only.
  const captures=h.calls.filter(c=>typeof c==='string' && c.startsWith('getUserMedia:')).map(c=>JSON.parse(c.slice('getUserMedia:'.length)));
  assert.equal(captures.filter(c=>c.video).length,6);
  assert.equal(h.calls.includes('stop:sdk-processed-video'),false,'disposing suppliers must preserve the source');
  h.effectsBridge.disposeSource('shared-output');assert.ok(h.calls.includes('stop:sdk-processed-video'));
});


test('Agora enables an independently disabled clone when publishing and republishing', async () => {
  const h=await createAgoraHarness();
  h.context.supplierInputs=[];
  await h.effectsBridge.createSource('disabled-source',{effect:{type:'blur'}});
  await h.effectsBridge.setEnabled('disabled-source',false);
  await h.bridge.create('agora','clone',agoraPayload);
  await h.bridge.join('agora','clone');
  await h.bridge.command('agora','clone','attachProcessedVideoSource',{sourceId:'disabled-source'});
  await h.bridge.command('agora','clone','setVideoEnabled',{enabled:true});
  const input=h.context.supplierInputs[0].track;
  assert.equal(input.enabled,true);
  await h.bridge.command('agora','clone','setVideoEnabled',{enabled:false});
  assert.equal(input.enabled,false);
  await h.bridge.command('agora','clone','setVideoEnabled',{enabled:true});
  assert.equal(input.enabled,true);
  await h.bridge.dispose('agora','clone');
  h.effectsBridge.disposeSource('disabled-source');
});

test('Agora camera toggles recreate a closed native track without loading effects', async () => {
  const h=await createAgoraHarness();
  await h.bridge.create('agora','camera-toggle',agoraPayload);
  await h.bridge.join('agora','camera-toggle');
  for(const enabled of [true,false,true]) await h.bridge.command('agora','camera-toggle','setVideoEnabled',{enabled});
  assert.equal(h.calls.filter(call=>call.startsWith('createCameraVideoTrack:')).length,2);
  assert.equal(h.calls.some(call=>call.startsWith('vision.fileset:')),false);
  await h.bridge.dispose('agora','camera-toggle');
});

test('Agora releases the native camera after failed publication and permits retry', async () => {
  const h=await createAgoraHarness();
  await h.bridge.create('agora','camera-failure',agoraPayload);
  await h.bridge.join('agora','camera-failure');
  const client=h.context.AgoraRTC.createClient();
  const publish=client.publish;
  client.publish=async()=>{throw new Error('publish rejected');};
  await assert.rejects(h.bridge.command('agora','camera-failure','setVideoEnabled',{enabled:true}),/publish rejected/);
  assert.ok(h.calls.includes('custom-video.close'));
  client.publish=publish;
  await h.bridge.command('agora','camera-failure','setVideoEnabled',{enabled:true});
  assert.equal(h.calls.filter(call=>call.startsWith('createCameraVideoTrack:')).length,2);
  await h.bridge.dispose('agora','camera-failure');
});


test('Agora renders into a detached element without looking it up by id', async () => {
  const h=await createAgoraHarness();
  await h.bridge.create('agora','detached-render',agoraPayload);
  await h.bridge.join('agora','detached-render');
  await h.bridge.command('agora','detached-render','setVideoEnabled',{enabled:true});
  const element={id:'detached',replaceChildren(){}};
  await h.bridge.attachVideoElement('agora','detached-render',`agora:video:${agoraPayload.participantId}`,element);
  assert.equal(h.calls.find(call=>Array.isArray(call)&&call[0]==='video.play')?.[1],element);
  await h.bridge.dispose('agora','detached-render');
});

test('disposing a pending Agora join invalidates late connection and permits a new session with the same id', async () => {
  const h=await createAgoraHarness();
  assert.equal(h.bridge.bridgeVersion,1);
  const client=h.context.AgoraRTC.createClient();
  let finish;
  client.join=()=>new Promise(resolve=>{finish=resolve;});
  await h.bridge.create('agora','pending',agoraPayload);
  const joining=h.bridge.join('agora','pending');
  const failure=assert.rejects(joining,/cancelled/);
  await h.bridge.dispose('agora','pending');
  assert.ok(h.calls.includes('client.leave'));
  client.join=async()=>{};
  await h.bridge.create('agora','pending',agoraPayload);
  await h.bridge.join('agora','pending');
  finish();await failure;
  assert.equal(h.events.filter(({event})=>event.type==='state'&&event.state==='connected').length,1);
  await h.bridge.command('agora','pending','setMuted',{muted:true});
  await h.bridge.dispose('agora','pending');
});

test('legacy string attachment remains compatible with the element-based bridge', async () => {
  const h=await createAgoraHarness();
  await h.bridge.create('agora','legacy',agoraPayload);
  await h.bridge.join('agora','legacy');
  await h.bridge.command('agora','legacy','setVideoEnabled',{enabled:true});
  const element={id:'legacy-view',replaceChildren(){}};
  h.context.document.getElementById=id=>id===element.id?element:null;
  await h.bridge.attachVideo('agora','legacy',`agora:video:${agoraPayload.participantId}`,element.id);
  assert.equal(h.calls.find(call=>Array.isArray(call)&&call[0]==='video.play')?.[1],element);
  await h.bridge.dispose('agora','legacy');
});
