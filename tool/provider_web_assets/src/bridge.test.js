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
  let contentObserver;

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
    addContentShareObserver(value) {
      contentObserver = value;
      calls.push('addContentShareObserver');
    },
    removeContentShareObserver(value) {
      assert.equal(value, contentObserver);
      calls.push('removeContentShareObserver');
    },
    async startContentShare(stream) {
      calls.push('startContentShare');
      contentObserver?.contentShareDidStart?.();
      return stream;
    },
    async startContentShareFromScreenCapture() {
      calls.push('startContentShareFromScreenCapture');
      const track = {
        id: 'chime-screen-track',kind:'video',readyState:'live',
        stop() { calls.push('stop:chime-screen-track'); },
        addEventListener() {},
      };
      contentObserver?.contentShareDidStart?.();
      return {getVideoTracks:()=>[track],getTracks:()=>[track]};
    },
    stopContentShare() {
      calls.push('stopContentShare');
      contentObserver?.contentShareDidStop?.();
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
    async stopVideoInput() {
      calls.push('stopVideoInput');
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
    setVideoCodecSendPreferences(preferences) {
      calls.push(`videoCodecs:${preferences.join(',')}`);
    },
    setContentShareVideoCodecPreferences(preferences) {
      calls.push(`contentCodecs:${preferences.join(',')}`);
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
      VideoCodecCapability: {
        h264ConstrainedBaselineProfile: () => 'H264_CBP',
        h264MainProfile: () => 'H264_MAIN',
        vp8: () => 'VP8',
      },
    },
  });
  const source = (await build({ entryPoints: [new URL('./bridge.js', import.meta.url).pathname], bundle: true, write: false, format: 'iife', platform: 'browser' })).outputFiles[0].text;
  const effectsSource = await readFile(new URL('../../../packages/flutter_realtime_video_effects/web/video-effects-bridge.js', import.meta.url), 'utf8');
  vm.runInContext(effectsSource, context, {filename: 'video-effects-bridge.js'});
  vm.runInContext(source, context, { filename: 'bridge.js' });
  return {
    bridge: context.MediaProviderBridge,
    context,
    audioVideo,
    calls,
    events,
    stopChime: (status) => observer?.audioVideoDidStop?.(status),
    stopContentShare: () => contentObserver?.contentShareDidStop?.(),
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

  assert.ok(!calls.some(call => call.startsWith('startAudioInput:')),
    'Chime must not capture the microphone during a muted join');
  assert.ok(calls.includes('bindRemoteAudio'));
  assert.ok(calls.includes('playRemoteAudio'));
  assert.ok(calls.includes('mute'));
  assert.ok(!calls.includes('startVideoInput:cam-1'));
  assert.ok(calls.includes('videoCodecs:H264_CBP,H264_MAIN,VP8'));
  assert.ok(calls.includes('contentCodecs:H264_CBP,H264_MAIN,VP8'));
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
  assert.ok(!calls.some(call => call.startsWith('startAudioInput:')),
    'choosing a microphone while muted is not permission to capture');
  await bridge.command('chime', 'meeting-1', 'setMuted', JSON.stringify({muted: false}));
  assert.ok(calls.includes('unmute'));
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
  assert.ok(!calls.includes('startVideoInput:cam-2'),
    'selecting a Chime camera must not capture before explicit enable');
  await bridge.command('chime','meeting-1','setVideoEnabled',{enabled:true});
  assert.ok(calls.includes('startVideoInput:cam-2'));
  await bridge.command('chime','meeting-1','setVideoEnabled',{enabled:false});
  assert.ok(calls.includes('stopVideoInput'),
    'disabling Chime camera must stop capture, not merely hide the tile');
  assert.ok(calls.includes('chooseAudioOutput:speaker-2'));
  assert.ok(calls.filter((entry) => entry === 'playRemoteAudio').length >= 2);

  await bridge.dispose('chime', 'meeting-1');
  assert.ok(calls.includes('unsubscribePresence'));
  assert.ok(calls.includes('unsubscribeData'));
  assert.ok(calls.includes('destroyDeviceController'));
  assert.ok(calls.includes('unbindRemoteAudio'));
  assert.ok(calls.includes('removeRemoteAudio'));
});

test('Chime bridge mutes and plays remote video elements for WebKit autoplay', async () => {
  const bridgeGlobal = await createChimeVideoHarness();
  await bridgeGlobal.bridge.create('chime', 'meeting-remote-video', JSON.stringify(chimePayload));
  await bridgeGlobal.bridge.join('chime', 'meeting-remote-video');
  bridgeGlobal.emitRemoteTile({ tileId: 7, boundAttendeeId: 'remote-1', localTile: false, isContent: false });
  const container = { querySelector: () => null, replaceChildren() {} };
  await bridgeGlobal.bridge.attachVideoElement('chime', 'meeting-remote-video', 'chime:tile:7', container);
  assert.equal(bridgeGlobal.videos[0].muted, true);
  assert.equal(bridgeGlobal.videos[0].defaultMuted, true);
  assert.equal(bridgeGlobal.videoPlayed, true);
  await bridgeGlobal.bridge.dispose('chime', 'meeting-remote-video');
});

async function createChimeVideoHarness() {
  let observer = null;
  let videoPlayed = false;
  const videos = [];
  const audioVideo = {
    addObserver(item) { observer = item; },
    removeObserver() {},
    addContentShareObserver() {},
    removeContentShareObserver() {},
    realtimeSubscribeToAttendeeIdPresence() {},
    realtimeUnsubscribeToAttendeeIdPresence() {},
    realtimeSubscribeToReceiveDataMessage() {},
    realtimeUnsubscribeFromReceiveDataMessage() {},
    bindAudioElement() {},
    unbindAudioElement() {},
    start() { queueMicrotask(() => observer?.audioVideoDidStart?.()); },
    realtimeMuteLocalAudio() {},
    getAllVideoTiles() { return []; },
    bindVideoElement() {},
    unbindVideoElement() {},
    stop() {},
  };
  const context = vm.createContext({
    console,
    TextDecoder,
    Blob,
    document: {
      createElement(tag) {
        if (tag === 'audio') {
          return { style: {}, addEventListener() {}, removeEventListener() {}, play: async () => {}, remove() {} };
        }
        const video = {
          style: {},
          autoplay: false,
          playsInline: false,
          muted: false,
          defaultMuted: false,
          play: async () => { videoPlayed = true; },
        };
        videos.push(video);
        return video;
      },
      body: { append() {} },
    },
    setTimeout,
    clearTimeout,
    setInterval: () => 1,
    clearInterval: () => {},
    ChimeSDK: {
      ConsoleLogger: class {},
      LogLevel: { WARN: 'warn' },
      DefaultDeviceController: class { async destroy() {} },
      MeetingSessionConfiguration: class {},
      DefaultMeetingSession: class { constructor() { this.audioVideo = audioVideo; } },
      MeetingSessionStatusCode: { Left: 'Left' },
    },
  });
  const source = (await build({
    entryPoints: [new URL('./bridge.js', import.meta.url).pathname],
    bundle: true,
    write: false,
    format: 'iife',
    platform: 'browser',
  })).outputFiles[0].text;
  vm.runInContext(source, context, { filename: 'bridge.js' });
  return {
    bridge: context.MediaProviderBridge,
    videos,
    get videoPlayed() { return videoPlayed; },
    emitRemoteTile(tile) { observer?.videoTileDidUpdate?.(tile); },
  };
}

test('Chime bridge multiplexes dotted topics over chat to prevent RealtimeApiFailed', async () => {
  const { bridge, calls, events, getDataObserver } = await createChimeHarness();
  await bridge.create('chime', 'meeting-topics', chimePayload);
  await bridge.join('chime', 'meeting-topics');

  await bridge.command('chime', 'meeting-topics', 'sendMessage', {
    topic: 'realtime.profile.v1',
    message: '{"displayName":"Mac"}',
    lifetimeMs: 300000,
  });
  await bridge.command('chime', 'meeting-topics', 'sendMessage', {
    topic: 'chat',
    message: 'hello room',
    lifetimeMs: 300000,
  });

  const sentCalls = calls.filter((c) => c.startsWith('message:'));
  assert.equal(sentCalls.length, 2);
  assert.ok(sentCalls[0].startsWith('message:chat:'));
  const envelopePayload = sentCalls[0].slice('message:chat:'.length, -':300000'.length);
  const parsed = JSON.parse(envelopePayload);
  assert.equal(parsed.__chimeTopicEnvelope, 1);
  assert.equal(parsed.topic, 'realtime.profile.v1');
  assert.equal(parsed.message, '{"displayName":"Mac"}');
  assert.equal(sentCalls[1], 'message:chat:hello room:300000');

  getDataObserver()({
    senderAttendeeId: 'attendee-2',
    senderExternalUserId: 'iPhone',
    topic: 'chat',
    text: () => envelopePayload,
    timestampMs: 1234,
    throttled: false,
  });
  getDataObserver()({
    senderAttendeeId: 'attendee-2',
    senderExternalUserId: 'iPhone',
    topic: 'chat',
    text: () => 'plain hello',
    timestampMs: 1235,
    throttled: false,
  });

  const messageEvents = events.filter((e) => e.event?.type === 'message');
  assert.equal(messageEvents.length, 2);
  assert.equal(messageEvents[0].event.topic, 'realtime.profile.v1');
  assert.equal(messageEvents[0].event.message, '{"displayName":"Mac"}');
  assert.equal(messageEvents[1].event.topic, 'chat');
  assert.equal(messageEvents[1].event.message, 'plain hello');

  await bridge.dispose('chime', 'meeting-topics');
});

test('Chime Web cannot resurrect a screen share stopped before capture resolves', async () => {
  const {bridge, audioVideo, events, calls} = await createChimeHarness();
  const start = audioVideo.startContentShareFromScreenCapture;
  audioVideo.startContentShareFromScreenCapture = async () => {
    const stream = await start();
    audioVideo.stopContentShare();
    return stream;
  };
  await bridge.create('chime','content-race',chimePayload);
  await bridge.join('chime','content-race');
  await assert.rejects(
    bridge.command('chime','content-race','setScreenShareEnabled',{enabled:true}),
    /capture ended before content sharing started/,
  );
  const snapshot = events.filter(({event}) => event.type === 'snapshot').at(-1).event;
  assert.equal(snapshot.tracks.some(track => track.isLocal && track.isScreenShare),false);
  assert.ok(calls.includes('stop:chime-screen-track'),
    'late screen stream must release capture after an asynchronous stop');
  await bridge.dispose('chime','content-race');
});

test('Chime Web only shows active local screen after content share starts and has a track', async () => {
  const {bridge, calls, events, stopContentShare} = await createChimeHarness();
  await bridge.create('chime','content-1',chimePayload);
  await bridge.join('chime','content-1');
  const localScreen = () => events.filter(({event}) => event.type === 'snapshot')
    .at(-1).event.tracks.find(track => track.isLocal && track.isScreenShare);
  assert.equal(localScreen(),undefined);
  await bridge.command('chime','content-1','setScreenShareEnabled',{enabled:true});
  assert.equal(localScreen()?.id,'chime:screen:attendee-1');
  stopContentShare();
  assert.equal(localScreen(),undefined,
    'a system/content-share stop must remove the local shared screen');
  assert.ok(calls.includes('stop:chime-screen-track'));
  await bridge.dispose('chime','content-1');
  assert.ok(calls.includes('removeContentShareObserver'));
});

test('Chime desktop sharing publishes a native RealtimeScreenCaptureBridge track when processedSourceId is supplied', async () => {
  const nativeTrack = {
    id: 'macos-sc-track-1',
    kind: 'video',
    readyState: 'live',
    addEventListener() {},
    stop() {},
  };
  const {bridge, calls, events} = await createChimeHarness({
    MediaStream: class FakeMediaStream {
      constructor(tracks) { this._tracks = tracks; }
      getVideoTracks() { return this._tracks; }
      getTracks() { return this._tracks; }
    },
    RealtimeScreenCaptureBridge: {
      getTrack(sourceId) {
        assert.equal(sourceId, 'aws-screen-chime-1');
        return nativeTrack;
      },
    },
  });
  await bridge.create('chime', 'content-native', chimePayload);
  await bridge.join('chime', 'content-native');
  await bridge.command('chime', 'content-native', 'setScreenShareEnabled', {
    enabled: true,
    processedSourceId: 'aws-screen-chime-1',
  });
  assert.ok(calls.includes('startContentShare'));
  assert.ok(!calls.includes('startContentShareFromScreenCapture'));
  const snapshot = events.filter(({event}) => event.type === 'snapshot').at(-1).event;
  assert.equal(
    snapshot.tracks.some((track) => track.id === 'chime:screen:attendee-1' && track.isLocal && track.isScreenShare),
    true,
  );
  await bridge.dispose('chime', 'content-native');
});

test('IVS Web awaits the Stage leave handshake before releasing local capture', async () => {
  const {bridge, calls, getStage} = await createIvsHarness();
  const payload = {participantId:'host',role:'host',
    ivs:{token:'publisher-token',capabilities:['PUBLISH','SUBSCRIBE']}};
  await bridge.create('ivs','wait-for-leave',payload);
  await bridge.join('ivs','wait-for-leave');
  await bridge.command('ivs','wait-for-leave','setMuted',{muted:false});
  let finishLeave;
  getStage().leave=()=>new Promise(resolve=>{finishLeave=resolve;});
  const disposing=bridge.dispose('ivs','wait-for-leave');
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(typeof finishLeave,'function');
  assert.ok(!calls.includes('stop:audio-1'),
    'the microphone must remain owned until Stage.leave resolves');
  finishLeave();
  await disposing;
  assert.ok(calls.includes('stop:audio-1'));
});

test('IVS Web always releases local capture if Stage.leave fails', async () => {
  const {bridge, calls, getStage} = await createIvsHarness();
  const payload = {participantId:'host',role:'host',
    ivs:{token:'publisher-token',capabilities:['PUBLISH','SUBSCRIBE']}};
  await bridge.create('ivs','failed-leave',payload);
  await bridge.join('ivs','failed-leave');
  await bridge.command('ivs','failed-leave','setMuted',{muted:false});
  getStage().leave=async()=>{throw new Error('Stage leave failed');};
  await assert.rejects(bridge.dispose('ivs','failed-leave'),/Stage leave failed/);
  assert.ok(calls.includes('stop:audio-1'),
    'a failed leave cannot keep recording the microphone');
});

test('ARTC Web viewer disables default microphone publication before joining', async () => {
  const h = await createAgoraHarness();
  const calls = [];
  const artc = {
    on(){}, setChannelProfile(){}, async setClientRole(){return 0;},
    async enableLocalVideo(){return 0;},
    async publishLocalVideoStream(){return 0;},
    async publishLocalAudioStream(enabled){calls.push(`audio:${enabled}`);return 0;},
    async joinChannel(){calls.push('join');return 0;},
    async leaveChannel(){}, async destroy(){},
  };
  h.context.AliRtcEngine = {
    createInstance:()=>artc,
    AliRtcSdkChannelProfile:{AliRtcInteractiveLive:'live'},
    AliRtcSdkClientRole:{AliRtcSdkLive:'audience'},
    AliRtcVideoTrack:{AliRtcVideoTrackCamera:1, AliRtcVideoTrackScreen:2},
    AliRtcConnectionStatus:{},
  };
  await h.bridge.create('artc','viewer',{participantId:'viewer',role:'viewer',artc:{authInfo:'test',userId:'viewer'}});
  await h.bridge.join('artc','viewer');
  assert.deepEqual(calls,['audio:false','join']);
  await assert.rejects(h.bridge.command('artc','viewer','setMuted',{muted:false}),/cannot publish/);
  await h.bridge.dispose('artc','viewer');
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
  assert.ok(calls.includes('videoCodecs:H264_CBP,H264_MAIN,VP8'));
  assert.ok(calls.includes('contentCodecs:H264_CBP,H264_MAIN,VP8'));
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

async function createIvsHarness(browserGlobals = {}) {
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
      createElement: (tag) => ({
        remove: () => calls.push(`dom:remove:${tag}`),
        pause: () => calls.push(`dom:pause:${tag}`),
        play: () => { calls.push(`dom:play:${tag}`); return Promise.resolve(); },
      }),
      addEventListener: () => {},
      removeEventListener: () => {},
      body: { append: () => calls.push('dom:append') },
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
    ...browserGlobals,
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
  assert.equal(calls.some((call) => call.startsWith('getUserMedia:')), false,
    'joining as an IVS publisher must not open the microphone');
  assert.ok(calls.includes('stage.join'));

  await bridge.command(
    'ivs',
    'stage-1',
    'setMuted',
    JSON.stringify({ muted: false }),
  );
  assert.ok(calls.some((call) => call.startsWith('mute:audio-') && call.endsWith(':false')));
  assert.ok(calls.some((call) => call.startsWith('getUserMedia:')),
    'explicit IVS unmute must acquire the microphone');

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
  const capturesVideo = () => calls.some((call) =>
    call.startsWith('getUserMedia:') && Boolean(JSON.parse(call.slice('getUserMedia:'.length)).video));
  assert.equal(capturesVideo(), false,
    'selecting an IVS camera while disabled must not activate video');
  await bridge.command('ivs', 'stage-1', 'setVideoEnabled', JSON.stringify({enabled: true}));
  assert.ok(capturesVideo(),
    'IVS camera enable must capture and publish real video');
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

test('IVS Web releases remote audio on participant exit or local leave', async () => {
  const {bridge, calls, getStage} = await createIvsHarness();
  await bridge.create('ivs', 'viewer-audio', JSON.stringify({
    participantId: 'viewer-audio', role: 'viewer',
    ivs: {token: 'token', capabilities: ['SUBSCRIBE']},
  }));
  await bridge.join('ivs', 'viewer-audio');
  const stage = getStage();
  const remote = {id: 'remote-audio', userId: 'remote-audio', isLocal: false};
  const makeStream = (id) => ({
    id, streamType: 'audio',
    mediaStreamTrack: {kind: 'audio', id},
  });
  stage.handlers.get('stageParticipantStreamsAdded')(remote, [makeStream('audio-a')]);
  assert.equal(calls.filter(x => x === 'dom:append').length, 1);
  stage.handlers.get('stageParticipantLeft')(remote);
  assert.equal(calls.filter(x => x === 'dom:remove:audio').length, 1);
  stage.handlers.get('stageParticipantStreamsAdded')(remote, [makeStream('audio-b')]);
  assert.equal(calls.filter(x => x === 'dom:append').length, 2);
  await bridge.dispose('ivs', 'viewer-audio');
  assert.equal(calls.filter(x => x === 'dom:remove:audio').length, 2,
    'local leave must clean audio tags even without remote stream-removal events');
});

test('IVS Web mirrors remote Stage audio mute events to participant state', async () => {
  const {bridge, getStage, events} = await createIvsHarness();
  await bridge.create('ivs', 'mute-state', JSON.stringify({
    participantId: 'viewer', role: 'viewer',
    ivs: {token: 'viewer-token', capabilities: ['SUBSCRIBE']},
  }));
  await bridge.join('ivs', 'mute-state');
  const remote = {userId:'speaker', id:'speaker', isLocal:false};
  getStage().handlers.get('stageParticipantStreamsAdded')(remote, [{
    id:'speaker-audio', streamType:'audio', mediaStreamTrack:{kind:'audio',id:'speaker-audio'},
  }]);
  const muteChange = getStage().handlers.get('stageStreamMuteChanged');
  assert.equal(typeof muteChange, 'function');
  const remoteMuted = () => events.filter(({event})=>event.type==='snapshot').at(-1)
    .event.participants.find(item=>item.id==='speaker').isMuted;
  muteChange(remote, {streamType:'audio', isMuted:true});
  assert.equal(remoteMuted(), true);
  muteChange(remote, {streamType:'audio', isMuted:false});
  assert.equal(remoteMuted(), false);
  await bridge.dispose('ivs', 'mute-state');
});

test('IVS device switch rolls back when refreshStrategy rejects the new stream', async () => {
  const {bridge, getStage, calls} = await createIvsHarness();
  await bridge.create('ivs','switch-rollback',{
    participantId:'host',role:'host',
    ivs:{token:'publisher-token',capabilities:['PUBLISH','SUBSCRIBE']},
  });
  await bridge.join('ivs','switch-rollback');
  await bridge.command('ivs','switch-rollback','setMuted',{muted:false});
  const stage=getStage();
  const before=stage.strategy.stageStreamsToPublish()[0];
  stage.refreshStrategy=()=>{throw new Error('IVS rejected replacement');};
  await assert.rejects(
    bridge.command('ivs','switch-rollback','selectDevice',{
      device:{kind:'microphone',id:'new-mic'},
    }),
    /IVS rejected replacement/,
  );
  assert.equal(stage.strategy.stageStreamsToPublish()[0],before);
  assert.ok(!calls.includes(`stop:${before.id}`),'old input must remain live after rejected switch');
  assert.ok(calls.includes('stop:audio-2'),'new rejected input must be closed');
  await bridge.dispose('ivs','switch-rollback');
});

test('TRTC Web uses current 5.19 screen-sharing API and stops capture on leave', async () => {
  const h = await createAgoraHarness();
  const calls = [];
  const listeners = new Map();
  const screenTrack = {kind:'video',id:'current-trtc-screen'};
  const trtc = {
    on(name, handler){listeners.set(name,handler);},
    async enterRoom(){},
    async startScreenShare(){calls.push('startScreenShare');},
    async stopScreenShare(){calls.push('stopScreenShare');},
    getVideoTrack({streamType}={}){return streamType==='sub'?screenTrack:null;},
    async startRemoteVideo(options){calls.push(options);},
    async exitRoom(){calls.push('exitRoom');},
    destroy(){},
  };
  h.context.TRTC = {create:()=>trtc, TYPE:{
    SCENE_RTC:'rtc', STREAM_TYPE_MAIN:'main', STREAM_TYPE_SUB:'sub',
  }};
  await h.bridge.create('trtc','current-share',{
    role:'participant',participantId:'presenting-user',
    trtc:{sdkAppId:1,strRoomId:'room',userId:'presenting-user',userSig:'signed'},
  });
  await h.bridge.join('trtc','current-share');
  await h.bridge.command('trtc','current-share','setScreenShareEnabled',{enabled:true});
  assert.ok(calls.includes('startScreenShare'));
  listeners.get('remote-video-available')({userId:'presenter',streamType:'sub'});
  const div={replaceChildren(){}};
  await h.bridge.attachVideoElement('trtc','current-share','trtc:video:presenter:sub',div);
  assert.equal(calls.find(call=>call && call.view)?.view,div);
  await h.bridge.dispose('trtc','current-share');
  assert.ok(calls.includes('stopScreenShare'));
  assert.ok(calls.includes('exitRoom'));
});

test('TRTC Web never reports screen-share success without a video track', async () => {
  const h = await createAgoraHarness();
  const calls = [];
  const trtc = {
    on(){},async enterRoom(){},
    async startScreenShare(){calls.push('start');},
    async stopScreenShare(){calls.push('stop');},
    getVideoTrack(){return null;},
    async exitRoom(){},destroy(){},
  };
  h.context.TRTC={create:()=>trtc,TYPE:{SCENE_RTC:'rtc',STREAM_TYPE_SUB:'sub'}};
  await h.bridge.create('trtc','empty-screen',{
    participantId:'presenting-user',role:'participant',
    trtc:{sdkAppId:1,strRoomId:'room',userId:'presenting-user',userSig:'signed'},
  });
  await h.bridge.join('trtc','empty-screen');
  await assert.rejects(
    h.bridge.command('trtc','empty-screen','setScreenShareEnabled',{enabled:true}),
    /without a screen video track/,
  );
  assert.deepEqual(calls,['start','stop']);
  await h.bridge.dispose('trtc','empty-screen');
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
  await bridge.command('ivs', 'stage-screen', 'setVideoEnabled', JSON.stringify({enabled: true}));
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
  await bridge.command('ivs', 'stage-share-dispose', 'setVideoEnabled', JSON.stringify({enabled: true}));
  const camera = getStage().strategy.stageStreamsToPublish()
    .find(stream => stream.streamType === 'video');
  await bridge.command('ivs', 'stage-share-dispose', 'setScreenShareEnabled', JSON.stringify({enabled: true}));
  await bridge.dispose('ivs', 'stage-share-dispose');
  assert.ok(calls.includes(`stop:${camera.id}`));
  assert.ok(calls.includes('stop:screen-1'));
});

test('IVS desktop sharing publishes a native RealtimeScreenCaptureBridge track when processedSourceId is supplied', async () => {
  const {bridge, calls, events} = await createIvsHarness({
    RealtimeScreenCaptureBridge: {
      getTrack(sourceId) {
        assert.equal(sourceId, 'aws-screen-ivs-1');
        return {
          id: 'macos-ivs-sc-1',
          readyState: 'live',
          addEventListener() {},
          stop() { calls.push('stop:macos-ivs-sc-1'); },
        };
      },
    },
  });
  await bridge.create('ivs', 'stage-native-screen', JSON.stringify({
    participantId: 'host', role: 'host',
    ivs: {token: 'publisher-token', capabilities: ['PUBLISH', 'SUBSCRIBE']},
  }));
  await bridge.join('ivs', 'stage-native-screen');
  await bridge.command('ivs', 'stage-native-screen', 'setScreenShareEnabled', JSON.stringify({
    enabled: true,
    processedSourceId: 'aws-screen-ivs-1',
  }));
  assert.ok(!calls.includes('getDisplayMedia'));
  assert.ok(events.some(({event}) =>
    event.type === 'snapshot' && event.tracks?.some((t) => t.id === 'ivs:screen:macos-ivs-sc-1' && t.isScreenShare && t.isLocal)));
  await bridge.command('ivs', 'stage-native-screen', 'setScreenShareEnabled', JSON.stringify({enabled: false}));
  assert.ok(calls.includes('stop:macos-ivs-sc-1'));
  await bridge.dispose('ivs', 'stage-native-screen');
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
    on(){}, async enterRoom(){}, async startLocalAudio(){audioActions.push('trtc:start');}, async stopLocalVideo(){},
    async stopLocalAudio(){audioActions.push('trtc:stop');},
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
    addContentShareObserver(){}, removeContentShareObserver(){},
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
      if (provider === 'trtc') {
        assert.ok(!audioActions.includes('trtc:start'),
          'TRTC must not capture/publish mic audio before explicit unmute');
      } else {
        assert.ok(audioActions.includes('artc:false'),
          'ARTC must join without publishing microphone audio');
      }
      await h.bridge.command(provider,provider,'setMuted',{muted:false});
      assert.ok(audioActions.includes(provider === 'trtc' ? 'trtc:start' : 'artc:true'),
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

test('ARTC Web does not report published media when provider returns error codes', async () => {
  const h = await createAgoraHarness();
  const calls = [];
  const artc = {
    on(){}, setChannelProfile(){},
    async enableLocalVideo(){return 0;},
    async publishLocalVideoStream(enabled){return enabled ? -24 : 0;},
    async publishLocalAudioStream(enabled){return enabled ? -17 : 0;},
    async muteLocalMic(){return 0;},
    async joinChannel(){return 0;},
    async startPreviewScreen(){calls.push('screen-preview:start');return 0;},
    async publishLocalScreenShareStream(enabled){return enabled ? -33 : 0;},
    async stopPreviewScreen(){calls.push('screen-preview:stop');return 0;},
    async leaveChannel(){},async destroy(){},
  };
  h.context.AliRtcEngine = {
    createInstance:()=>artc,
    AliRtcSdkChannelProfile:{AliRtcSdkCommunication:'rtc'},
    AliRtcSdkClientRole:{},
    AliRtcVideoTrack:{AliRtcVideoTrackCamera:1, AliRtcVideoTrackScreen:2},
    AliRtcConnectionStatus:{},
  };
  const payload = {
    participantId: 'host', role: 'participant', displayName: 'Host',
    artc: {authInfo: 'test', userId: 'host'},
  };
  await h.bridge.create('artc', 'error-codes', payload);
  await h.bridge.join('artc', 'error-codes');
  await assert.rejects(
    h.bridge.command('artc', 'error-codes', 'setMuted', {muted: false}),
    /microphone publication failed \(-17\)/,
  );
  await assert.rejects(
    h.bridge.command('artc', 'error-codes', 'setVideoEnabled', {enabled: true}),
    /camera publication failed \(-24\)/,
  );
  await assert.rejects(
    h.bridge.command('artc', 'error-codes', 'setScreenShareEnabled', {enabled: true}),
    /publish screen failed \(-33\)/,
  );
  assert.ok(calls.includes('screen-preview:stop'), 'failed ARTC screen publish must stop capture');
  await h.bridge.dispose('artc', 'error-codes');
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

test('overlapping multi-view attachments preserve active container until last detach', async () => {
  const h = await createAgoraHarness();
  let stoppedCount = 0;
  await h.bridge.create('agora', 'multi-view', agoraPayload);
  await h.bridge.join('agora', 'multi-view');
  const client = h.context.AgoraRTC.createClient();
  const played = [];
  const remote = {
    uid: 777,
    videoTrack: {
      play(container) { played.push(container); },
      stop() { stoppedCount += 1; },
    },
  };
  client.remoteUsers.push(remote);
  await client.handlers.get('user-published')(remote, 'video');
  const gridCleared = [];
  const grid = { id: 'grid-tile', replaceChildren() { gridCleared.push(true); } };
  const spotlight = { id: 'spotlight-tile', replaceChildren() {} };
  await h.bridge.attachVideoElement('agora', 'multi-view', 'agora:video:777', grid);
  await h.bridge.attachVideoElement('agora', 'multi-view', 'agora:video:777', spotlight);
  // Detaching the older grid tile while spotlight remains mounted must not stop remote video.
  h.bridge.detachVideo('agora', 'multi-view', 'agora:video:777', 'grid-tile');
  await Promise.resolve();
  assert.equal(stoppedCount, 0);
  assert.equal(gridCleared.length, 1);
  assert.equal(played.at(-1), spotlight);
  // Detaching the final container stops remote playback cleanly.
  h.bridge.detachVideo('agora', 'multi-view', 'agora:video:777', 'spotlight-tile');
  assert.equal(stoppedCount, 1);
  await h.bridge.dispose('agora', 'multi-view');
});

test('Chime and IVS emit recoverable warnings instead of fatal errors when audio autoplay is blocked', async () => {
  const listeners = new Map();
  const chime = await createChimeHarness({
    document: {
      addEventListener(name, fn) { listeners.set(name, fn); },
      removeEventListener(name) { listeners.delete(name); },
      createElement: () => ({
        style: {},
        play: async () => { throw new Error('NotAllowedError: play() failed'); },
        remove: () => {},
      }),
      body: { append: () => {} },
    },
  });
  await chime.bridge.create('chime', 'autoplay-chime', chimePayload);
  await chime.bridge.join('chime', 'autoplay-chime');
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(chime.events.some(({ event }) => event.type === 'error'), false);
  const warning = chime.events.find(({ event }) => event.type === 'warning')?.event;
  assert.equal(warning?.code, 'audio-autoplay-blocked');
  assert.equal(warning?.recoverable, true);
  assert.equal(typeof listeners.get('pointerdown'), 'function');
  assert.equal(typeof listeners.get('keydown'), 'function');
  await chime.bridge.dispose('chime', 'autoplay-chime');
});

test('Agora Web broadcasts screen-share signals to native peers and supports data messages', async () => {
  const { bridge, context, events } = await createAgoraHarness();
  await bridge.create('agora', 'agora-signals', JSON.stringify(agoraPayload));
  await bridge.join('agora', 'agora-signals');
  const client = context.AgoraRTC.createClient();
  const sentPayloads = [];
  client.sendStreamMessage = async (bytes) => {
    sentPayloads.push(JSON.parse(new TextDecoder().decode(bytes)));
  };
  context.AgoraRTC.createScreenVideoTrack = async () => ({
    id: 'screen-out',
    close() {},
    on() {},
  });
  await bridge.command('agora', 'agora-signals', 'setScreenShareEnabled', { enabled: true });
  assert.equal(sentPayloads[0]?.topic, '_flutter_realtime.screen_share.v1');
  assert.equal(sentPayloads[0]?.message, 'started');
  await bridge.command('agora', 'agora-signals', 'sendMessage', {
    topic: 'custom.whiteboard',
    message: '{"stroke":1}',
  });
  assert.equal(sentPayloads[1]?.topic, 'custom.whiteboard');
  assert.equal(sentPayloads[1]?.message, '{"stroke":1}');

  client.handlers.get('stream-message')(
    901,
    new TextEncoder().encode(JSON.stringify({
      version: 1,
      topic: 'custom.whiteboard',
      message: '{"stroke":2}',
      timestampMs: 4321,
    })),
  );
  const incoming = events.find(({ event }) => event.type === 'message')?.event;
  assert.equal(incoming?.topic, 'custom.whiteboard');
  assert.equal(incoming?.message, '{"stroke":2}');

  await bridge.command('agora', 'agora-signals', 'setScreenShareEnabled', { enabled: false });
  assert.equal(sentPayloads.at(-1)?.topic, '_flutter_realtime.screen_share.v1');
  assert.equal(sentPayloads.at(-1)?.message, 'stopped');
  await bridge.dispose('agora', 'agora-signals');
});

test('TRTC Web defers camera device updates while video is disabled and applies selected camera on enable', async () => {
  const h = await createAgoraHarness();
  const calls = [];
  const trtc = {
    on() {},
    async enterRoom() {},
    async startLocalVideo({ option }) { calls.push(['startLocalVideo', option]); },
    async updateLocalVideo({ option }) { calls.push(['updateLocalVideo', option]); },
    async stopLocalVideo() { calls.push(['stopLocalVideo']); },
    getVideoTrack() { return { kind: 'video', id: 'trtc-cam' }; },
    async exitRoom() {},
    destroy() {},
  };
  h.context.TRTC = {
    create: () => trtc,
    getCameras: async () => [{ deviceId: 'cam-a' }, { deviceId: 'cam-b' }],
    TYPE: { SCENE_RTC: 'rtc' },
  };
  await h.bridge.create('trtc', 'trtc-offline-cam', {
    role: 'participant',
    participantId: 'u1',
    trtc: { sdkAppId: 1, strRoomId: 'r1', userId: 'u1', userSig: 'sig' },
  });
  await h.bridge.join('trtc', 'trtc-offline-cam');
  await h.bridge.command('trtc', 'trtc-offline-cam', 'selectDevice', {
    device: { kind: 'camera', id: 'cam-b' },
  });
  assert.equal(calls.length, 0, 'selecting camera while video is off must not call updateLocalVideo');
  await h.bridge.command('trtc', 'trtc-offline-cam', 'setVideoEnabled', { enabled: true });
  assert.equal(calls[0][0], 'startLocalVideo');
  assert.equal(calls[0][1].cameraId, 'cam-b');
  await h.bridge.dispose('trtc', 'trtc-offline-cam');
});

test('ARTC Web stops active screen capture on leave and defers switchCamera while video is off', async () => {
  const h = await createAgoraHarness();
  const calls = [];
  const artc = {
    on() {},
    setChannelProfile() {},
    async enableLocalVideo() { return 0; },
    async publishLocalVideoStream() { return 0; },
    async publishLocalAudioStream() { return 0; },
    async joinChannel() { return 0; },
    setCameraCapturerConfiguration(cfg) { calls.push(`config:${cfg.deviceId}`); },
    async switchCamera(id) { calls.push(`switch:${id}`); return 0; },
    async startPreviewScreen() { calls.push('screen:start'); return 0; },
    async publishLocalScreenShareStream(enabled) { calls.push(`screen:publish:${enabled}`); return 0; },
    async stopPreviewScreen() { calls.push('screen:stop'); return 0; },
    async leaveChannel() { calls.push('leaveChannel'); },
    async destroy() {},
  };
  h.context.AliRtcEngine = {
    createInstance: () => artc,
    getCameraList: async () => [{ deviceId: 'cam-1' }, { deviceId: 'cam-2' }],
    AliRtcSdkChannelProfile: { AliRtcSdkCommunication: 'rtc' },
    AliRtcSdkClientRole: {},
    AliRtcVideoTrack: { AliRtcVideoTrackCamera: 1, AliRtcVideoTrackScreen: 2 },
    AliRtcConnectionStatus: {},
  };
  await h.bridge.create('artc', 'artc-leave-screen', {
    participantId: 'host',
    role: 'participant',
    artc: { authInfo: 'test', userId: 'host' },
  });
  await h.bridge.join('artc', 'artc-leave-screen');
  await h.bridge.command('artc', 'artc-leave-screen', 'selectDevice', {
    device: { kind: 'camera', id: 'cam-2' },
  });
  assert.deepEqual(calls, ['config:cam-2']);
  await h.bridge.command('artc', 'artc-leave-screen', 'setScreenShareEnabled', { enabled: true });
  await h.bridge.dispose('artc', 'artc-leave-screen');
  assert.ok(calls.includes('screen:stop'), 'leaving ARTC while sharing must stop screen capture');
});

test('Chime entry synthesizes silent AudioContext when navigator.mediaDevices is unavailable', async () => {
  const chimeBundleSource = await readFile(
    new URL('../../../packages/flutter_realtime_provider_aws/assets/chime-sdk.js', import.meta.url),
    'utf8',
  );
  let createdContexts = 0;
  const context = vm.createContext({
    console,
    navigator: {},
    window: {},
    self: {},
    AudioContext: class FakeAudioContext {
      constructor() {
        createdContexts += 1;
        this.sampleRate = 48000;
      }
    },
  });
  context.window = context;
  context.self = context;
  vm.runInContext(chimeBundleSource, context, { filename: 'chime-sdk.js' });
  const audioCtx = context.ChimeSDK.DefaultDeviceController.getAudioContext();
  assert.ok(audioCtx);
  assert.equal(createdContexts, 1);
  assert.equal(context.ChimeSDK.DefaultDeviceController.getAudioContext(), audioCtx);
});

test('Chime Web tolerates WebKit missing setSinkId, matches native camera label, and preserves tile dimensions', async () => {
  const { bridge, audioVideo, calls, events } = await createChimeHarness();
  let capturedObserver;
  const origAddObserver = audioVideo.addObserver;
  audioVideo.addObserver = (obs) => {
    capturedObserver = obs;
    origAddObserver(obs);
  };
  audioVideo.chooseAudioOutput = async () => {
    throw new Error('Cannot select audio output device. This browser does not support setSinkId.');
  };
  audioVideo.listVideoInputDevices = async () => [
    { deviceId: 'webkit-hashed-cam-id', label: 'FaceTime HD Camera', groupId: 'g-cam' },
  ];

  await bridge.create('chime', 'webkit-compat', JSON.stringify(chimePayload));
  await bridge.join('chime', 'webkit-compat');

  // Must not reject on WebKit where HTMLMediaElement.setSinkId is absent.
  await bridge.command('chime', 'webkit-compat', 'selectAudioOutput', {
    id: 'default-speaker',
    label: 'MacBook Pro Speakers',
    kind: 'audioOutput',
  });

  // Selecting a macOS AVCaptureDevice uniqueID with matching label resolves to WebKit's deviceId.
  await bridge.command('chime', 'webkit-compat', 'selectDevice', {
    device: { id: '0x1234000005ac8514', label: 'FaceTime HD Camera', kind: 'camera' },
  });
  await bridge.command('chime', 'webkit-compat', 'setVideoEnabled', { enabled: true });
  assert.ok(calls.includes('startVideoInput:webkit-hashed-cam-id'));

  capturedObserver.videoTileDidUpdate({
    tileId: 3,
    boundAttendeeId: 'remote-peer',
    localTile: false,
    isContent: false,
    videoStreamContentWidth: 1280,
    videoStreamContentHeight: 720,
  });
  const latestSnapshot = events.filter(({ event }) => event.type === 'snapshot').at(-1)?.event;
  const remoteTrack = latestSnapshot?.tracks?.find((t) => t.id === 'chime:tile:3');
  assert.equal(remoteTrack?.width, 1280);
  assert.equal(remoteTrack?.height, 720);

  await bridge.dispose('chime', 'webkit-compat');
});

test('Chime bridge emits ended state and clears participants on remote MeetingEnded stop', async () => {
  const { bridge, stopChime, events } = await createChimeHarness();
  await bridge.create('chime', 'chime-remote-end', JSON.stringify(chimePayload));
  await bridge.join('chime', 'chime-remote-end');

  events.length = 0;
  stopChime({ statusCode: () => 6 });

  const endedState = events.find(({ event }) => event.type === 'state' && event.state === 'ended');
  assert.ok(endedState, 'remote MeetingEnded must emit state: ended');
  assert.equal(
    events.some(({ event }) => event.type === 'error'),
    false,
    'clean remote MeetingEnded must not emit a fatal error event',
  );
  const latestSnapshot = events.filter(({ event }) => event.type === 'snapshot').at(-1)?.event;
  assert.deepEqual(latestSnapshot?.participants, []);
  assert.deepEqual(latestSnapshot?.tracks, []);

  await bridge.dispose('chime', 'chime-remote-end');
});

test('IVS bridge emits ended state when Stage disconnects after connecting', async () => {
  const { bridge, getStage, events } = await createIvsHarness();
  await bridge.create('ivs', 'ivs-remote-end', JSON.stringify({
    participantId: 'viewer-1',
    role: 'viewer',
    ivs: { token: 'viewer-token', capabilities: ['SUBSCRIBE'] },
  }));
  await bridge.join('ivs', 'ivs-remote-end');

  const connHandler = getStage().handlers.get('stageConnectionStateChanged');
  assert.equal(typeof connHandler, 'function');
  connHandler('connected');
  events.length = 0;

  connHandler('disconnected');
  const endedState = events.find(({ event }) => event.type === 'state' && event.state === 'ended');
  assert.ok(endedState, 'remote Stage disconnect after CONNECTED must emit state: ended');
  const latestSnapshot = events.filter(({ event }) => event.type === 'snapshot').at(-1)?.event;
  assert.deepEqual(latestSnapshot?.participants, []);
  assert.deepEqual(latestSnapshot?.tracks, []);

  await bridge.dispose('ivs', 'ivs-remote-end');
});

test('Chime preserves shared non-cloned processed track across detach and leave', async () => {
  const { bridge, context, calls } = await createChimeHarness();
  let stopped = 0;
  let enabledState = true;
  const sharedTrack = {
    kind: 'video',
    id: 'desktop-capture-0',
    clone() { return this; },
    stop() { stopped += 1; },
  };
  context.MediaStream = class { constructor(tracks) { this.tracks = tracks; } };
  context.RealtimeProcessedVideoBridge.register('mac-blur', {
    track: sharedTrack,
    async setEnabled(enabled) { enabledState = enabled; },
    async setCameraDevice() {},
  });
  try {
    await bridge.create('chime', 'chime-mac-blur', JSON.stringify(chimePayload));
    await bridge.join('chime', 'chime-mac-blur');
    await bridge.command('chime', 'chime-mac-blur', 'attachProcessedVideoSource', { sourceId: 'mac-blur' });
    assert.ok(calls.some((entry) => entry.startsWith('startVideoInput:')), 'attaching processed source must feed Chime');
    await bridge.command('chime', 'chime-mac-blur', 'setVideoEnabled', { enabled: true });
    assert.equal(enabledState, true);
    await bridge.command('chime', 'chime-mac-blur', 'detachProcessedVideoSource', {});
    assert.equal(stopped, 0, 'non-cloned desktop track must stay owned by native runtime');
    await bridge.command('chime', 'chime-mac-blur', 'attachProcessedVideoSource', { sourceId: 'mac-blur' });
    await bridge.leave('chime', 'chime-mac-blur');
    assert.equal(stopped, 0, 'leaving Chime must not stop a non-cloned desktop track');
    await bridge.dispose('chime', 'chime-mac-blur');
  } finally {
    context.RealtimeProcessedVideoBridge.unregister('mac-blur');
  }
});



