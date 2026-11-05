export function createChimeSession(session, context) {
  const { global, StageEvents, createSdkProcessedVideo, parsePayload, providerBlock, emit, emitState, addParticipant, removeParticipant, addVideoTrack, removeVideoTrack, emitMessage, publishSnapshot, reportError, createSession, join, leave, dispose, startStats, stopStats, effectsTrack, command, listDevices, makeVideoElement, attachStreamTrack, getTrackAttachment, requireSession } = context;
    const info = session.payload;
    const meeting = info.meeting || info.Meeting;
    const attendee = info.attendee || info.Attendee;
    if (!meeting || !attendee) throw new Error('Chime join data must include meeting and attendee objects.');
    const logger = new ChimeSDK.ConsoleLogger(`media-web-${session.id}`, ChimeSDK.LogLevel.WARN);
    const deviceController = new ChimeSDK.DefaultDeviceController(logger);
    const configuration = new ChimeSDK.MeetingSessionConfiguration(meeting, attendee);
    const meetingSession = new ChimeSDK.DefaultMeetingSession(configuration, logger, deviceController);
    const audioVideo = meetingSession.audioVideo;
    let remoteAudioElement = null;
    let microphones = [];
    let selectedMicrophoneId = null;
    let selectedCameraId = null;
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
    const playRemoteAudio = () => {
      const audio = remoteAudioElement;
      if (!audio) return;
      audio.play().catch((error) => {
        reportError(session, new Error(`Chime remote audio playback blocked: ${error.message}. Tap the page to allow sound.`));
        if (!pendingAudioUnlock) {
          pendingAudioUnlock = () => {
            pendingAudioUnlock = null;
            playRemoteAudio();
          };
          global.document.addEventListener('pointerdown', pendingAudioUnlock, { once: true });
        }
      });
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
          reportError(session, new Error(`Chime meeting disconnected (status ${code ?? 'unknown'}).`));
        }
      },
      videoTileDidUpdate(tile) {
        if (!tile || !tile.tileId || !tile.boundAttendeeId) return;
        tiles.set(tile.tileId, tile);
        addParticipant(session, tile.boundAttendeeId, null, Boolean(tile.localTile));
        addVideoTrack(session, { id: tileIdFor(tile), participantId: tile.boundAttendeeId, isLocal: Boolean(tile.localTile), isScreenShare: Boolean(tile.isContent), native: tile });
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
    const dataObserver = (dataMessage) => {
      let message = '';
      try {
        if (typeof dataMessage.text === 'function') message = dataMessage.text();
        else if (dataMessage.data) message = new TextDecoder().decode(dataMessage.data);
      } catch (_) {
        message = '';
      }
      emitMessage(session, {
        participantId: dataMessage.senderAttendeeId,
        displayName: dataMessage.senderExternalUserId,
        message,
        topic: dataMessage.topic || dataTopic,
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
          global.document.body.append(audio);
          try {
            audioVideo.bindAudioElement(audio);
            remoteAudioElement = audio;
          } catch (error) {
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
              const selected = selectedMicrophoneId || available[0].deviceId;
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
              const cameraId = selectedCameraId || cameras[0]?.deviceId;
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
            if (!session.localMuted) await audioVideo.startAudioInput(selected.id);
            selectedMicrophoneId = selected.id;
          }
          if (selected.kind === 'camera') {
            if (!selected.id) throw new Error('Chime camera device id is required.');
            if (session.localVideoEnabled && !session.processedTrack) {
              await audioVideo.startVideoInput(selected.id);
            }
            selectedCameraId = selected.id;
          }
          if (selected.kind === 'audioOutput') await audioVideo.chooseAudioOutput(selected.id);
          return;
        }
        if (name === 'listDevices') {
          const [microphones, cameras, outputs] = await Promise.all([audioVideo.listAudioInputDevices(), audioVideo.listVideoInputDevices(), audioVideo.listAudioOutputDevices()]);
          return [...microphones.map((item) => ({ id: item.deviceId, label: item.label, groupId: item.groupId, kind: 'microphone' })), ...cameras.map((item) => ({ id: item.deviceId, label: item.label, groupId: item.groupId, kind: 'camera' })), ...outputs.map((item) => ({ id: item.deviceId, label: item.label, groupId: item.groupId, kind: 'audioOutput' }))];
        }
        if (name === 'sendMessage') {
          const topic = String(args.topic || dataTopic);
          const message = String(args.message || '');
          const lifetimeMs = Number(args.lifetimeMs || 300000);
          if (!message || !topic || lifetimeMs <= 0) throw new Error('Chime data message requires message, topic, and positive lifetimeMs.');
          audioVideo.realtimeSendDataMessage(topic, message, lifetimeMs);
          return;
        }
        throw new Error(`Chime does not support ${name}.`);
      },
      async attachProcessedTrack(track) {
        await audioVideo.startVideoInput(new MediaStream([track]));
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
        audioVideo.bindVideoElement(tile.tileId, video);
      },
      detachVideo(track) {
        if (track.isLocal && track.isScreenShare && track.native?.track) return;
        audioVideo.unbindVideoElement(track.native.tileId);
      },
      async leave() {
        if (contentShareStream || contentShareStarted) audioVideo.stopContentShare();
        releaseLocalContentShare();
        audioVideo.stop();
        if (pendingAudioUnlock) {
          global.document.removeEventListener('pointerdown', pendingAudioUnlock);
          pendingAudioUnlock = null;
        }
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
