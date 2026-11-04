export function createTrtcSession(session, context) {
  const { global, StageEvents, createSdkProcessedVideo, parsePayload, providerBlock, emit, emitState, addParticipant, removeParticipant, addVideoTrack, removeVideoTrack, emitMessage, publishSnapshot, reportError, createSession, join, leave, dispose, startStats, stopStats, effectsTrack, command, listDevices, makeVideoElement, attachStreamTrack, getTrackAttachment, requireSession } = context;
    const info = providerBlock(session, 'trtc');
    const sdk = global.TRTC;
    const trtc = sdk.create({ assetsPath: (globalThis.__realtimeTrtcAssetsPath || new URL('assets/packages/flutter_realtime_sdk/assets/provider_web_runtime/vendors/trtc-assets/', document.baseURI).toString()) });
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
    trtc.on(events.REMOTE_USER_EXIT || 'remote-user-exit', (event) => removeParticipant(session, event.userId));
    trtc.on(events.REMOTE_VIDEO_AVAILABLE || 'remote-video-available', attachRemote);
    trtc.on(events.REMOTE_VIDEO_UNAVAILABLE || 'remote-video-unavailable', (event) => removeVideoTrack(session, `trtc:video:${event.userId}:${event.streamType || sdk.TYPE?.STREAM_TYPE_MAIN || 'main'}`));
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
        if (session.role !== 'viewer') {
          await trtc.startLocalAudio();
          // iOS joins muted; Web must not transmit microphone audio before
          // the participant explicitly unmutes via Pre-Join or room controls.
          await trtc.updateLocalAudio({ mute: true });
          session.localMuted = true;
          session.localVideoEnabled = false;
        }
      },
      async command(name, args) {
        if (name === 'setMuted') {
          await trtc.updateLocalAudio({ mute: Boolean(args.muted) });
          session.localMuted = Boolean(args.muted);
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
            await trtc.startLocalScreen({ publish: true });
            session.screenTrack = trtc.getVideoTrack({ streamType: sdk.TYPE.STREAM_TYPE_SUB });
            if (session.screenTrack) addVideoTrack(session, { id: `trtc:screen:${session.localParticipantId}`, participantId: session.localParticipantId, isLocal: true, isScreenShare: true, native: session.screenTrack });
          } else if (!args.enabled && session.screenTrack) {
            await trtc.stopLocalScreen();
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
          if (selected.kind === 'microphone') await trtc.updateLocalAudio({ option: { microphoneId: selected.id } });
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
          await trtc.startRemoteVideo({ userId: native.userId, streamType: native.streamType, view: container.id, option: { fillMode: 'contain' } });
        } else {
          const mediaTrack = native?.mediaStreamTrack || native;
          if (mediaTrack && mediaTrack.kind === 'video') attachStreamTrack(mediaTrack, container);
        }
      },
      async detachVideo(track) {
        const native = track.native;
        if (native?.userId) await trtc.stopRemoteVideo({ userId: native.userId, streamType: native.streamType });
      },
      async leave() { await trtc.exitRoom(); },
      async dispose() { trtc.destroy?.(); },
      async getStats() {
        const statistics = session.lastTrtcStatistics;
        return statistics ? { uploadKbps: statistics.localVideo?.sendBitrate, downloadKbps: statistics.remoteVideo?.receiveBitrate, rttMs: statistics.rtt } : null;
      },
    };
    trtc.on(events.STATISTICS || 'statistics', (value) => { session.lastTrtcStatistics = value; });
    return session;
  }
