import '../../../packages/flutter_realtime_processed_video/web/processed-video-bridge.js';
import { createAgoraSession } from './media/agora-session.js';
import { createTrtcSession } from './media/trtc-session.js';
import { createArtcSession } from './media/artc-session.js';
import { createIvsSession } from './media/ivs-session.js';
import { createChimeSession } from './media/chime-session.js';
(function installMediaProviderBridge(global) {
  'use strict';

  const sessions = new Map();
  const StageEvents = {
    CONNECTION: 'stageConnectionStateChanged',
    JOINED: 'stageParticipantJoined',
    LEFT: 'stageParticipantLeft',
    STREAMS_ADDED: 'stageParticipantStreamsAdded',
    STREAMS_REMOVED: 'stageParticipantStreamsRemoved',
    STREAM_MUTE_CHANGED: 'stageStreamMuteChanged',
    ERROR: 'stageError',
  };

  let nextPreviewSource = 0;
  async function createSdkProcessedVideo({effect = {type: 'none'}, deviceId = null} = {}) {
    const bridge = global.RealtimeVideoEffectsBridge;
    if (!bridge) return createRawPreview({effect, deviceId});
    const id = `provider-preview-${Date.now()}-${nextPreviewSource++}`;
    await bridge.createSource(id, {effect, cameraDeviceId: deviceId});
    return {
      get track() { return bridge.getTrack(id); },
      setEffect: (next) => bridge.setEffect(id, next),
      setCameraDevice: (next) => bridge.selectCamera(id, next),
      setEnabled: (enabled) => bridge.setEnabled(id, enabled),
      stop: () => bridge.disposeSource(id),
    };
  }

  async function createRawPreview({effect, deviceId}) {
    if (effect.type !== 'none') throw new Error('preview.effects.unregistered');
    let track = null;
    let stopped = false;
    async function setEnabled(enabled) {
      if (!enabled) { track?.stop(); track = null; return; }
      if (stopped) throw new Error('preview.disposed');
      if (track) return;
      const stream = await global.navigator.mediaDevices.getUserMedia({audio: false, video: deviceId ? {deviceId: {exact: deviceId}} : true});
      if (stopped) { stream.getTracks().forEach((item) => item.stop()); throw new Error('preview.disposed'); }
      track = stream.getVideoTracks()[0];
    }
    await setEnabled(true);
    return {
      get track() { return track; }, setEnabled,
      async setEffect(next) { if (next.type !== 'none') throw new Error('preview.effects.unregistered'); },
      async setCameraDevice(next) { deviceId = next; if (track) { await setEnabled(false); await setEnabled(true); } },
      async stop() { stopped = true; await setEnabled(false); },
    };
  }

  function parsePayload(value) {
    return typeof value === 'string' ? JSON.parse(value) : value;
  }

  function providerBlock(session, key = session.providerId) {
    const payload = session.payload;
    const block = payload[key];
    return block && typeof block === 'object' ? block : payload;
  }

  function emit(session, event) {
    if (session.disposed) return;
    const callback = global.__flutterMediaProviderOnEvent;
    if (typeof callback === 'function') {
      callback(session.id, JSON.stringify(event));
    }
  }

  function emitState(session, state, reason) {
    emit(session, { type: 'state', state, reason });
  }

  function addParticipant(session, id, displayName, isLocal = false) {
    if (!id) return null;
    const current = session.participants.get(String(id)) || {};
    const participant = {
      ...current,
      id: String(id),
      displayName: displayName || current.displayName || String(id),
      isLocal: Boolean(isLocal || current.isLocal),
      isMuted: Boolean(current.isMuted),
      isVideoEnabled: Boolean(current.isVideoEnabled),
    };
    session.participants.set(participant.id, participant);
    return participant;
  }

  function removeParticipant(session, id) {
    const participantId = String(id || '');
    if (!participantId || participantId === session.localParticipantId) return;
    session.participants.delete(participantId);
    for (const [trackId, track] of session.tracks) {
      if (track.participantId === participantId) session.tracks.delete(trackId);
    }
    publishSnapshot(session);
  }

  function addVideoTrack(session, { id, participantId, isLocal = false, isScreenShare = false, native }) {
    if (!id || !participantId) return null;
    const track = {
      id: String(id),
      participantId: String(participantId),
      isLocal: Boolean(isLocal),
      isScreenShare: Boolean(isScreenShare),
      native,
    };
    session.tracks.set(track.id, track);
    const participant = addParticipant(session, participantId, null, isLocal);
    participant.isVideoEnabled = true;
    if (!isScreenShare) participant.videoTrackId = track.id;
    publishSnapshot(session);
    return track;
  }

  function removeVideoTrack(session, id) {
    const track = session.tracks.get(String(id));
    if (!track) return;
    session.tracks.delete(String(id));
    const participant = session.participants.get(track.participantId);
    if (participant && ![...session.tracks.values()].some((item) => item.participantId === track.participantId)) {
      participant.isVideoEnabled = false;
      delete participant.videoTrackId;
    } else if (participant && participant.videoTrackId === track.id) {
      const replacement = [...session.tracks.values()].find(
        (item) => item.participantId === track.participantId && !item.isScreenShare,
      );
      participant.videoTrackId = replacement?.id;
      if (!replacement) participant.isVideoEnabled = false;
    }
    publishSnapshot(session);
  }

  function emitMessage(session, { participantId, displayName, message, topic = 'chat', timestampMs = Date.now(), throttled = false }) {
    emit(session, {
      type: 'message',
      participantId: String(participantId || ''),
      displayName: String(displayName || participantId || ''),
      message: String(message || ''),
      topic: String(topic || 'chat'),
      timestampMs: Number(timestampMs || Date.now()),
      throttled: Boolean(throttled),
    });
  }

  function publishSnapshot(session) {
    const participants = [...session.participants.values()];
    emit(session, {
      type: 'snapshot',
      localParticipantId: session.localParticipantId,
      localMuted: session.localMuted,
      localVideoEnabled: session.localVideoEnabled,
      participants,
      tracks: [...session.tracks.values()].map(({ native, ...track }) => track),
    });
  }

  function reportError(session, error) {
    emit(session, {
      type: 'error',
      message: error && error.message ? error.message : String(error),
    });
  }

  function createSession(providerId, id, payload) {
    const context = { global, StageEvents, createSdkProcessedVideo, parsePayload, providerBlock, emit, emitState, addParticipant, removeParticipant, addVideoTrack, removeVideoTrack, emitMessage, publishSnapshot, reportError, createSession, join, leave, dispose, startStats, stopStats, effectsTrack, command, listDevices, makeVideoElement, attachStreamTrack, getTrackAttachment, requireSession };
    const role = String(payload.role || 'participant').toLowerCase();
    const session = {
      id,
      providerId,
      payload,
      role,
      localParticipantId: String(payload.participantId || ''),
      localMuted: true,
      localVideoEnabled: false,
      joined: false,
      joining: false,
      disposed: false,
      participants: new Map(),
      tracks: new Map(),
      attachments: new Map(),
      timers: new Set(),
      screenTrack: null,
    };
    addParticipant(session, session.localParticipantId, payload.displayName, true);
    switch (providerId) {
      case 'agora': return createAgoraSession(session, context);
      case 'chime': return createChimeSession(session, context);
      case 'trtc': return createTrtcSession(session, context);
      case 'artc': return createArtcSession(session, context);
      case 'ivs': return createIvsSession(session, context);
      default:
        throw new Error(`No browser SDK driver is registered for ${providerId}.`);
    }
  }

  async function join(session) {
    session.joining = true;
    session.joinAttempted = true;
    emitState(session, 'connecting');
    try {
      await session.driver.join();
      if (session.disposed) {
        await session.driver.leave();
        throw new Error('media.join.cancelled');
      }
    } catch (error) {
      // A Chime signaling attempt may have started even if we never received
      // audioVideoDidStart. Tear it down instead of leaking a background SDK
      // connection when the caller retries after a timeout or stop event.
      if (session.providerId === 'chime') {
        try { await session.driver.leave(); session.joinAttempted = false; }
        catch (_) { /* Keep the original signaling failure. */ }
      }
      throw error;
    } finally {
      session.joining = false;
    }
    session.joined = true;
    emitState(session, 'connected');
    publishSnapshot(session);
    startStats(session);
  }

  async function leave(session) {
    if (!session.joined) return;
    stopStats(session);
    await session.driver.leave();
    session.processedTrack?.stop?.();
    session.processedTrack = null;
    session.processedSourceId = null;
    session.joined = false;
    session.tracks.clear();
    session.participants.clear();
    session.localParticipantId = '';
    emitState(session, 'ended');
    publishSnapshot(session);
  }

  async function dispose(session) {
    if (session.disposeFuture) return session.disposeFuture;
    session.disposed = true;
    stopStats(session);
    // Invalidate the registry synchronously, even if vendor teardown stalls.
    if (sessions.get(session.id) === session) sessions.delete(session.id);
    const partialJoin = session.joinAttempted && !session.joined;
    session.disposeFuture = (async () => {
    try {
      if (partialJoin) await session.driver.leave();
      else await leave(session);
    } finally {
      stopStats(session);
      if (session.driver.dispose) await session.driver.dispose();
      if (sessions.get(session.id) === session) sessions.delete(session.id);
    }
    })();
    return session.disposeFuture;
  }

  function startStats(session) {
    if (!session.driver.getStats || session.timers.size) return;
    const timer = global.setInterval(async () => {
      try {
        const stats = await session.driver.getStats();
        if (stats) emit(session, { type: 'stats', timestampMs: Date.now(), ...stats });
      } catch (_) {
        // Stats are best-effort and must not affect a live call.
      }
    }, 4000);
    session.timers.add(timer);
  }

  function stopStats(session) {
    for (const timer of session.timers) global.clearInterval(timer);
    session.timers.clear();
  }

  function effectsTrack(sourceId) {
    const track = global.RealtimeProcessedVideoBridge?.getTrack(sourceId);
    if (!track) throw new Error(`Unknown processed video source: ${sourceId}`);
    return track;
  }

  async function command(session, name, args) {
    if (!session.joined && name !== 'listDevices') {
      throw new Error(`Cannot run ${name} while the session is not connected.`);
    }
    args ||= {};
    if (session.role === 'viewer' && [
      'attachProcessedVideoSource', 'setProcessedVideoEffect', 'setScreenShareEnabled',
    ].includes(name)) {
      throw new Error('Viewers cannot publish camera or screen video.');
    }
    if (name === 'attachProcessedVideoSource' && session.providerId !== 'agora') {
      const sourceId = String(args.sourceId || '');
      if (session.processedSourceId === sourceId) return '';
      if (!session.driver.attachProcessedTrack) throw new Error('Provider has no processed video input.');
      const sourceTrack = effectsTrack(sourceId);
      const track = sourceTrack.clone?.() || sourceTrack;
      try { await session.driver.attachProcessedTrack(track); }
      catch (error) { if (track !== sourceTrack) track.stop?.(); throw error; }
      session.processedTrack?.stop?.();
      session.processedSourceId = sourceId;
      session.processedTrack = track;
      publishSnapshot(session);
      return '';
    }
    if (name === 'detachProcessedVideoSource' && session.providerId !== 'agora') {
      await session.driver.command('setVideoEnabled', {enabled: false});
      await session.driver.detachProcessedTrack?.();
      session.processedTrack?.stop?.();
      session.processedTrack = null;
      session.processedSourceId = null;
      publishSnapshot(session);
      return '';
    }
    const sourceId = session.processedSourceId;
    if (sourceId && name === 'setProcessedVideoEffect') {
      await global.RealtimeVideoEffectsBridge.setEffect(sourceId, JSON.stringify(args));
      return '';
    }
    if (sourceId && name === 'selectDevice' && (args.device || args).kind === 'camera') {
      await global.RealtimeProcessedVideoBridge.selectCamera(sourceId, (args.device || args).id);
      return '';
    }
    if (sourceId && name === 'switchCamera') {
      const cameras = (await listDevices(session)).filter((d) => d.kind === 'camera');
      const next = cameras[(cameras.findIndex((d) => d.id === session.cameraId) + 1) % cameras.length];
      if (next) { await global.RealtimeProcessedVideoBridge.selectCamera(sourceId, next.id); session.cameraId = next.id; }
      return '';
    }
    if (sourceId && name === 'setVideoEnabled') {
      await global.RealtimeProcessedVideoBridge.setEnabled(sourceId, Boolean(args.enabled));
    }
    const result = await session.driver.command(name, args);
    publishSnapshot(session);
    return result === undefined ? '' : JSON.stringify(result);
  }

  async function listDevices(session) {
    if (!global.navigator || !navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) return [];
    const devices = await navigator.mediaDevices.enumerateDevices();
    return devices.map((device) => ({
      id: device.deviceId,
      label: device.label,
      groupId: device.groupId,
      kind: device.kind === 'audioinput' ? 'microphone' : device.kind === 'audiooutput' ? 'audioOutput' : 'camera',
    }));
  }

  function makeVideoElement(container) {
    const existing = container.querySelector('video');
    if (existing) return existing;
    const video = document.createElement('video');
    video.autoplay = true;
    video.playsInline = true;
    video.muted = false;
    video.style.width = '100%';
    video.style.height = '100%';
    video.style.objectFit = 'contain';
    container.replaceChildren(video);
    return video;
  }

  function attachStreamTrack(track, container) {
    const video = makeVideoElement(container);
    video.srcObject = new MediaStream([track]);
    video.play().catch(() => {});
    return video;
  }

  function getTrackAttachment(session, trackId) {
    return session.attachments.get(String(trackId));
  }

  const bridge = {
    // Version of the Dart/JS contract, independent of the pub release number.
    bridgeVersion: 1,
    async createLocalPreview(providerId, previewId, serializedArgs) {
      const args = parsePayload(serializedArgs || '{}') || {};
      if (sessions.has(previewId)) {
        throw new Error(`Duplicate local preview session ${previewId}.`);
      }
      let pipeline = null;
      let creatingPipeline = null;
      let effect = args.backgroundEffect || {
          type: 'none',
          blurStrength: 'medium',
        };
      let cameraId = args.cameraId || null;
      const preview = {
        id: previewId,
        providerId,
        payload: {},
        role: String(args.role || 'participant'),
        localParticipantId: `preview:${previewId}`,
        localMuted: !Boolean(args.microphoneEnabled),
        localVideoEnabled: args.cameraEnabled === true,
        joined: true,
        participants: new Map(),
        tracks: new Map(),
        attachments: new Map(),
        timers: new Set(),
        screenTrack: null,
      };
      const trackId = `preview:video:${previewId}`;
      addParticipant(
        preview,
        preview.localParticipantId,
        'Local preview',
        true,
      );
      async function ensurePipeline() {
        if (pipeline) return pipeline;
        if (creatingPipeline) return creatingPipeline;
        creatingPipeline = (async () => {
          const created = await createSdkProcessedVideo({ effect, deviceId: cameraId });
          if (!preview.joined) {
            await created.stop();
            throw new Error('Local preview was disposed while enabling the camera.');
          }
          pipeline = created;
          addVideoTrack(preview, {
            id: trackId, participantId: preview.localParticipantId,
            isLocal: true, native: { mediaStreamTrack: pipeline.track },
          });
          return pipeline;
        })();
        try { return await creatingPipeline; }
        finally { creatingPipeline = null; }
      }
      if (preview.localVideoEnabled) {
        await (await ensurePipeline()).setEnabled(true);
      }
      preview.driver = {
        async command(name, commandArgs) {
          if (name === 'setMuted') {
            preview.localMuted = Boolean(commandArgs.muted);
            return;
          }
          if (name === 'setVideoEnabled') {
            const enabled = Boolean(commandArgs.enabled);
            const capture = enabled ? await ensurePipeline() : pipeline;
            if (capture) await capture.setEnabled(enabled);
            if (enabled && capture) addVideoTrack(preview, {id: trackId, participantId: preview.localParticipantId, isLocal: true, native: {mediaStreamTrack: capture.track}});
            else removeVideoTrack(preview, trackId);
            preview.localVideoEnabled = enabled;
            return;
          }
          if (name === 'setBackgroundEffect') {
            effect = {
              type: String(commandArgs.type || 'none'),
              blurStrength: String(commandArgs.blurStrength || 'medium'),
              imageBytes: commandArgs.imageBytes || null,
            };
            if (pipeline) await pipeline.setEffect(effect);
            return;
          }
          if (name === 'selectDevice') {
            const selected = commandArgs.device || commandArgs;
            if (selected.kind === 'camera') {
              cameraId = selected.id;
              if (pipeline) await pipeline.setCameraDevice(cameraId);
            }
            return;
          }
          if (name === 'listDevices') return listDevices(preview);
          throw new Error(`Local preview does not support ${name}.`);
        },
        async attachVideo(track, container) {
          const mediaTrack = track.native?.mediaStreamTrack;
          if (mediaTrack) attachStreamTrack(mediaTrack, container);
        },
        detachVideo(_track, container) {
          container.replaceChildren();
        },
        async leave() {
          preview.joined = false;
          if (pipeline) await pipeline.stop();
        },
      };
      sessions.set(previewId, preview);
    },


    async create(providerId, sessionId, serializedPayload) {
      const payload = parsePayload(serializedPayload);
      const session = createSession(providerId, sessionId, payload);
      session.driver = session.driver || {};
      sessions.set(sessionId, session);
    },

    async join(providerId, sessionId) {
      const session = requireSession(providerId, sessionId);
      await join(session);
    },

    async leave(providerId, sessionId) {
      const session = sessions.get(sessionId);
      if (session && session.providerId === providerId) await leave(session);
    },

    async dispose(providerId, sessionId) {
      const session = sessions.get(sessionId);
      if (session && session.providerId === providerId) await dispose(session);
    },

    async command(providerId, sessionId, name, serializedArgs) {
      const session = requireSession(providerId, sessionId);
      const result = await command(session, name, parsePayload(serializedArgs));
      return typeof result === 'string' ? result : JSON.stringify(result || {});
    },

    async attachVideo(providerId, sessionId, trackId, elementId) {
      const container = document.getElementById(elementId);
      if (container) await this.attachVideoElement(providerId, sessionId, trackId, container);
    },

    async attachVideoElement(providerId, sessionId, trackId, container) {
      const session = requireSession(providerId, sessionId);
      const track = session.tracks.get(String(trackId));
      if (!track || !container) return;
      session.attachments.set(track.id, { elementId: container.id, container });
      await session.driver.attachVideo(track, container);
    },

    detachVideo(providerId, sessionId, trackId, elementId) {
      const session = sessions.get(sessionId);
      if (!session || session.providerId !== providerId) return;
      const track = session.tracks.get(String(trackId));
      const attachment = session.attachments.get(String(trackId));
      if (track && attachment && attachment.elementId === elementId && session.driver.detachVideo) {
        session.driver.detachVideo(track, attachment.container);
      }
      session.attachments.delete(String(trackId));
    },
  };

  function requireSession(providerId, sessionId) {
    const session = sessions.get(sessionId);
    if (!session || session.providerId !== providerId) throw new Error(`Unknown ${providerId} session ${sessionId}.`);
    return session;
  }


  global.MediaProviderBridge = bridge;
})(globalThis);
