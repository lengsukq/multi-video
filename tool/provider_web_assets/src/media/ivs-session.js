export function createIvsSession(session, context) {
  const { global, StageEvents, createSdkProcessedVideo, parsePayload, providerBlock, emit, emitState, addParticipant, removeParticipant, addVideoTrack, removeVideoTrack, emitMessage, publishSnapshot, reportError, createSession, join, leave, dispose, startStats, stopStats, effectsTrack, command, listDevices, makeVideoElement, attachStreamTrack, getTrackAttachment, requireSession } = context;
    const info = providerBlock(session, 'ivs');
    const sdk = global.IVSBroadcastClient;
    if (!sdk?.Stage || !sdk?.LocalStageStream) {
      throw new Error('Amazon IVS Web Broadcast SDK is unavailable in this browser build.');
    }
    const canPublish = session.role !== 'viewer' && info.capabilities?.includes('PUBLISH');
    const localStreams = [];
    const remoteStreams = new Map();
    let selectedMicrophoneId = null;
    let selectedCameraId = null;
    const createLocalStream = async (kind, deviceId) => {
      if (!canPublish) throw new Error('IVS credentials do not permit publishing media.');
      if (!navigator.mediaDevices?.getUserMedia) {
        throw new Error('This browser cannot access camera or microphone media devices.');
      }
      const option = deviceId ? { deviceId: { exact: deviceId } } : true;
      const media = await navigator.mediaDevices.getUserMedia(
        kind === 'audio' ? { audio: option, video: false } : { audio: false, video: option },
      );
      const tracks = media.getTracks();
      const track = tracks.find(item => item.kind === kind);
      for (const extra of tracks) if (extra !== track) extra.stop();
      if (!track) throw new Error(`No IVS ${kind} device track was returned.`);
      try { return new sdk.LocalStageStream(track); }
      catch (error) { track.stop(); throw error; }
    };
    const replacePublishedStream = (old, replacement) => {
      const oldIndex = localStreams.indexOf(old);
      if (oldIndex >= 0) localStreams.splice(oldIndex, 1, replacement);
      else localStreams.push(replacement);
      try { stage.refreshStrategy(); }
      catch (error) {
        const replacementIndex = localStreams.indexOf(replacement);
        if (replacementIndex >= 0) localStreams.splice(replacementIndex, 1);
        if (oldIndex >= 0) localStreams.splice(oldIndex, 0, old);
        replacement.mediaStreamTrack.stop();
        throw error;
      }
      old?.mediaStreamTrack.stop();
    };
    const remoteAudioStreams = new Set();
    const releaseRemoteAudio = (stream) => {
      if (stream.__audioRetry) {
        global.document.removeEventListener('pointerdown', stream.__audioRetry);
        stream.__audioRetry = null;
      }
      const audio = stream.__audioElement;
      if (audio) {
        audio.pause?.();
        audio.srcObject = null;
        audio.remove();
        stream.__audioElement = null;
      }
      remoteAudioStreams.delete(stream);
    };
    const stage = new sdk.Stage(info.token, {
      stageStreamsToPublish: () => localStreams,
      shouldPublishParticipant: () => Boolean(canPublish),
      shouldSubscribeToParticipant: (participant) => participant.capabilities?.has('subscribe') ? sdk.SubscribeType.AUDIO_VIDEO : sdk.SubscribeType.NONE,
    });
    stage.on(StageEvents.CONNECTION, (state) => {
      if (state === sdk.StageConnectionState.CONNECTED) emitState(session, 'connected');
      else if (state === sdk.StageConnectionState.CONNECTING) emitState(session, 'connecting');
      else if (state === sdk.StageConnectionState.DISCONNECTED) emitState(session, 'disconnected');
    });
    stage.on(StageEvents.JOINED, (participant) => { addParticipant(session, participant.userId || participant.id, participant.userInfo?.displayName, participant.isLocal); publishSnapshot(session); });
    stage.on(StageEvents.LEFT, (participant) => {
      const participantId = String(participant.userId || participant.id);
      // Be resilient to an SDK which emits LEFT before STREAMS_REMOVED.
      for (const stream of [...remoteAudioStreams]) {
        if (stream.__participantId === participantId) releaseRemoteAudio(stream);
      }
      removeParticipant(session, participantId);
    });
    stage.on(StageEvents.STREAMS_ADDED, (participant, streams) => {
      const participantId = String(participant.userId || participant.id);
      const member = addParticipant(session, participantId, participant.userInfo?.displayName, participant.isLocal);
      if (member && participant.isLocal) member.isMuted = session.localMuted;
      for (const stream of streams) {
        if (stream.streamType !== sdk.StreamType.VIDEO) continue;
        remoteStreams.set(stream.id, stream);
        addVideoTrack(session, { id: `ivs:${participantId}:${stream.id}`, participantId, isLocal: participant.isLocal, native: stream });
      }
      for (const stream of streams) {
        if (stream.streamType === sdk.StreamType.AUDIO && !participant.isLocal) {
          if (member) {
            member.isMuted = typeof stream.isMuted === 'boolean'
              ? stream.isMuted : Boolean(participant.audioMuted);
            publishSnapshot(session);
          }
          if (stream.__audioElement) continue;
          const audio = document.createElement('audio');
          audio.autoplay = true;
          audio.srcObject = new MediaStream([stream.mediaStreamTrack]);
          document.body.append(audio);
          stream.__audioElement = audio;
          stream.__participantId = participantId;
          remoteAudioStreams.add(stream);
          audio.play().catch((error) => {
            if (stream.__audioElement !== audio) return;
            // Browser autoplay permission is separate from a successfully
            // subscribed remote IVS audio track. Do not silently lose sound.
            reportError(session, new Error(`IVS remote audio playback blocked: ${error.message}. Tap the page to allow sound.`));
            const retry = () => {
              stream.__audioRetry = null;
              audio.play().catch((retryError) => reportError(session, retryError));
            };
            stream.__audioRetry = retry;
            global.document.addEventListener('pointerdown', retry, { once: true });
          });
        }
      }
    });
    stage.on(StageEvents.STREAM_MUTE_CHANGED, (participant, stream) => {
      const participantId = String(participant.userId || participant.id || '');
      if (!participantId) return;
      const current = session.participants.get(participantId);
      if (!current) return;
      if (stream.streamType === sdk.StreamType.AUDIO) {
        current.isMuted = Boolean(stream.isMuted);
        if (participant.isLocal) session.localMuted = current.isMuted;
        publishSnapshot(session);
      } else if (stream.streamType === sdk.StreamType.VIDEO && !participant.isLocal) {
        current.isVideoEnabled = !stream.isMuted;
        publishSnapshot(session);
      }
    });
    stage.on(StageEvents.STREAMS_REMOVED, (_participant, streams) => {
      for (const stream of streams) {
        removeVideoTrack(session, [...session.tracks.values()].find((track) => track.native === stream)?.id);
        releaseRemoteAudio(stream);
        remoteStreams.delete(stream.id);
      }
    });
    stage.on(StageEvents.ERROR, (error) => reportError(session, error));
    session.localStreams = localStreams;
    session.stage = stage;
    session.driver = {
      async join() {
        // An IVS publisher may join with an empty stageStreamsToPublish list.
        // Defer the browser permission prompt until microphone/camera enable.
        session.localMuted = true;
        session.localVideoEnabled = false;
        await stage.join();
      },
      async command(name, args) {
        if (name === 'setMuted') {
          const muted = Boolean(args.muted);
          if (!muted && !session.localAudioStream) {
            const replacement = await createLocalStream('audio', selectedMicrophoneId);
            try {
              replacement.setMuted(false);
              replacePublishedStream(null, replacement);
            } catch (error) {
              replacement.mediaStreamTrack.stop();
              throw error;
            }
            session.localAudioStream = replacement;
          } else {
            session.localAudioStream?.setMuted(muted);
          }
          session.localMuted = muted;
          return;
        }
        if (name === 'setVideoEnabled') {
          const enabled = Boolean(args.enabled);
          if (enabled && !session.localVideoStream) {
            const replacement = await createLocalStream('video', selectedCameraId);
            try {
              replacement.setMuted(false);
              if (session.screenTrack) {
                session.screenPausedCamera = replacement;
              } else {
                replacePublishedStream(null, replacement);
                addVideoTrack(session, { id: `ivs:local:${replacement.id}`, participantId: session.localParticipantId, isLocal: true, native: replacement });
              }
            } catch (error) {
              replacement.mediaStreamTrack.stop();
              throw error;
            }
            session.localVideoStream = replacement;
          } else {
            session.localVideoStream?.setMuted(!enabled);
          }
          session.localVideoEnabled = enabled;
          return;
        }
        if (name === 'setScreenShareEnabled') {
          if (args.enabled && !session.screenTrack) {
            // IVS needs a second Stage token for a simultaneous screen and
            // camera video. In a single-token Demo, switch the video source.
            const media = await navigator.mediaDevices.getDisplayMedia({
              video: { width: { max: 1280 }, height: { max: 720 } },
            });
            const track = media.getVideoTracks()[0];
            if (!track) throw new Error('Browser screen capture provided no video track.');
            let localStream;
            try { localStream = new sdk.LocalStageStream(track); }
            catch (error) { track.stop(); throw error; }
            const pausedCamera = session.localVideoStream;
            const cameraIndex = localStreams.indexOf(pausedCamera);
            if (cameraIndex >= 0) localStreams.splice(cameraIndex, 1);
            session.screenPausedCamera = cameraIndex >= 0 ? pausedCamera : null;
            if (cameraIndex >= 0) {
              removeVideoTrack(session, [...session.tracks.values()].find(
                item => item.native === pausedCamera,
              )?.id);
            }
            localStreams.push(localStream);
            session.screenTrack = localStream;
            try { stage.refreshStrategy(); }
            catch (error) {
              localStreams.splice(localStreams.indexOf(localStream), 1);
              session.screenTrack = null;
              if (session.screenPausedCamera) {
                localStreams.push(session.screenPausedCamera);
                const camera = session.screenPausedCamera;
                addVideoTrack(session, {
                  id: `ivs:local:${camera.mediaStreamTrack.id}`,
                  participantId: session.localParticipantId,
                  isLocal: true, native: camera,
                });
                session.screenPausedCamera = null;
                stage.refreshStrategy();
              }
              track.stop();
              throw error;
            }
            addVideoTrack(session, { id: `ivs:screen:${track.id}`, participantId: session.localParticipantId, isLocal: true, isScreenShare: true, native: localStream });
            track.addEventListener('ended', () => this.command('setScreenShareEnabled', { enabled: false }).catch(() => {}), { once: true });
          } else if (!args.enabled && session.screenTrack) {
            const track = session.screenTrack.mediaStreamTrack;
            track.stop();
            const index = localStreams.indexOf(session.screenTrack);
            if (index >= 0) localStreams.splice(index, 1);
            removeVideoTrack(session, [...session.tracks.values()].find((item) => item.native === session.screenTrack)?.id);
            session.screenTrack = null;
            if (session.screenPausedCamera) {
              const camera = session.screenPausedCamera;
              session.screenPausedCamera = null;
              localStreams.push(camera);
              addVideoTrack(session, {
                id: `ivs:local:${camera.mediaStreamTrack.id}`,
                participantId: session.localParticipantId,
                isLocal: true, native: camera,
              });
            }
            stage.refreshStrategy();
          }
          return;
        }
        if (name === 'switchCamera') return;
        if (name === 'selectDevice') {
          const selected = args.device || args;
          if (selected.kind !== 'camera' && selected.kind !== 'microphone') return;
          if (!selected.id) throw new Error('IVS media device id is required.');
          const old = selected.kind === 'camera' ? session.localVideoStream : session.localAudioStream;
          if (selected.kind === 'microphone') selectedMicrophoneId = selected.id;
          else selectedCameraId = selected.id;
          // Choosing a device in Pre-Join must not activate its permission.
          if (!old) return;
          const replacement = await createLocalStream(selected.kind === 'camera' ? 'video' : 'audio', selected.id);
          try {
            replacement.setMuted(selected.kind === 'camera' ? !session.localVideoEnabled : session.localMuted);
            if (selected.kind === 'camera' && session.screenTrack) {
              session.screenPausedCamera = replacement;
              old.mediaStreamTrack.stop();
            } else {
              replacePublishedStream(old, replacement);
            }
          } catch (error) {
            replacement.mediaStreamTrack.stop();
            throw error;
          }
          if (selected.kind === 'camera') {
            session.localVideoStream = replacement;
            if (old) removeVideoTrack(session, [...session.tracks.values()].find((item) => item.native === old)?.id);
            if (session.screenTrack) {
              // A camera switch during a share changes what will be restored,
              // not the sole video stream currently published to IVS.
              session.screenPausedCamera = replacement;
              return;
            }
            addVideoTrack(session, { id: `ivs:local:${replacement.id}`, participantId: session.localParticipantId, isLocal: true, native: replacement });
          } else {
            session.localAudioStream = replacement;
          }
          return;
        }
        if (name === 'listDevices') return listDevices(session);
        throw new Error(`IVS Real-Time does not support ${name}.`);
      },
      async attachProcessedTrack(track) {
        const old = session.localVideoStream;
        const replacement = new sdk.LocalStageStream(track);
        replacement.setMuted(!session.localVideoEnabled);
        if (old) {
          const index = localStreams.indexOf(old);
          if (index >= 0) localStreams.splice(index, 1);
          removeVideoTrack(session, [...session.tracks.values()].find((item) => item.native === old)?.id);
        }
        session.localVideoStream = replacement;
        if (session.screenTrack) {
          session.screenPausedCamera = replacement;
          return;
        }
        localStreams.push(replacement);
        addVideoTrack(session, {id: `ivs:local:${track.id}`, participantId: session.localParticipantId, isLocal: true, native: replacement});
        stage.refreshStrategy();
      },
      async detachProcessedTrack() {
        const old = session.localVideoStream;
        if (old) {
          const index = localStreams.indexOf(old);
          if (index >= 0) localStreams.splice(index, 1);
          removeVideoTrack(session, [...session.tracks.values()].find((item) => item.native === old)?.id);
        }
        session.localVideoStream = null;
        if (session.screenTrack) session.screenPausedCamera = null;
        stage.refreshStrategy();
      },
      async attachVideo(track, container) { attachStreamTrack(track.native.mediaStreamTrack, container); },
      detachVideo(_track, container) { container.replaceChildren(); },
      async leave() {
        // Some browser SDK versions do not emit per-stream removal callbacks
        // after a local Stage.leave(); release HTMLAudioElements explicitly.
        // Stage.leave() is asynchronous. Do not stop tracks while its network
        // teardown is still in flight, and release every source even if leave
        // rejects (otherwise the microphone/camera may keep running).
        try {
          await stage.leave();
        } finally {
          for (const stream of [...remoteAudioStreams]) releaseRemoteAudio(stream);
          remoteStreams.clear();
          for (const stream of [...localStreams]) stream.mediaStreamTrack.stop();
          if (session.screenPausedCamera &&
              !localStreams.includes(session.screenPausedCamera)) {
            session.screenPausedCamera.mediaStreamTrack.stop();
          }
          session.screenPausedCamera = null;
          localStreams.length = 0;
        }
      },
      async dispose() {
        for (const stream of [...remoteAudioStreams]) releaseRemoteAudio(stream);
        remoteStreams.clear();
        stage.removeAllListeners?.();
      },
      async getStats() {
        const stats = await Promise.all(localStreams.map((stream) => stream.requestQualityStats?.()));
        const values = stats.flat().filter(Boolean);
        if (!values.length) return null;
        const loss = values.map((item) => item.packetsLost && item.packetsSent ? (item.packetsLost / item.packetsSent) * 100 : 0).reduce((a, b) => a + b, 0) / values.length;
        return { uplinkPacketLossPercent: loss };
      },
    };
    return session;
  }
