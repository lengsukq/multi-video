export function createAgoraSession(session, context) {
  const { global, StageEvents, createSdkProcessedVideo, parsePayload, providerBlock, emit, emitState, addParticipant, removeParticipant, addVideoTrack, removeVideoTrack, emitMessage, publishSnapshot, reportError, createSession, join, leave, dispose, startStats, stopStats, effectsTrack, command, listDevices, makeVideoElement, attachStreamTrack, getTrackAttachment, requireSession } = context;
    const info = providerBlock(session, 'agora');
    const live = session.role !== 'participant';
    const client = AgoraRTC.createClient({ mode: live ? 'live' : 'rtc', codec: 'vp8' });
    const screenShareTopic = '_flutter_realtime.screen_share.v1';
    let screenShareSignalTimer = null;

    function encodeUtf8(text) {
      if (typeof global.TextEncoder === 'function') {
        return new global.TextEncoder().encode(text);
      }
      if (typeof TextEncoder === 'function') {
        return new TextEncoder().encode(text);
      }
      const escaped = unescape(encodeURIComponent(text));
      const bytes = new Uint8Array(escaped.length);
      for (let i = 0; i < escaped.length; i += 1) {
        bytes[i] = escaped.charCodeAt(i);
      }
      return bytes;
    }

    const stopScreenShareSignalTimer = () => {
      if (screenShareSignalTimer !== null) {
        global.clearInterval?.(screenShareSignalTimer);
        screenShareSignalTimer = null;
      }
    };

    const sendStreamEnvelope = async (topic, message) => {
      if (typeof client.sendStreamMessage !== 'function') return;
      const wire = JSON.stringify({
        version: 1,
        topic,
        message,
        timestampMs: Date.now(),
      });
      await client.sendStreamMessage(encodeUtf8(wire), false);
    };

    const sendScreenShareSignal = (state) => {
      Promise.resolve(sendStreamEnvelope(screenShareTopic, state)).catch(() => {});
    };

    const startScreenShareSignalTimer = () => {
      stopScreenShareSignalTimer();
      sendScreenShareSignal('started');
      if (typeof global.setInterval === 'function') {
        screenShareSignalTimer = global.setInterval(() => {
          if (localTracks.screen) sendScreenShareSignal('started');
          else stopScreenShareSignalTimer();
        }, 2000);
      }
    };

    const localTracks = {
      audio: null,
      video: null,
      screen: null,
      pipeline: null,
      videoTrackId: `agora:video:${session.localParticipantId}`,
      videoPublished: false,
    };
    let selectedCameraId = null;
    let backgroundEffect = { type: 'none', blurStrength: 'medium' };
    let processedSourceId = null;
    let providerInputTrack = null;
    const remoteUsers = new Map();
    const remoteScreenUids = new Set();
    const processedTrackForSource = (sourceId) => {
      const effectsBridge = global.RealtimeProcessedVideoBridge;
      if (!effectsBridge?.getTrack) {
        throw new Error('RealtimeProcessedVideoBridge is unavailable.');
      }
      const mediaStreamTrack = effectsBridge.getTrack(sourceId);
      if (!mediaStreamTrack) {
        throw new Error(
          `Processed video source ${sourceId} has no MediaStreamTrack.`,
        );
      }
      return mediaStreamTrack;
    };
    const ensureVideoTrack = async () => {
      if (processedSourceId) {
        if (!localTracks.video) {
          const sourceTrack = processedTrackForSource(processedSourceId);
          providerInputTrack = sourceTrack.clone?.() || sourceTrack;
          localTracks.video = AgoraRTC.createCustomVideoTrack({mediaStreamTrack: providerInputTrack});
        }
        return localTracks.video;
      }
      if (backgroundEffect.type === 'none' && !localTracks.pipeline) {
        localTracks.video ??= await AgoraRTC.createCameraVideoTrack(
          selectedCameraId ? {cameraId: selectedCameraId} : {},
        );
        return localTracks.video;
      }
      if (!localTracks.pipeline) {
        localTracks.pipeline = await createSdkProcessedVideo({
          effect: backgroundEffect,
          deviceId: selectedCameraId,
        });
      } else {
        await localTracks.pipeline.setEffect(backgroundEffect);
      }
      if (!localTracks.video) {
        localTracks.video = AgoraRTC.createCustomVideoTrack({
          mediaStreamTrack: localTracks.pipeline.track,
        });
      }
      return localTracks.video;
    };
    const publishCameraIfNeeded = async () => {
      if (localTracks.screen || localTracks.videoPublished || !session.localVideoEnabled) return;
      const videoTrack = await ensureVideoTrack();
      if (processedSourceId) {
        await global.RealtimeProcessedVideoBridge.setEnabled(processedSourceId, true);
        providerInputTrack.enabled = true;
      } else {
        await localTracks.pipeline?.setEnabled(true);
      }
      await client.publish(videoTrack);
      localTracks.videoPublished = true;
      addVideoTrack(session, {
        id: localTracks.videoTrackId,
        participantId: session.localParticipantId,
        isLocal: true,
        native: { track: videoTrack },
      });
    };
    const unpublishCameraIfNeeded = async () => {
      if (localTracks.videoPublished && localTracks.video) {
        await client.unpublish(localTracks.video);
      }
      localTracks.videoPublished = false;
      if (providerInputTrack) providerInputTrack.enabled = false;
      if (!processedSourceId) {
        await localTracks.pipeline?.setEnabled(false);
        if (!localTracks.pipeline) {
          localTracks.video?.close?.();
          localTracks.video = null;
        }
      }
      removeVideoTrack(session, localTracks.videoTrackId);
    };
    const updateRemote = async (user, mediaType) => {
      const participantId = String(user.uid);
      const participant = addParticipant(session, participantId);
      if (mediaType === 'audio' && user.audioTrack) user.audioTrack.play();
      if (mediaType === 'video' && user.videoTrack) {
        const screenShare = remoteScreenUids.has(participantId);
        const trackId = `agora:${screenShare ? 'screen' : 'video'}:${participantId}`;
        const formerId = `agora:${screenShare ? 'video' : 'screen'}:${participantId}`;
        remoteUsers.delete(formerId);
        removeVideoTrack(session, formerId);
        const remote = { user, track: user.videoTrack };
        remoteUsers.set(trackId, remote);
        addVideoTrack(session, {
          id: trackId, participantId,
          isScreenShare: screenShare, native: remote,
        });
        const attachment = getTrackAttachment(session, trackId);
        if (attachment) {
          const fit = attachment.container?.dataset?.videoFit === 'cover' ? 'cover' : 'contain';
          user.videoTrack.play(attachment.container, { fit });
        }
      }
      participant.isMuted = !user.audioTrack;
      publishSnapshot(session);
    };
    client.on('user-joined', (user) => {
      addParticipant(session, user.uid);
      publishSnapshot(session);
      if (localTracks.screen) sendScreenShareSignal('started');
    });
    client.on('user-left', (user) => {
      remoteScreenUids.delete(String(user.uid));
      removeParticipant(session, user.uid);
    });
    client.on('stream-message', (uid, payload) => {
      try {
        const message = JSON.parse(new TextDecoder().decode(payload));
        if (message?.topic === screenShareTopic) {
          if (!['started', 'stopped'].includes(message.message)) return;
          const key = String(uid);
          if (message.message === 'started') remoteScreenUids.add(key);
          else remoteScreenUids.delete(key);
          const remote = client.remoteUsers?.find(user => String(user.uid) === key);
          if (remote?.videoTrack) updateRemote(remote, 'video').catch(
            (error) => reportError(session, error),
          );
          return;
        }
        if (
          typeof message?.message === 'string' &&
          typeof message?.topic === 'string' &&
          message.topic.trim().length > 0
        ) {
          const key = String(uid);
          const participant = session.participants.get(key);
          emitMessage(session, {
            participantId: key,
            displayName: participant?.displayName || key,
            message: message.message,
            topic: message.topic.trim(),
            timestampMs: Number(message.timestampMs || Date.now()),
          });
        }
      } catch (_) {
        // Another SDK's unrelated data stream must not break media.
      }
    });
    client.on('user-published', async (user, type) => {
      try {
        await client.subscribe(user, type);
        await updateRemote(user, type);
      } catch (error) { reportError(session, error); }
    });
    client.on('user-unpublished', (user, type) => {
      if (type === 'video') {
        remoteUsers.delete(`agora:video:${user.uid}`);
        remoteUsers.delete(`agora:screen:${user.uid}`);
        removeVideoTrack(session, `agora:video:${user.uid}`);
        removeVideoTrack(session, `agora:screen:${user.uid}`);
      }
      if (type === 'audio') {
        const participant = session.participants.get(String(user.uid));
        if (participant) participant.isMuted = true;
        publishSnapshot(session);
      }
    });
    client.on('connection-state-change', (current) => {
      if (current === 'RECONNECTING') emitState(session, 'reconnecting');
      if (current === 'CONNECTED') emitState(session, 'connected');
    });
    session.driver = {
      async join() {
        if (live) await client.setClientRole(session.role === 'viewer' ? 'audience' : 'host');
        await client.join(info.appId, info.channelName, info.token, Number(info.uid));
        // RTC joining must not prompt for microphone permission. Pre-Join
        // defaults both devices to off; explicit unmute controls acquisition.
        session.localMuted = true;
        session.localVideoEnabled = false;
      },
      async command(name, args) {
        if (name === 'setMuted') {
          const muted = Boolean(args.muted);
          if (!muted && session.role === 'viewer') {
            throw new Error('Agora viewers cannot publish microphone audio.');
          }
          if (!muted && !localTracks.audio) {
            const audio = await AgoraRTC.createMicrophoneAudioTrack();
            try {
              await client.publish(audio);
              localTracks.audio = audio;
            } catch (error) {
              audio.close?.();
              throw error;
            }
          } else if (localTracks.audio) {
            await localTracks.audio.setEnabled(!muted);
          }
          session.localMuted = muted;
          return;
        }
        if (name === 'attachProcessedVideoSource') {
          const sourceId = String(args.sourceId || '');
          if (!sourceId) throw new Error('Processed video sourceId is required.');
          processedTrackForSource(sourceId);
          await unpublishCameraIfNeeded();
          localTracks.video?.close?.();
          providerInputTrack?.stop?.(); providerInputTrack = null;
          localTracks.video = null;
          localTracks.pipeline?.stop?.();
          localTracks.pipeline = null;
          processedSourceId = sourceId;
          session.processedSourceId = sourceId;
          if (session.localVideoEnabled) await publishCameraIfNeeded();
          return;
        }
        if (name === 'detachProcessedVideoSource') {
          await unpublishCameraIfNeeded();
          localTracks.video?.close?.();
          providerInputTrack?.stop?.(); providerInputTrack = null;
          localTracks.video = null;
          processedSourceId = null;
          session.processedSourceId = null;
          return;
        }
        if (name === 'setProcessedVideoEffect') {
          if (!processedSourceId) {
            throw new Error('No SDK processed video source is attached.');
          }
          const effectsBridge = global.RealtimeVideoEffectsBridge;
          if (!effectsBridge?.setEffect) {
            throw new Error('RealtimeProcessedVideoBridge is unavailable.');
          }
          await effectsBridge.setEffect(
            processedSourceId,
            JSON.stringify({
              type: String(args.type || 'none'),
              blurStrength: String(args.blurStrength || 'medium'),
              imageBytes: args.imageBytes || null,
            }),
          );
          return;
        }
        if (name === 'setVideoEnabled') {
          const enabled = Boolean(args.enabled);
          const previous = session.localVideoEnabled;
          session.localVideoEnabled = enabled;
          try {
            if (enabled) await publishCameraIfNeeded();
            else await unpublishCameraIfNeeded();
          } catch (error) {
            session.localVideoEnabled = previous;
            if (enabled && !processedSourceId && !localTracks.pipeline) {
              localTracks.video?.close?.();
              localTracks.video = null;
            }
            throw error;
          }
          return;
        }
        if (name === 'setBackgroundEffect') {
          const type = String(args.type || 'none');
          if (!['none', 'blur', 'replaceImage'].includes(type)) {
            throw new Error(`Unsupported SDK background effect: ${type}`);
          }
          if (type === 'blur' && !global.SdkVideoEffectsVision?.ImageSegmenter) {
            throw new Error('SDK MediaPipe background processor is unavailable.');
          }
          backgroundEffect = {
            type,
            blurStrength: String(args.blurStrength || 'medium'),
            imageBytes: args.imageBytes || null,
          };
          if (localTracks.pipeline) {
            await localTracks.pipeline.setEffect(backgroundEffect);
          } else if (type !== 'none' && localTracks.video) {
            await unpublishCameraIfNeeded();
            await publishCameraIfNeeded();
          }
          return;
        }
        if (name === 'setScreenShareEnabled') {
          if (args.enabled && !localTracks.screen) {
            // Ask for browser consent *before* disrupting a healthy camera
            // stream. Cancelling the picker must leave camera publish intact.
            const screen = await AgoraRTC.createScreenVideoTrack({ encoderConfig: '1080p_1' }, 'disable');
            await unpublishCameraIfNeeded();
            try {
              await client.publish(screen);
              localTracks.screen = screen;
            } catch (error) {
              screen.close();
              await publishCameraIfNeeded();
              throw error;
            }
            addVideoTrack(session, { id: 'agora:screen:local', participantId: session.localParticipantId, isLocal: true, isScreenShare: true, native: { track: localTracks.screen } });
            startScreenShareSignalTimer();
            localTracks.screen.on('track-ended', () => this.command('setScreenShareEnabled', { enabled: false }).catch(() => {}));
          } else if (!args.enabled && localTracks.screen) {
            stopScreenShareSignalTimer();
            sendScreenShareSignal('stopped');
            await client.unpublish(localTracks.screen);
            localTracks.screen.close();
            localTracks.screen = null;
            removeVideoTrack(session, 'agora:screen:local');
            await publishCameraIfNeeded();
          }
          return;
        }
        if (name === 'sendMessage') {
          const topic = String(args.topic || 'chat').trim() || 'chat';
          const message = String(args.message || '');
          if (!message) throw new Error('Agora data message requires a non-empty message.');
          if (typeof client.sendStreamMessage !== 'function') {
            throw new Error('Agora Web client does not support stream messages in this session.');
          }
          await sendStreamEnvelope(topic, message);
          return;
        }
        if (name === 'selectDevice' || name === 'selectAudioOutput') {
          const selected = args.device || args;
          if (selected.kind === 'microphone' && localTracks.audio) await localTracks.audio.setDevice(selected.id);
          if (selected.kind === 'camera') {
            if (processedSourceId) {
              await global.RealtimeProcessedVideoBridge?.selectCamera?.(
                processedSourceId,
                selected.id,
              );
              return;
            }
            selectedCameraId = selected.id;
            if (localTracks.pipeline) {
              await localTracks.pipeline.setCameraDevice(selected.id);
            } else if (localTracks.video) {
              await localTracks.video.setDevice(selected.id);
            }
          }
          if (selected.kind === 'audioOutput') {
            for (const user of client.remoteUsers || []) if (user.audioTrack?.setPlaybackDevice) await user.audioTrack.setPlaybackDevice(selected.id);
          }
          return;
        }
        if (name === 'switchCamera') {
          const cameras = await AgoraRTC.getCameras();
          const index = cameras.findIndex(
            (device) => device.deviceId === selectedCameraId,
          );
          const next = cameras[(index + 1) % cameras.length];
          if (next) {
            selectedCameraId = next.deviceId;
            if (localTracks.pipeline) {
              await localTracks.pipeline.setCameraDevice(next.deviceId);
            } else if (localTracks.video) {
              await localTracks.video.setDevice(next.deviceId);
            }
          }
          return;
        }
        if (name === 'listDevices') return listDevices(session);
        throw new Error(`Agora does not support ${name}.`);
      },
      async attachVideo(track, container) {
        const native = track.native?.track || remoteUsers.get(track.id)?.track;
        const fit = container?.dataset?.videoFit === 'cover' ? 'cover' : 'contain';
        if (native?.play) native.play(container, { fit });
      },
      detachVideo(track, container) {
        const native = track.native?.track || remoteUsers.get(track.id)?.track;
        if (native?.stop) native.stop();
        container.replaceChildren();
      },
      async leave() {
        stopScreenShareSignalTimer();
        if (localTracks.screen) sendScreenShareSignal('stopped');
        for (const track of [localTracks.screen, localTracks.video, localTracks.audio]) {
          if (track?.close) track.close();
        }
        localTracks.screen = null;
        localTracks.video = null;
        localTracks.audio = null;
        providerInputTrack?.stop?.(); providerInputTrack = null;
        localTracks.pipeline?.stop();
        localTracks.pipeline = null;
        processedSourceId = null;
        localTracks.videoPublished = false;
        await client.leave();
      },
      async dispose() {
        stopScreenShareSignalTimer();
        client.removeAllListeners?.();
      },
      async getStats() {
        const stats = client.getRTCStats?.();
        return stats ? { rttMs: Math.round(stats.RTT || 0), uploadKbps: Math.round((stats.SendBitrate || 0) / 1000), downloadKbps: Math.round((stats.RecvBitrate || 0) / 1000) } : null;
      },
    };
    return session;
  }
