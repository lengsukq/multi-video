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
    stage.on(StageEvents.LEFT, (participant) => removeParticipant(session, participant.userId || participant.id));
    stage.on(StageEvents.STREAMS_ADDED, (participant, streams) => {
      const participantId = String(participant.userId || participant.id);
      addParticipant(session, participantId, participant.userInfo?.displayName, participant.isLocal);
      for (const stream of streams) {
        if (stream.streamType !== sdk.StreamType.VIDEO) continue;
        remoteStreams.set(stream.id, stream);
        addVideoTrack(session, { id: `ivs:${participantId}:${stream.id}`, participantId, isLocal: participant.isLocal, native: stream });
      }
      for (const stream of streams) {
        if (stream.streamType === sdk.StreamType.AUDIO && !participant.isLocal) {
          const audio = document.createElement('audio');
          audio.autoplay = true;
          audio.srcObject = new MediaStream([stream.mediaStreamTrack]);
          document.body.append(audio);
          stream.__audioElement = audio;
          audio.play().catch((error) => {
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
    stage.on(StageEvents.STREAMS_REMOVED, (_participant, streams) => {
      for (const stream of streams) {
        removeVideoTrack(session, [...session.tracks.values()].find((track) => track.native === stream)?.id);
        if (stream.__audioRetry) global.document.removeEventListener('pointerdown', stream.__audioRetry);
        stream.__audioElement?.remove();
        stream.__audioRetry = null;
        remoteStreams.delete(stream.id);
      }
    });
    stage.on(StageEvents.ERROR, (error) => reportError(session, error));
    session.localStreams = localStreams;
    session.stage = stage;
    session.driver = {
      async join() {
        if (canPublish) {
          if (!navigator.mediaDevices?.getUserMedia) {
            throw new Error('This browser cannot access camera or microphone media devices.');
          }
          const media = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
          for (const track of media.getTracks()) {
            const localStream = new sdk.LocalStageStream(track);
            if (track.kind === 'audio') localStream.setMuted(true);
            localStreams.push(localStream);
            if (track.kind === 'video') {
              session.localVideoStream = localStream;
              session.localVideoEnabled = true;
              addVideoTrack(session, { id: `ivs:local:${track.id}`, participantId: session.localParticipantId, isLocal: true, native: localStream });
            } else session.localAudioStream = localStream;
          }
          session.localMuted = true;
        }
        await stage.join();
      },
      async command(name, args) {
        if (name === 'setMuted') {
          const muted = Boolean(args.muted);
          if (!session.localAudioStream && !muted) {
            throw new Error('No IVS microphone stream is available.');
          }
          session.localAudioStream?.setMuted(muted);
          session.localMuted = muted;
          return;
        }
        if (name === 'setVideoEnabled') {
          session.localVideoEnabled = Boolean(args.enabled);
          if (session.localVideoStream) session.localVideoStream.setMuted(!session.localVideoEnabled);
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
          const media = await navigator.mediaDevices.getUserMedia(selected.kind === 'camera' ? { video: { deviceId: { exact: selected.id } } } : { audio: { deviceId: { exact: selected.id } } });
          const track = media.getTracks()[0];
          const old = selected.kind === 'camera' ? session.localVideoStream : session.localAudioStream;
          if (old) {
            old.mediaStreamTrack.stop();
            const index = localStreams.indexOf(old);
            if (index >= 0) localStreams.splice(index, 1);
          }
          const replacement = new sdk.LocalStageStream(track);
          if (selected.kind === 'camera') {
            session.localVideoStream = replacement;
            if (old) removeVideoTrack(session, [...session.tracks.values()].find((item) => item.native === old)?.id);
            if (session.screenTrack) {
              // A camera switch during a share changes what will be restored,
              // not the sole video stream currently published to IVS.
              session.screenPausedCamera = replacement;
              return;
            }
            localStreams.push(replacement);
            addVideoTrack(session, { id: `ivs:local:${track.id}`, participantId: session.localParticipantId, isLocal: true, native: replacement });
          } else {
            // Switching input devices must not publish a muted participant
            // accidentally, nor silently mute an already-speaking one.
            replacement.setMuted(session.localMuted);
            session.localAudioStream = replacement;
            localStreams.push(replacement);
          }
          stage.refreshStrategy();
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
        stage.leave();
        for (const stream of [...localStreams]) stream.mediaStreamTrack.stop();
        if (session.screenPausedCamera &&
            !localStreams.includes(session.screenPausedCamera)) {
          session.screenPausedCamera.mediaStreamTrack.stop();
        }
        session.screenPausedCamera = null;
        localStreams.length = 0;
      },
      async dispose() { stage.removeAllListeners?.(); },
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
