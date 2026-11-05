export function createTrtcSession(session, context) {
  const { global, StageEvents, createSdkProcessedVideo, parsePayload, providerBlock, emit, emitState, addParticipant, removeParticipant, addVideoTrack, removeVideoTrack, emitMessage, publishSnapshot, reportError, createSession, join, leave, dispose, startStats, stopStats, effectsTrack, command, listDevices, makeVideoElement, attachStreamTrack, getTrackAttachment, requireSession } = context;
    const info = providerBlock(session, 'trtc');
    const sdk = global.TRTC;
    const trtc = sdk.create({ assetsPath: (globalThis.__realtimeTrtcAssetsPath || new URL('assets/packages/flutter_realtime_sdk/assets/provider_web_runtime/vendors/trtc-assets/', document.baseURI).toString()) });
    let audioStarted = false;
    let selectedMicrophoneId = null;
    const localVideoId = `trtc:video:${session.localParticipantId}`;
    const remoteTracks = new Map();
    const refreshLocalTrack = () => {
      const track = trtc.getVideoTrack?.();
      if (track) addVideoTrack(session, { id: localVideoId, participantId: session.localParticipantId, isLocal: true, native: track });
    };
    const events = sdk.EVENT || {};
    const attachRemote = (event) => {
      const userId = String(event.userId || '');
      if (!userId) return;
      addParticipant(session, userId);
      const streamType = event.streamType || sdk.TYPE?.STREAM_TYPE_MAIN || 'main';
      const trackId = `trtc:video:${userId}:${streamType}`;
      remoteTracks.set(trackId, { userId, streamType });
      addVideoTrack(session, { id: trackId, participantId: userId, isScreenShare: streamType === (sdk.TYPE?.STREAM_TYPE_SUB || 'sub'), native: { userId, streamType } });
    };
    trtc.on(events.REMOTE_USER_ENTER || 'remote-user-enter', (event) => { addParticipant(session, event.userId); publishSnapshot(session); });
    trtc.on(events.REMOTE_USER_EXIT || 'remote-user-exit', (event) => {
      const userId = String(event.userId || '');
      for (const [trackId, track] of remoteTracks) {
        if (track.userId === userId) remoteTracks.delete(trackId);
      }
      removeParticipant(session, userId);
    });
    trtc.on(events.REMOTE_VIDEO_AVAILABLE || 'remote-video-available', attachRemote);
    trtc.on(events.REMOTE_VIDEO_UNAVAILABLE || 'remote-video-unavailable', (event) => {
      const trackId = `trtc:video:${event.userId}:${event.streamType || sdk.TYPE?.STREAM_TYPE_MAIN || 'main'}`;
      remoteTracks.delete(trackId);
      removeVideoTrack(session, trackId);
    });
    trtc.on(events.CONNECTION_STATE_CHANGED || 'connection-state-changed', (event) => {
      const value = String(event.state || event.currentState || '').toLowerCase();
      if (value.includes('reconnect')) emitState(session, 'reconnecting');
      if (value.includes('connected')) emitState(session, 'connected');
    });
    trtc.on(events.ERROR || 'error', (error) => reportError(session, error));
    trtc.on(events.SCREEN_SHARE_STOPPED || 'screen-share-stopped', () => {
      session.screenTrack = null;
      removeVideoTrack(session, `trtc:screen:${session.localParticipantId}`);
    });
    session.driver = {
      async join() {
        const live = session.role !== 'participant';
        await trtc.enterRoom({
          sdkAppId: Number(info.sdkAppId),
          strRoomId: info.strRoomId,
          userId: info.userId,
          userSig: info.userSig,
          privateMapKey: info.privateMapKey,
          scene: live ? sdk.TYPE.SCENE_LIVE : sdk.TYPE.SCENE_RTC,
          ...(live ? { role: session.role === 'viewer' ? sdk.TYPE.ROLE_AUDIENCE : sdk.TYPE.ROLE_ANCHOR } : {}),
          autoReceiveAudio: true,
          autoReceiveVideo: true,
        });
        // startLocalAudio captures and PUBLISHES by default. Never start it
        // just to mute immediately: that can publish an initial audio frame
        // and request microphone permission before the user opts in.
        session.localMuted = true;
        session.localVideoEnabled = false;
      },
      async command(name, args) {
        if (name === 'setMuted') {
          const muted = Boolean(args.muted);
          if (session.role === 'viewer' && !muted) {
            throw new Error('TRTC audience members cannot publish microphone audio.');
          }
          if (!muted && !audioStarted) {
            await trtc.startLocalAudio({
              publish: true,
              mute: false,
              ...(selectedMicrophoneId ? { option: { microphoneId: selectedMicrophoneId } } : {}),
            });
            audioStarted = true;
          } else if (audioStarted) {
            await trtc.updateLocalAudio({ mute: muted });
          }
          session.localMuted = muted;
          return;
        }
        if (name === 'setVideoEnabled') {
          if (args.enabled && !session.localVideoEnabled) {
            await trtc.startLocalVideo({
              publish: true,
              option: {
                fillMode: 'contain',
                ...(session.processedTrack ? {videoTrack: session.processedTrack} : {}),
              },
            });
          } else if (!args.enabled) {
            await trtc.stopLocalVideo();
          }
          session.localVideoEnabled = Boolean(args.enabled);
          if (!args.enabled) removeVideoTrack(session, localVideoId); else refreshLocalTrack();
          return;
        }
        if (name === 'setScreenShareEnabled') {
          if (args.enabled && !session.screenTrack) {
            // TRTC Web 5.19.x exposes startScreenShare/stopScreenShare, not
            // the obsolete startLocalScreen/stopLocalScreen methods.
            await trtc.startScreenShare({ publish: true });
            const track = trtc.getVideoTrack({ streamType: sdk.TYPE.STREAM_TYPE_SUB });
            if (!track) {
              await trtc.stopScreenShare();
              throw new Error('TRTC screen capture started without a screen video track.');
            }
            session.screenTrack = track;
            addVideoTrack(session, { id: `trtc:screen:${session.localParticipantId}`, participantId: session.localParticipantId, isLocal: true, isScreenShare: true, native: track });
          } else if (!args.enabled && session.screenTrack) {
            await trtc.stopScreenShare();
            session.screenTrack = null;
            removeVideoTrack(session, `trtc:screen:${session.localParticipantId}`);
          }
          return;
        }
        if (name === 'switchCamera') {
          const cameras = await sdk.getCameras();
          const current = cameras.find((device) => device.deviceId === session.cameraId);
          const index = current ? cameras.indexOf(current) : -1;
          const next = cameras[(index + 1) % cameras.length];
          if (next) { session.cameraId = next.deviceId; await trtc.updateLocalVideo({ option: { cameraId: next.deviceId } }); }
          return;
        }
        if (name === 'selectDevice') {
          const selected = args.device || args;
          if (selected.kind === 'microphone') {
            if (!selected.id) throw new Error('TRTC microphone device id is required.');
            if (audioStarted) await trtc.updateLocalAudio({ option: { microphoneId: selected.id } });
            selectedMicrophoneId = selected.id;
          }
          if (selected.kind === 'camera') { session.cameraId = selected.id; await trtc.updateLocalVideo({ option: { cameraId: selected.id } }); }
          return;
        }
        if (name === 'listDevices') return listDevices(session);
        throw new Error(`TRTC does not support ${name}.`);
      },
      async attachProcessedTrack(track) {
        if (session.localVideoEnabled) await trtc.updateLocalVideo({option: {videoTrack: track}});
      },
      async detachProcessedTrack() { await trtc.stopLocalVideo(); },
      async attachVideo(track, container) {
        const native = track.native;
        if (native?.userId) {
          // Flutter's platform-view element is often not assigned an HTML id.
          // TRTC accepts the actual HTMLElement as well as an id string.
          await trtc.startRemoteVideo({ userId: native.userId, streamType: native.streamType, view: container, option: { fillMode: 'contain' } });
        } else {
          const mediaTrack = native?.mediaStreamTrack || native;
          if (mediaTrack && mediaTrack.kind === 'video') attachStreamTrack(mediaTrack, container);
        }
      },
      async detachVideo(track) {
        const native = track.native;
        if (native?.userId) await trtc.stopRemoteVideo({ userId: native.userId, streamType: native.streamType });
      },
      async leave() {
        try {
          if (session.screenTrack) await trtc.stopScreenShare();
          if (audioStarted) await trtc.stopLocalAudio();
        } finally {
          audioStarted = false;
          session.screenTrack = null;
          await trtc.exitRoom();
        }
      },
      async dispose() { trtc.destroy?.(); },
      async getStats() {
        const statistics = session.lastTrtcStatistics;
        return statistics ? { uploadKbps: statistics.localVideo?.sendBitrate, downloadKbps: statistics.remoteVideo?.receiveBitrate, rttMs: statistics.rtt } : null;
      },
    };
    trtc.on(events.STATISTICS || 'statistics', (value) => { session.lastTrtcStatistics = value; });
    return session;
  }
