export function createChimeSession(session, context) {
  const { global, StageEvents, createSdkProcessedVideo, parsePayload, providerBlock, emit, emitState, addParticipant, removeParticipant, addVideoTrack, removeVideoTrack, emitMessage, publishSnapshot, reportError, reportRecoverableWarning, createSession, join, leave, dispose, startStats, stopStats, effectsTrack, command, listDevices, makeVideoElement, attachStreamTrack, getTrackAttachment, requireSession } = context;
    const info = session.payload;
    const meeting = info.meeting || info.Meeting;
    const attendee = info.attendee || info.Attendee;
    if (!meeting || !attendee) throw new Error('Chime join data must include meeting and attendee objects.');
    const logger = new ChimeSDK.ConsoleLogger(`media-web-${session.id}`, ChimeSDK.LogLevel.WARN);
    const deviceController = new ChimeSDK.DefaultDeviceController(logger);
    const configuration = new ChimeSDK.MeetingSessionConfiguration(meeting, attendee);
    const meetingSession = new ChimeSDK.DefaultMeetingSession(configuration, logger, deviceController);
    const audioVideo = meetingSession.audioVideo;
    if (ChimeSDK.VideoCodecCapability) {
      // Avoid VP9 send preferences that older native mobile SDKs cannot decode;
      // prioritize baseline/main H.264 and VP8 for iOS <-> macOS/Web interop.
      const codecPreferences = [
        ChimeSDK.VideoCodecCapability.h264ConstrainedBaselineProfile?.(),
        ChimeSDK.VideoCodecCapability.h264MainProfile?.(),
        ChimeSDK.VideoCodecCapability.vp8?.(),
      ].filter(Boolean);
      if (codecPreferences.length) {
        audioVideo.setVideoCodecSendPreferences?.(codecPreferences);
        audioVideo.setContentShareVideoCodecPreferences?.(codecPreferences);
      }
    }
    let remoteAudioElement = null;
    let microphones = [];
    let selectedMicrophone = null;
    let selectedCamera = null;
    const resolveChimeDeviceId = (available, selected) => {
      if (!Array.isArray(available) || !available.length) return selected?.id || null;
      if (!selected) return available[0].deviceId;
      const byId = selected.id && available.find((item) => item.deviceId === selected.id);
      if (byId) return byId.deviceId;
      const byLabel = selected.label && available.find((item) => item.label && item.label === selected.label);
      if (byLabel) return byLabel.deviceId;
      return selected.id || available[0].deviceId;
    };
    let contentShareStream = null;
    let contentShareStarted = false;
    let contentShareGeneration = 0;
    const localContentTrackId = `chime:screen:${session.localParticipantId}`;
    const releaseLocalContentShare = () => {
      const stream = contentShareStream;
      contentShareStream = null;
      contentShareStarted = false;
      session.screenTrack = null;
      removeVideoTrack(session, localContentTrackId);
      stream?.getTracks?.().forEach((track) => track.stop?.());
    };
    const publishLocalContentShare = () => {
      if (!contentShareStarted || !contentShareStream || session.screenTrack) return;
      const videoTrack = contentShareStream.getVideoTracks?.()[0];
      if (!videoTrack || videoTrack.readyState === 'ended') {
        reportError(session, new Error('Chime content share started without an active screen video track.'));
        return;
      }
      session.screenTrack = videoTrack;
      addVideoTrack(session, {
        id: localContentTrackId,
        participantId: session.localParticipantId,
        isLocal: true,
        isScreenShare: true,
        native: { track: videoTrack },
      });
      videoTrack.addEventListener?.('ended', () => {
        if (session.screenTrack === videoTrack) {
          audioVideo.stopContentShare();
          releaseLocalContentShare();
        }
      }, { once: true });
    };
    const contentObserver = {
      contentShareDidStart() {
        contentShareStarted = true;
        publishLocalContentShare();
      },
      contentShareDidStop() {
        contentShareGeneration += 1;
        releaseLocalContentShare();
      },
    };
    audioVideo.addContentShareObserver(contentObserver);
    let pendingAudioUnlock = null;
    const clearPendingAudioUnlock = () => {
      if (!pendingAudioUnlock) return;
      global.document.removeEventListener?.('pointerdown', pendingAudioUnlock);
      global.document.removeEventListener?.('keydown', pendingAudioUnlock);
      pendingAudioUnlock = null;
    };
    const playRemoteAudio = () => {
      const audio = remoteAudioElement;
      if (!audio) return;
      audio.play().catch((error) => {
        const warn = reportRecoverableWarning || ((target, _code, err) => reportError(target, err));
        warn(
          session,
          'audio-autoplay-blocked',
          new Error(`Chime remote audio playback blocked: ${error.message}. Tap the page to allow sound.`),
        );
        if (!pendingAudioUnlock) {
          pendingAudioUnlock = () => {
            clearPendingAudioUnlock();
            playRemoteAudio();
          };
          global.document.addEventListener?.('pointerdown', pendingAudioUnlock, { once: true });
          global.document.addEventListener?.('keydown', pendingAudioUnlock, { once: true });
        }
      });
    };
    const onAudioStreamLoaded = () => {
      if (session.joined && !session.disposed) playRemoteAudio();
    };
    const tiles = new Map();
    const tileIdFor = (tile) => `chime:tile:${tile.tileId}`;
    let settleStart = null;
    const observer = {
      audioVideoDidStart() {
        settleStart?.(null);
        emitState(session, 'connected');
      },
      audioVideoDidStop(status) {
        const code = typeof status?.statusCode === 'function'
          ? status.statusCode() : status?.statusCode;
        if (settleStart) {
          settleStart(new Error(`Chime connection stopped before joining (status ${code ?? 'unknown'}).`));
        } else if (session.joined && code !== ChimeSDK.MeetingSessionStatusCode.Left) {
          session.joined = false;
          stopStats(session);
          session.tracks.clear();
          session.participants.clear();
          session.localParticipantId = '';
          const meetingEndedCode = ChimeSDK.MeetingSessionStatusCode?.MeetingEnded ?? 6;
          const attendeeRemovedCode = ChimeSDK.MeetingSessionStatusCode?.AudioDisconnectAudio ?? 12;
          const kickedOrEnded =
            code === meetingEndedCode ||
            code === attendeeRemovedCode ||
            code === 'MeetingEnded' ||
            code === 'AudioDisconnectAudio';
          emitState(session, 'ended', kickedOrEnded ? 'meeting-ended' : `stopped:${code ?? 'unknown'}`);
          publishSnapshot(session);
          if (!kickedOrEnded) {
            reportError(session, new Error(`Chime meeting disconnected (status ${code ?? 'unknown'}).`));
          }
        }
      },
      videoTileDidUpdate(tile) {
        if (!tile || !tile.tileId || !tile.boundAttendeeId) return;
        tiles.set(tile.tileId, tile);
        addParticipant(session, tile.boundAttendeeId, null, Boolean(tile.localTile));
        addVideoTrack(session, {
          id: tileIdFor(tile),
          participantId: tile.boundAttendeeId,
          isLocal: Boolean(tile.localTile),
          isScreenShare: Boolean(tile.isContent),
          width: tile.videoStreamContentWidth || 0,
          height: tile.videoStreamContentHeight || 0,
          native: tile,
        });
      },
      videoTileWasRemoved(tileId) {
        const tile = tiles.get(tileId);
        if (tile) removeVideoTrack(session, tileIdFor(tile));
        tiles.delete(tileId);
      },
      connectionDidSuggestStop() { emitState(session, 'reconnecting', 'connection-did-suggest-stop'); },
    };
    audioVideo.addObserver(observer);
    const presenceObserver = (attendeeId, present, externalUserId) => {
      if (!attendeeId || attendeeId.includes('#')) return;
      if (present) {
        addParticipant(
          session,
          attendeeId,
          externalUserId || attendeeId,
          attendeeId === session.localParticipantId,
        );
        publishSnapshot(session);
      } else {
        removeParticipant(session, attendeeId);
      }
    };
    audioVideo.realtimeSubscribeToAttendeeIdPresence(presenceObserver);
    const dataTopic = 'chat';
    const encodeDataPayload = (topic, rawMessage) => {
      if (topic === dataTopic) return rawMessage;
      return JSON.stringify({
        __chimeTopicEnvelope: 1,
        topic,
        message: rawMessage,
      });
    };
    const decodeDataPayload = (wireTopic, rawText) => {
      if (typeof rawText === 'string' && rawText.startsWith('{')) {
        try {
          const decoded = JSON.parse(rawText);
          if (
            decoded &&
            typeof decoded === 'object' &&
            decoded.__chimeTopicEnvelope === 1 &&
            typeof decoded.topic === 'string' &&
            decoded.topic.trim().length > 0 &&
            typeof decoded.message === 'string'
          ) {
            return {
              topic: decoded.topic.trim(),
              message: decoded.message,
            };
          }
        } catch (_) {
          // Regular plain-text or non-envelope JSON chat message.
        }
      }
      return {
        topic: wireTopic || dataTopic,
        message: rawText,
      };
    };
    const dataObserver = (dataMessage) => {
      let rawText = '';
      try {
        if (typeof dataMessage.text === 'function') rawText = dataMessage.text();
        else if (dataMessage.data) rawText = new TextDecoder().decode(dataMessage.data);
      } catch (_) {
        rawText = '';
      }
      const decoded = decodeDataPayload(dataMessage.topic || dataTopic, rawText);
      emitMessage(session, {
        participantId: dataMessage.senderAttendeeId,
        displayName: dataMessage.senderExternalUserId,
        message: decoded.message,
        topic: decoded.topic,
        timestampMs: dataMessage.timestampMs,
        throttled: dataMessage.throttled,
      });
    };
    audioVideo.realtimeSubscribeToReceiveDataMessage(dataTopic, dataObserver);
    session.meetingSession = meetingSession;
    session.driver = {
      async join() {
        // Chime Web never plays remote participants unless an HTMLAudioElement
        // is bound. Video tiles do not carry the mixed remote audio stream.
        if (!remoteAudioElement) {
          const audio = global.document.createElement('audio');
          audio.autoplay = true;
          audio.playsInline = true;
          audio.style.display = 'none';
          audio.addEventListener?.('loadedmetadata', onAudioStreamLoaded);
          global.document.body.append(audio);
          try {
            audioVideo.bindAudioElement(audio);
            remoteAudioElement = audio;
          } catch (error) {
            audio.removeEventListener?.('loadedmetadata', onAudioStreamLoaded);
            audio.remove();
            throw error;
          }
        }
        // Chime can join as a listener with no audio input. Do not request
        // microphone permission before the participant explicitly unmutes.
        // Device discovery is deferred too (WKWebView/TCC can reject it).
        microphones = [];

        // start() begins asynchronous signaling. Do not mark the attendee as
        // connected until Chime actually fires audioVideoDidStart. Otherwise
        // macOS can show a joined room while the service still reports 0 users.
        const connected = new Promise((resolve, reject) => {
          const timeout = global.setTimeout(() => {
            settleStart?.(new Error('Chime signaling timed out after 30 seconds. Check network and AWS media region.'));
          }, 30000);
          settleStart = (error) => {
            global.clearTimeout(timeout);
            settleStart = null;
            if (error) reject(error);
            else resolve();
          };
        });
        try { audioVideo.start(); }
        catch (error) { settleStart?.(error); }
        await connected;
        // Keep the actual local SDK state aligned with the initial muted UI.
        audioVideo.realtimeMuteLocalAudio();
        session.localMuted = true;
        session.localVideoEnabled = false;
        playRemoteAudio();
        for (const tile of audioVideo.getAllVideoTiles()) observer.videoTileDidUpdate(tile.state());
      },
      async command(name, args) {
        if (name === 'setMuted') {
          if (args.muted) {
            audioVideo.realtimeMuteLocalAudio();
          } else {
            // Joining as a listener is allowed without microphone permission;
            // an explicit unmute must obtain a usable input or fail visibly.
            if (!microphones.length) {
              const available = await audioVideo.listAudioInputDevices();
              if (!available.length) throw new Error('No Chime microphone is available.');
              const selected = resolveChimeDeviceId(available, selectedMicrophone);
              await audioVideo.startAudioInput(selected);
              microphones = available;
            }
            const unmuted = await audioVideo.realtimeUnmuteLocalAudio();
            if (unmuted === false) throw new Error('Chime failed to unmute local audio.');
          }
          session.localMuted = Boolean(args.muted);
          return;
        }
        if (name === 'setVideoEnabled') {
          if (args.enabled) {
            if (session.processedTrack) await audioVideo.startVideoInput(new MediaStream([session.processedTrack]));
            else {
              const cameras = await audioVideo.listVideoInputDevices();
              const cameraId = resolveChimeDeviceId(cameras, selectedCamera);
              if (!cameraId) throw new Error('No Chime camera is available.');
              await audioVideo.startVideoInput(cameraId);
            }
            audioVideo.startLocalVideoTile();
          } else {
            audioVideo.stopLocalVideoTile();
            // Stop the vendor-owned camera capture as well as its video tile;
            // leaving a black tile is not equivalent to releasing a camera.
            if (!session.processedTrack) await audioVideo.stopVideoInput?.();
          }
          session.localVideoEnabled = Boolean(args.enabled);
          return;
        }
        if (name === 'setScreenShareEnabled') {
          if (args.enabled && !session.screenTrack) {
            // A resolved screen-picker promise alone is not proof that Chime
            // started content publication. Match the vendor observer's start
            // event with an actual screen MediaStreamTrack.
            const generation = contentShareGeneration;
            const stream = await audioVideo.startContentShareFromScreenCapture();
            // A content-share rejection/stop can race with the capture
            // promise settling. Never resurrect a stopped recording.
            if (generation !== contentShareGeneration || session.disposed) {
              stream?.getTracks?.().forEach((track) => track.stop?.());
              throw new Error('Chime screen capture ended before content sharing started.');
            }
            contentShareStream = stream;
            publishLocalContentShare();
          } else if (!args.enabled) {
            audioVideo.stopContentShare();
            releaseLocalContentShare();
          }
          return;
        }
        if (name === 'selectDevice' || name === 'selectAudioOutput') {
          const selected = args.device || args;
          if (selected.kind === 'microphone') {
            if (!selected.id) throw new Error('Chime microphone device id is required.');
            const nextMic = { id: selected.id, label: selected.label || '' };
            if (!session.localMuted) {
              const available = microphones.length ? microphones : await audioVideo.listAudioInputDevices();
              microphones = available;
              await audioVideo.startAudioInput(resolveChimeDeviceId(available, nextMic));
            }
            selectedMicrophone = nextMic;
          }
          if (selected.kind === 'camera') {
            if (!selected.id) throw new Error('Chime camera device id is required.');
            const nextCamera = { id: selected.id, label: selected.label || '' };
            if (session.localVideoEnabled && !session.processedTrack) {
              const cameras = await audioVideo.listVideoInputDevices();
              await audioVideo.startVideoInput(resolveChimeDeviceId(cameras, nextCamera));
            }
            selectedCamera = nextCamera;
          }
          if (selected.kind === 'audioOutput') {
            try {
              await audioVideo.chooseAudioOutput(selected.id);
            } catch (error) {
              // Safari and macOS WKWebView lack HTMLMediaElement.setSinkId.
              if (!String(error?.message || error).includes('setSinkId')) {
                throw error;
              }
            }
            playRemoteAudio();
          }
          return;
        }
        if (name === 'listDevices') {
          const [microphones, cameras, outputs] = await Promise.all([audioVideo.listAudioInputDevices(), audioVideo.listVideoInputDevices(), audioVideo.listAudioOutputDevices()]);
          return [...microphones.map((item) => ({ id: item.deviceId, label: item.label, groupId: item.groupId, kind: 'microphone' })), ...cameras.map((item) => ({ id: item.deviceId, label: item.label, groupId: item.groupId, kind: 'camera' })), ...outputs.map((item) => ({ id: item.deviceId, label: item.label, groupId: item.groupId, kind: 'audioOutput' }))];
        }
        if (name === 'sendMessage') {
          const topic = String(args.topic || dataTopic).trim() || dataTopic;
          const message = String(args.message || '');
          const lifetimeMs = Number(args.lifetimeMs || 300000);
          if (!message || lifetimeMs <= 0) throw new Error('Chime data message requires message, topic, and positive lifetimeMs.');
          // Chime SDK only subscribes to 'chat' cleanly and rejects '.' in
          // data-message topics with RealtimeApiFailed (17), so multiplex
          // logical topics over 'chat' via a shared envelope.
          audioVideo.realtimeSendDataMessage(dataTopic, encodeDataPayload(topic, message), lifetimeMs);
          return;
        }
        throw new Error(`Chime does not support ${name}.`);
      },
      async attachProcessedTrack(track) {
        await audioVideo.startVideoInput(new MediaStream([track]));
        if (session.localVideoEnabled) {
          audioVideo.startLocalVideoTile();
        }
      },
      async detachProcessedTrack() {
        audioVideo.stopLocalVideoTile();
        await audioVideo.stopVideoInput?.();
      },
      attachVideo(track, container) {
        if (track.isLocal && track.isScreenShare && track.native?.track) {
          attachStreamTrack(track.native.track, container);
          return;
        }
        const tile = track.native;
        const video = makeVideoElement(container);
        // Chime video tiles carry no audio track; muting prevents WebKit from
        // blocking remote tiles as unmuted autoplay without a user gesture.
        video.muted = true;
        video.defaultMuted = true;
        audioVideo.bindVideoElement(tile.tileId, video);
        video.play?.().catch(() => {});
      },
      detachVideo(track) {
        if (track.isLocal && track.isScreenShare && track.native?.track) return;
        audioVideo.unbindVideoElement(track.native.tileId);
      },
      async leave() {
        if (contentShareStream || contentShareStarted) audioVideo.stopContentShare();
        releaseLocalContentShare();
        audioVideo.stop();
        clearPendingAudioUnlock();
        remoteAudioElement?.removeEventListener?.('loadedmetadata', onAudioStreamLoaded);
        audioVideo.unbindAudioElement?.();
        remoteAudioElement?.remove();
        remoteAudioElement = null;
        await deviceController.destroy?.();
      },
      async dispose() {
        audioVideo.removeContentShareObserver(contentObserver);
        audioVideo.removeObserver(observer);
        audioVideo.realtimeUnsubscribeToAttendeeIdPresence(presenceObserver);
        audioVideo.realtimeUnsubscribeFromReceiveDataMessage(dataTopic);
      },
      async getStats() { return null; },
    };
    return session;
  }
