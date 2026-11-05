export function createArtcSession(session, context) {
  const { global, StageEvents, createSdkProcessedVideo, parsePayload, providerBlock, emit, emitState, addParticipant, removeParticipant, addVideoTrack, removeVideoTrack, emitMessage, publishSnapshot, reportError, createSession, join, leave, dispose, startStats, stopStats, effectsTrack, command, listDevices, makeVideoElement, attachStreamTrack, getTrackAttachment, requireSession } = context;
    const info = providerBlock(session, 'artc');
    const namespace = global.AliRtcEngine;
    const AliRtcEngine = namespace?.AliRtcEngine || namespace?.default || namespace;
    const profile = AliRtcEngine.AliRtcSdkChannelProfile;
    const roles = AliRtcEngine.AliRtcSdkClientRole;
    const engine = AliRtcEngine.createInstance ? AliRtcEngine.createInstance() : AliRtcEngine.getInstance();
    const checked = async (operation, action) => {
      const result = await action();
      // AliRTC APIs report synchronous native/SDK failures as non-zero codes
      // rather than rejected promises on some platforms/SDK versions.
      if (typeof result === 'number' && result !== 0) {
        throw new Error(`ARTC ${operation} failed (${result}).`);
      }
    };
    const cameraTrack = AliRtcEngine.AliRtcVideoTrack.AliRtcVideoTrackCamera;
    const screenTrack = AliRtcEngine.AliRtcVideoTrack.AliRtcVideoTrackScreen;
    const remoteVideo = new Map();
    engine.on('connectionStatusChange', (status) => {
      if (status === AliRtcEngine.AliRtcConnectionStatus.AliRtcConnectionStatusReconnecting) emitState(session, 'reconnecting');
      if (status === AliRtcEngine.AliRtcConnectionStatus.AliRtcConnectionStatusConnected) emitState(session, 'connected');
    });
    engine.on('remoteUserOnLineNotify', (uid) => { addParticipant(session, uid); publishSnapshot(session); });
    engine.on('remoteUserOffLineNotify', (uid) => removeParticipant(session, uid));
    engine.on('remoteTrackAvailableNotify', (uid, audioTracks, videoTracks) => {
      const id = `artc:video:${uid}`;
      const screenId = `artc:screen:${uid}`;
      if (videoTracks & cameraTrack) {
        remoteVideo.set(id, { uid, track: cameraTrack });
        addVideoTrack(session, { id, participantId: uid, native: { uid, track: cameraTrack } });
      } else removeVideoTrack(session, id);
      if (videoTracks & screenTrack) {
        addVideoTrack(session, {
          id: screenId, participantId: uid, isScreenShare: true,
          native: { uid, track: screenTrack },
        });
      } else removeVideoTrack(session, screenId);
    });
    engine.on('error', (error) => reportError(session, error));
    session.driver = {
      async join() {
        if (session.role === 'participant') engine.setChannelProfile(profile.AliRtcSdkCommunication);
        else {
          engine.setChannelProfile(profile.AliRtcInteractiveLive);
          await engine.setClientRole(session.role === 'viewer' ? roles.AliRtcSdkLive : roles.AliRtcSdkInteractive);
        }
        await checked('disable camera capture', () => engine.enableLocalVideo(false));
        await checked('disable camera publication', () => engine.publishLocalVideoStream(false));
        // ARTC enables audio publication by default. Audience members must
        // also disable it BEFORE joinChannel, even though they cannot unmute.
        await checked('disable microphone publication', () => engine.publishLocalAudioStream(false));
        await engine.joinChannel(info.authInfo, session.payload.displayName || info.userId);
        session.localMuted = true;
        session.localVideoEnabled = false;
      },
      async command(name, args) {
        if (name === 'setMuted') {
          const muted = Boolean(args.muted);
          if (session.role === 'viewer' && !muted) {
            throw new Error('ARTC viewer sessions cannot publish microphone audio.');
          }
          await checked('microphone publication', () => engine.publishLocalAudioStream(!muted));
          await checked('microphone mute', () => engine.muteLocalMic(muted));
          session.localMuted = muted;
          return;
        }
        if (name === 'setVideoEnabled') {
          const enabled = Boolean(args.enabled);
          if (session.processedTrack) {
            await checked('camera mute', () => engine.muteLocalCamera(!enabled));
            await checked('camera publication', () => engine.publishLocalVideoStream(enabled));
          } else {
            await checked('camera capture', () => engine.enableLocalVideo(enabled));
            await checked('camera publication', () => engine.publishLocalVideoStream(enabled));
          }
          session.localVideoEnabled = enabled;
          if (!enabled) removeVideoTrack(session, `artc:video:${session.localParticipantId}`);
          else addVideoTrack(session, {id: `artc:video:${session.localParticipantId}`, participantId: session.localParticipantId, isLocal: true, native: {uid: session.localParticipantId, track: cameraTrack}});
          return;
        }
        if (name === 'setScreenShareEnabled') {
          if (args.enabled && !session.screenTrack) {
            await checked('start screen preview', () => engine.startPreviewScreen());
            try { await checked('publish screen', () => engine.publishLocalScreenShareStream(true)); }
            catch (error) { await engine.stopPreviewScreen(); throw error; }
            session.screenTrack = {uid: session.localParticipantId, track: screenTrack};
            addVideoTrack(session, { id: `artc:screen:${session.localParticipantId}`, participantId: session.localParticipantId, isLocal: true, isScreenShare: true, native: session.screenTrack });
          } else if (!args.enabled && session.screenTrack) {
            try {
              await checked('unpublish screen', () => engine.publishLocalScreenShareStream(false));
            } finally {
              await engine.stopPreviewScreen();
            }
            session.screenTrack = null;
            removeVideoTrack(session, `artc:screen:${session.localParticipantId}`);
          }
          return;
        }
        if (name === 'switchCamera') {
          const cameras = await AliRtcEngine.getCameraList();
          const current = engine.getCurrentCameraDeviceId?.();
          const index = cameras.findIndex((device) => device.deviceId === current);
          const next = cameras[(index + 1) % cameras.length];
          if (next) await engine.switchCamera(next.deviceId);
          return;
        }
        if (name === 'selectDevice') {
          const selected = args.device || args;
          if (selected.kind === 'camera') { engine.setCameraCapturerConfiguration({ deviceId: selected.id }); await engine.switchCamera(selected.id); }
          if (selected.kind === 'microphone') engine.setMicrophoneDeviceId?.(selected.id);
          return;
        }
        if (name === 'listDevices') return listDevices(session);
        throw new Error(`ARTC does not support ${name}.`);
      },
      async attachProcessedTrack(track) {
        // Pinned ARTC 7.3.5 ignores switchCamera's external track while capture
        // is disabled. Its public enableLocalVideo(true) opens a raw camera.
        // Set only the capture state before supplying the external track.
        const manager = engine.publisher?.streamManager;
        if (!manager || !('cameraCaptureDisabled' in manager)) {
          throw new Error('This ARTC SDK does not support the processed video input contract.');
        }
        manager.cameraCaptureDisabled = false;
        try {
          await engine.switchCamera(undefined, track);
          await engine.publishLocalVideoStream(session.localVideoEnabled);
        } catch (error) {
          await engine.enableLocalVideo(false);
          throw error;
        }
      },
      async detachProcessedTrack() {
        await engine.publishLocalVideoStream(false);
        await engine.enableLocalVideo(false);
      },
      async attachVideo(track, container) {
        const video = makeVideoElement(container);
        if (track.isLocal) await engine.setLocalViewConfig(video, track.isScreenShare ? screenTrack : cameraTrack);
        else engine.setRemoteViewConfig(video, track.participantId, track.isScreenShare ? screenTrack : cameraTrack);
        video.style.objectFit = 'contain';
      },
      detachVideo(track) {
        if (track.isLocal) engine.setLocalViewConfig(null, track.isScreenShare ? screenTrack : cameraTrack);
        else engine.setRemoteViewConfig(null, track.participantId, track.isScreenShare ? screenTrack : cameraTrack);
      },
      async leave() { await engine.leaveChannel(); },
      async dispose() { await engine.destroy(); },
      async getStats() { return session.lastArtcStats || null; },
    };
    engine.on('networkQuality', (stats) => {
      session.lastArtcStats = {
        rttMs: stats?.subscribe?.rtt,
        downlinkPacketLossPercent: stats?.subscribe?.loss,
      };
      emit(session, { type: 'stats', timestampMs: Date.now(), ...session.lastArtcStats });
    });
    return session;
  }
