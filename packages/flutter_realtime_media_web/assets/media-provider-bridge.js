(() => {
  // ../../packages/flutter_realtime_processed_video/web/processed-video-bridge.js
  (function installProcessedVideoBridge(global) {
    if (global.RealtimeProcessedVideoBridge) return;
    const sources = /* @__PURE__ */ new Map();
    function requireSource(id) {
      const source = sources.get(id);
      if (!source) throw new Error("processedVideo.source.unregistered");
      return source;
    }
    global.RealtimeProcessedVideoBridge = Object.freeze({
      register(id, source) {
        if (!id || sources.has(id)) throw new Error("processedVideo.source.duplicate");
        sources.set(id, source);
      },
      unregister(id) {
        sources.delete(id);
      },
      getTrack(id) {
        return requireSource(id).track;
      },
      setEnabled(id, enabled) {
        return requireSource(id).setEnabled(enabled);
      },
      selectCamera(id, deviceId) {
        return requireSource(id).setCameraDevice(deviceId);
      },
      attachPreviewElement(id, element, fit) {
        const source = requireSource(id);
        if (source.attachPreviewElement) return source.attachPreviewElement(element, fit);
        const video = global.document.createElement("video");
        video.autoplay = true;
        video.muted = true;
        video.playsInline = true;
        video.style.width = "100%";
        video.style.height = "100%";
        video.style.objectFit = fit;
        video.srcObject = new global.MediaStream([source.track]);
        element.replaceChildren(video);
        void video.play().catch(() => {
        });
      }
    });
  })(globalThis);

  // src/media/agora-session.js
  function createAgoraSession(session, context) {
    const { global, StageEvents, createSdkProcessedVideo, parsePayload, providerBlock, emit, emitState, addParticipant, removeParticipant, addVideoTrack, removeVideoTrack, emitMessage, publishSnapshot, reportError, createSession, join, leave, dispose, startStats, stopStats, effectsTrack, command, listDevices, makeVideoElement, attachStreamTrack, getTrackAttachment, requireSession } = context;
    const info = providerBlock(session, "agora");
    const live = session.role !== "participant";
    const client = AgoraRTC.createClient({ mode: live ? "live" : "rtc", codec: "vp8" });
    const localTracks = {
      audio: null,
      video: null,
      screen: null,
      pipeline: null,
      videoTrackId: `agora:video:${session.localParticipantId}`,
      videoPublished: false
    };
    let selectedCameraId = null;
    let backgroundEffect = { type: "none", blurStrength: "medium" };
    let processedSourceId = null;
    let providerInputTrack = null;
    const remoteUsers = /* @__PURE__ */ new Map();
    const remoteScreenUids = /* @__PURE__ */ new Set();
    const processedTrackForSource = (sourceId) => {
      const effectsBridge = global.RealtimeProcessedVideoBridge;
      if (!effectsBridge?.getTrack) {
        throw new Error("RealtimeProcessedVideoBridge is unavailable.");
      }
      const mediaStreamTrack = effectsBridge.getTrack(sourceId);
      if (!mediaStreamTrack) {
        throw new Error(
          `Processed video source ${sourceId} has no MediaStreamTrack.`
        );
      }
      return mediaStreamTrack;
    };
    const ensureVideoTrack = async () => {
      if (processedSourceId) {
        if (!localTracks.video) {
          const sourceTrack = processedTrackForSource(processedSourceId);
          providerInputTrack = sourceTrack.clone?.() || sourceTrack;
          localTracks.video = AgoraRTC.createCustomVideoTrack({ mediaStreamTrack: providerInputTrack });
        }
        return localTracks.video;
      }
      if (backgroundEffect.type === "none" && !localTracks.pipeline) {
        localTracks.video ?? (localTracks.video = await AgoraRTC.createCameraVideoTrack(
          selectedCameraId ? { cameraId: selectedCameraId } : {}
        ));
        return localTracks.video;
      }
      if (!localTracks.pipeline) {
        localTracks.pipeline = await createSdkProcessedVideo({
          effect: backgroundEffect,
          deviceId: selectedCameraId
        });
      } else {
        await localTracks.pipeline.setEffect(backgroundEffect);
      }
      if (!localTracks.video) {
        localTracks.video = AgoraRTC.createCustomVideoTrack({
          mediaStreamTrack: localTracks.pipeline.track
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
        native: { track: videoTrack }
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
      if (mediaType === "audio" && user.audioTrack) user.audioTrack.play();
      if (mediaType === "video" && user.videoTrack) {
        const screenShare = remoteScreenUids.has(participantId);
        const trackId = `agora:${screenShare ? "screen" : "video"}:${participantId}`;
        const formerId = `agora:${screenShare ? "video" : "screen"}:${participantId}`;
        remoteUsers.delete(formerId);
        removeVideoTrack(session, formerId);
        const remote = { user, track: user.videoTrack };
        remoteUsers.set(trackId, remote);
        addVideoTrack(session, {
          id: trackId,
          participantId,
          isScreenShare: screenShare,
          native: remote
        });
        const attachment = getTrackAttachment(session, trackId);
        if (attachment) user.videoTrack.play(attachment.container, { fit: "contain" });
      }
      participant.isMuted = !user.audioTrack;
      publishSnapshot(session);
    };
    client.on("user-joined", (user) => {
      addParticipant(session, user.uid);
      publishSnapshot(session);
    });
    client.on("user-left", (user) => {
      remoteScreenUids.delete(String(user.uid));
      removeParticipant(session, user.uid);
    });
    client.on("stream-message", (uid, payload) => {
      try {
        const message = JSON.parse(new TextDecoder().decode(payload));
        if (message.topic !== "_flutter_realtime.screen_share.v1" || !["started", "stopped"].includes(message.message)) return;
        const key = String(uid);
        if (message.message === "started") remoteScreenUids.add(key);
        else remoteScreenUids.delete(key);
        const remote = client.remoteUsers?.find((user) => String(user.uid) === key);
        if (remote?.videoTrack) updateRemote(remote, "video").catch(
          (error) => reportError(session, error)
        );
      } catch (_) {
      }
    });
    client.on("user-published", async (user, type) => {
      try {
        await client.subscribe(user, type);
        await updateRemote(user, type);
      } catch (error) {
        reportError(session, error);
      }
    });
    client.on("user-unpublished", (user, type) => {
      if (type === "video") {
        remoteUsers.delete(`agora:video:${user.uid}`);
        remoteUsers.delete(`agora:screen:${user.uid}`);
        removeVideoTrack(session, `agora:video:${user.uid}`);
        removeVideoTrack(session, `agora:screen:${user.uid}`);
      }
      if (type === "audio") {
        const participant = session.participants.get(String(user.uid));
        if (participant) participant.isMuted = true;
        publishSnapshot(session);
      }
    });
    client.on("connection-state-change", (current) => {
      if (current === "RECONNECTING") emitState(session, "reconnecting");
      if (current === "CONNECTED") emitState(session, "connected");
    });
    session.driver = {
      async join() {
        if (live) await client.setClientRole(session.role === "viewer" ? "audience" : "host");
        await client.join(info.appId, info.channelName, info.token, Number(info.uid));
        session.localMuted = true;
        session.localVideoEnabled = false;
      },
      async command(name, args) {
        if (name === "setMuted") {
          const muted = Boolean(args.muted);
          if (!muted && session.role === "viewer") {
            throw new Error("Agora viewers cannot publish microphone audio.");
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
        if (name === "attachProcessedVideoSource") {
          const sourceId = String(args.sourceId || "");
          if (!sourceId) throw new Error("Processed video sourceId is required.");
          processedTrackForSource(sourceId);
          await unpublishCameraIfNeeded();
          localTracks.video?.close?.();
          providerInputTrack?.stop?.();
          providerInputTrack = null;
          localTracks.video = null;
          localTracks.pipeline?.stop?.();
          localTracks.pipeline = null;
          processedSourceId = sourceId;
          session.processedSourceId = sourceId;
          if (session.localVideoEnabled) await publishCameraIfNeeded();
          return;
        }
        if (name === "detachProcessedVideoSource") {
          await unpublishCameraIfNeeded();
          localTracks.video?.close?.();
          providerInputTrack?.stop?.();
          providerInputTrack = null;
          localTracks.video = null;
          processedSourceId = null;
          session.processedSourceId = null;
          return;
        }
        if (name === "setProcessedVideoEffect") {
          if (!processedSourceId) {
            throw new Error("No SDK processed video source is attached.");
          }
          const effectsBridge = global.RealtimeVideoEffectsBridge;
          if (!effectsBridge?.setEffect) {
            throw new Error("RealtimeProcessedVideoBridge is unavailable.");
          }
          await effectsBridge.setEffect(
            processedSourceId,
            JSON.stringify({
              type: String(args.type || "none"),
              blurStrength: String(args.blurStrength || "medium"),
              imageBytes: args.imageBytes || null
            })
          );
          return;
        }
        if (name === "setVideoEnabled") {
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
        if (name === "setBackgroundEffect") {
          const type = String(args.type || "none");
          if (!["none", "blur", "replaceImage"].includes(type)) {
            throw new Error(`Unsupported SDK background effect: ${type}`);
          }
          if (type === "blur" && !global.SdkVideoEffectsVision?.ImageSegmenter) {
            throw new Error("SDK MediaPipe background processor is unavailable.");
          }
          backgroundEffect = {
            type,
            blurStrength: String(args.blurStrength || "medium"),
            imageBytes: args.imageBytes || null
          };
          if (localTracks.pipeline) {
            await localTracks.pipeline.setEffect(backgroundEffect);
          } else if (type !== "none" && localTracks.video) {
            await unpublishCameraIfNeeded();
            await publishCameraIfNeeded();
          }
          return;
        }
        if (name === "setScreenShareEnabled") {
          if (args.enabled && !localTracks.screen) {
            const screen = await AgoraRTC.createScreenVideoTrack({ encoderConfig: "1080p_1" }, "disable");
            await unpublishCameraIfNeeded();
            try {
              await client.publish(screen);
              localTracks.screen = screen;
            } catch (error) {
              screen.close();
              await publishCameraIfNeeded();
              throw error;
            }
            addVideoTrack(session, { id: "agora:screen:local", participantId: session.localParticipantId, isLocal: true, isScreenShare: true, native: { track: localTracks.screen } });
            localTracks.screen.on("track-ended", () => this.command("setScreenShareEnabled", { enabled: false }).catch(() => {
            }));
          } else if (!args.enabled && localTracks.screen) {
            await client.unpublish(localTracks.screen);
            localTracks.screen.close();
            localTracks.screen = null;
            removeVideoTrack(session, "agora:screen:local");
            await publishCameraIfNeeded();
          }
          return;
        }
        if (name === "selectDevice" || name === "selectAudioOutput") {
          const selected = args.device || args;
          if (selected.kind === "microphone" && localTracks.audio) await localTracks.audio.setDevice(selected.id);
          if (selected.kind === "camera") {
            if (processedSourceId) {
              await global.RealtimeProcessedVideoBridge?.selectCamera?.(
                processedSourceId,
                selected.id
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
          if (selected.kind === "audioOutput") {
            for (const user of client.remoteUsers || []) if (user.audioTrack?.setPlaybackDevice) await user.audioTrack.setPlaybackDevice(selected.id);
          }
          return;
        }
        if (name === "switchCamera") {
          const cameras = await AgoraRTC.getCameras();
          const index = cameras.findIndex(
            (device) => device.deviceId === selectedCameraId
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
        if (name === "listDevices") return listDevices(session);
        throw new Error(`Agora does not support ${name}.`);
      },
      async attachVideo(track, container) {
        const native = track.native?.track || remoteUsers.get(track.id)?.track;
        if (native?.play) native.play(container, { fit: "contain" });
      },
      detachVideo(track, container) {
        const native = track.native?.track || remoteUsers.get(track.id)?.track;
        if (native?.stop) native.stop();
        container.replaceChildren();
      },
      async leave() {
        for (const track of [localTracks.screen, localTracks.video, localTracks.audio]) {
          if (track?.close) track.close();
        }
        providerInputTrack?.stop?.();
        providerInputTrack = null;
        localTracks.pipeline?.stop();
        localTracks.pipeline = null;
        processedSourceId = null;
        localTracks.videoPublished = false;
        await client.leave();
      },
      async dispose() {
        client.removeAllListeners?.();
      },
      async getStats() {
        const stats = client.getRTCStats?.();
        return stats ? { rttMs: Math.round(stats.RTT || 0), uploadKbps: Math.round((stats.SendBitrate || 0) / 1e3), downloadKbps: Math.round((stats.RecvBitrate || 0) / 1e3) } : null;
      }
    };
    return session;
  }

  // src/media/trtc-session.js
  function createTrtcSession(session, context) {
    const { global, StageEvents, createSdkProcessedVideo, parsePayload, providerBlock, emit, emitState, addParticipant, removeParticipant, addVideoTrack, removeVideoTrack, emitMessage, publishSnapshot, reportError, createSession, join, leave, dispose, startStats, stopStats, effectsTrack, command, listDevices, makeVideoElement, attachStreamTrack, getTrackAttachment, requireSession } = context;
    const info = providerBlock(session, "trtc");
    const sdk = global.TRTC;
    const trtc = sdk.create({ assetsPath: globalThis.__realtimeTrtcAssetsPath || new URL("assets/packages/flutter_realtime_sdk/assets/provider_web_runtime/vendors/trtc-assets/", document.baseURI).toString() });
    let audioStarted = false;
    let selectedMicrophoneId = null;
    const localVideoId = `trtc:video:${session.localParticipantId}`;
    const remoteTracks = /* @__PURE__ */ new Map();
    const refreshLocalTrack = () => {
      const track = trtc.getVideoTrack?.();
      if (track) addVideoTrack(session, { id: localVideoId, participantId: session.localParticipantId, isLocal: true, native: track });
    };
    const events = sdk.EVENT || {};
    const attachRemote = (event) => {
      const userId = String(event.userId || "");
      if (!userId) return;
      addParticipant(session, userId);
      const streamType = event.streamType || sdk.TYPE?.STREAM_TYPE_MAIN || "main";
      const trackId = `trtc:video:${userId}:${streamType}`;
      remoteTracks.set(trackId, { userId, streamType });
      addVideoTrack(session, { id: trackId, participantId: userId, isScreenShare: streamType === (sdk.TYPE?.STREAM_TYPE_SUB || "sub"), native: { userId, streamType } });
    };
    trtc.on(events.REMOTE_USER_ENTER || "remote-user-enter", (event) => {
      addParticipant(session, event.userId);
      publishSnapshot(session);
    });
    trtc.on(events.REMOTE_USER_EXIT || "remote-user-exit", (event) => {
      const userId = String(event.userId || "");
      for (const [trackId, track] of remoteTracks) {
        if (track.userId === userId) remoteTracks.delete(trackId);
      }
      removeParticipant(session, userId);
    });
    trtc.on(events.REMOTE_VIDEO_AVAILABLE || "remote-video-available", attachRemote);
    trtc.on(events.REMOTE_VIDEO_UNAVAILABLE || "remote-video-unavailable", (event) => {
      const trackId = `trtc:video:${event.userId}:${event.streamType || sdk.TYPE?.STREAM_TYPE_MAIN || "main"}`;
      remoteTracks.delete(trackId);
      removeVideoTrack(session, trackId);
    });
    trtc.on(events.CONNECTION_STATE_CHANGED || "connection-state-changed", (event) => {
      const value = String(event.state || event.currentState || "").toLowerCase();
      if (value.includes("reconnect")) emitState(session, "reconnecting");
      if (value.includes("connected")) emitState(session, "connected");
    });
    trtc.on(events.ERROR || "error", (error) => reportError(session, error));
    trtc.on(events.SCREEN_SHARE_STOPPED || "screen-share-stopped", () => {
      session.screenTrack = null;
      removeVideoTrack(session, `trtc:screen:${session.localParticipantId}`);
    });
    session.driver = {
      async join() {
        const live = session.role !== "participant";
        await trtc.enterRoom({
          sdkAppId: Number(info.sdkAppId),
          strRoomId: info.strRoomId,
          userId: info.userId,
          userSig: info.userSig,
          privateMapKey: info.privateMapKey,
          scene: live ? sdk.TYPE.SCENE_LIVE : sdk.TYPE.SCENE_RTC,
          ...live ? { role: session.role === "viewer" ? sdk.TYPE.ROLE_AUDIENCE : sdk.TYPE.ROLE_ANCHOR } : {},
          autoReceiveAudio: true,
          autoReceiveVideo: true
        });
        session.localMuted = true;
        session.localVideoEnabled = false;
      },
      async command(name, args) {
        if (name === "setMuted") {
          const muted = Boolean(args.muted);
          if (session.role === "viewer" && !muted) {
            throw new Error("TRTC audience members cannot publish microphone audio.");
          }
          if (!muted && !audioStarted) {
            await trtc.startLocalAudio({
              publish: true,
              mute: false,
              ...selectedMicrophoneId ? { option: { microphoneId: selectedMicrophoneId } } : {}
            });
            audioStarted = true;
          } else if (audioStarted) {
            await trtc.updateLocalAudio({ mute: muted });
          }
          session.localMuted = muted;
          return;
        }
        if (name === "setVideoEnabled") {
          if (args.enabled && !session.localVideoEnabled) {
            await trtc.startLocalVideo({
              publish: true,
              option: {
                fillMode: "contain",
                ...session.processedTrack ? { videoTrack: session.processedTrack } : {}
              }
            });
          } else if (!args.enabled) {
            await trtc.stopLocalVideo();
          }
          session.localVideoEnabled = Boolean(args.enabled);
          if (!args.enabled) removeVideoTrack(session, localVideoId);
          else refreshLocalTrack();
          return;
        }
        if (name === "setScreenShareEnabled") {
          if (args.enabled && !session.screenTrack) {
            await trtc.startScreenShare({ publish: true });
            const track = trtc.getVideoTrack({ streamType: sdk.TYPE.STREAM_TYPE_SUB });
            if (!track) {
              await trtc.stopScreenShare();
              throw new Error("TRTC screen capture started without a screen video track.");
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
        if (name === "switchCamera") {
          const cameras = await sdk.getCameras();
          const current = cameras.find((device) => device.deviceId === session.cameraId);
          const index = current ? cameras.indexOf(current) : -1;
          const next = cameras[(index + 1) % cameras.length];
          if (next) {
            session.cameraId = next.deviceId;
            await trtc.updateLocalVideo({ option: { cameraId: next.deviceId } });
          }
          return;
        }
        if (name === "selectDevice") {
          const selected = args.device || args;
          if (selected.kind === "microphone") {
            if (!selected.id) throw new Error("TRTC microphone device id is required.");
            if (audioStarted) await trtc.updateLocalAudio({ option: { microphoneId: selected.id } });
            selectedMicrophoneId = selected.id;
          }
          if (selected.kind === "camera") {
            session.cameraId = selected.id;
            await trtc.updateLocalVideo({ option: { cameraId: selected.id } });
          }
          return;
        }
        if (name === "listDevices") return listDevices(session);
        throw new Error(`TRTC does not support ${name}.`);
      },
      async attachProcessedTrack(track) {
        if (session.localVideoEnabled) await trtc.updateLocalVideo({ option: { videoTrack: track } });
      },
      async detachProcessedTrack() {
        await trtc.stopLocalVideo();
      },
      async attachVideo(track, container) {
        const native = track.native;
        if (native?.userId) {
          await trtc.startRemoteVideo({ userId: native.userId, streamType: native.streamType, view: container, option: { fillMode: "contain" } });
        } else {
          const mediaTrack = native?.mediaStreamTrack || native;
          if (mediaTrack && mediaTrack.kind === "video") attachStreamTrack(mediaTrack, container);
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
      async dispose() {
        trtc.destroy?.();
      },
      async getStats() {
        const statistics = session.lastTrtcStatistics;
        return statistics ? { uploadKbps: statistics.localVideo?.sendBitrate, downloadKbps: statistics.remoteVideo?.receiveBitrate, rttMs: statistics.rtt } : null;
      }
    };
    trtc.on(events.STATISTICS || "statistics", (value) => {
      session.lastTrtcStatistics = value;
    });
    return session;
  }

  // src/media/artc-session.js
  function createArtcSession(session, context) {
    const { global, StageEvents, createSdkProcessedVideo, parsePayload, providerBlock, emit, emitState, addParticipant, removeParticipant, addVideoTrack, removeVideoTrack, emitMessage, publishSnapshot, reportError, createSession, join, leave, dispose, startStats, stopStats, effectsTrack, command, listDevices, makeVideoElement, attachStreamTrack, getTrackAttachment, requireSession } = context;
    const info = providerBlock(session, "artc");
    const namespace = global.AliRtcEngine;
    const AliRtcEngine = namespace?.AliRtcEngine || namespace?.default || namespace;
    const profile = AliRtcEngine.AliRtcSdkChannelProfile;
    const roles = AliRtcEngine.AliRtcSdkClientRole;
    const engine = AliRtcEngine.createInstance ? AliRtcEngine.createInstance() : AliRtcEngine.getInstance();
    const checked = async (operation, action) => {
      const result = await action();
      if (typeof result === "number" && result !== 0) {
        throw new Error(`ARTC ${operation} failed (${result}).`);
      }
    };
    const cameraTrack = AliRtcEngine.AliRtcVideoTrack.AliRtcVideoTrackCamera;
    const screenTrack = AliRtcEngine.AliRtcVideoTrack.AliRtcVideoTrackScreen;
    const remoteVideo = /* @__PURE__ */ new Map();
    engine.on("connectionStatusChange", (status) => {
      if (status === AliRtcEngine.AliRtcConnectionStatus.AliRtcConnectionStatusReconnecting) emitState(session, "reconnecting");
      if (status === AliRtcEngine.AliRtcConnectionStatus.AliRtcConnectionStatusConnected) emitState(session, "connected");
    });
    engine.on("remoteUserOnLineNotify", (uid) => {
      addParticipant(session, uid);
      publishSnapshot(session);
    });
    engine.on("remoteUserOffLineNotify", (uid) => removeParticipant(session, uid));
    engine.on("remoteTrackAvailableNotify", (uid, audioTracks, videoTracks) => {
      const id = `artc:video:${uid}`;
      const screenId = `artc:screen:${uid}`;
      if (videoTracks & cameraTrack) {
        remoteVideo.set(id, { uid, track: cameraTrack });
        addVideoTrack(session, { id, participantId: uid, native: { uid, track: cameraTrack } });
      } else removeVideoTrack(session, id);
      if (videoTracks & screenTrack) {
        addVideoTrack(session, {
          id: screenId,
          participantId: uid,
          isScreenShare: true,
          native: { uid, track: screenTrack }
        });
      } else removeVideoTrack(session, screenId);
    });
    engine.on("error", (error) => reportError(session, error));
    session.driver = {
      async join() {
        if (session.role === "participant") engine.setChannelProfile(profile.AliRtcSdkCommunication);
        else {
          engine.setChannelProfile(profile.AliRtcInteractiveLive);
          await engine.setClientRole(session.role === "viewer" ? roles.AliRtcSdkLive : roles.AliRtcSdkInteractive);
        }
        await checked("disable camera capture", () => engine.enableLocalVideo(false));
        await checked("disable camera publication", () => engine.publishLocalVideoStream(false));
        await checked("disable microphone publication", () => engine.publishLocalAudioStream(false));
        await engine.joinChannel(info.authInfo, session.payload.displayName || info.userId);
        session.localMuted = true;
        session.localVideoEnabled = false;
      },
      async command(name, args) {
        if (name === "setMuted") {
          const muted = Boolean(args.muted);
          if (session.role === "viewer" && !muted) {
            throw new Error("ARTC viewer sessions cannot publish microphone audio.");
          }
          await checked("microphone publication", () => engine.publishLocalAudioStream(!muted));
          await checked("microphone mute", () => engine.muteLocalMic(muted));
          session.localMuted = muted;
          return;
        }
        if (name === "setVideoEnabled") {
          const enabled = Boolean(args.enabled);
          if (session.processedTrack) {
            await checked("camera mute", () => engine.muteLocalCamera(!enabled));
            await checked("camera publication", () => engine.publishLocalVideoStream(enabled));
          } else {
            await checked("camera capture", () => engine.enableLocalVideo(enabled));
            await checked("camera publication", () => engine.publishLocalVideoStream(enabled));
          }
          session.localVideoEnabled = enabled;
          if (!enabled) removeVideoTrack(session, `artc:video:${session.localParticipantId}`);
          else addVideoTrack(session, { id: `artc:video:${session.localParticipantId}`, participantId: session.localParticipantId, isLocal: true, native: { uid: session.localParticipantId, track: cameraTrack } });
          return;
        }
        if (name === "setScreenShareEnabled") {
          if (args.enabled && !session.screenTrack) {
            await checked("start screen preview", () => engine.startPreviewScreen());
            try {
              await checked("publish screen", () => engine.publishLocalScreenShareStream(true));
            } catch (error) {
              await engine.stopPreviewScreen();
              throw error;
            }
            session.screenTrack = { uid: session.localParticipantId, track: screenTrack };
            addVideoTrack(session, { id: `artc:screen:${session.localParticipantId}`, participantId: session.localParticipantId, isLocal: true, isScreenShare: true, native: session.screenTrack });
          } else if (!args.enabled && session.screenTrack) {
            try {
              await checked("unpublish screen", () => engine.publishLocalScreenShareStream(false));
            } finally {
              await engine.stopPreviewScreen();
            }
            session.screenTrack = null;
            removeVideoTrack(session, `artc:screen:${session.localParticipantId}`);
          }
          return;
        }
        if (name === "switchCamera") {
          const cameras = await AliRtcEngine.getCameraList();
          const current = engine.getCurrentCameraDeviceId?.();
          const index = cameras.findIndex((device) => device.deviceId === current);
          const next = cameras[(index + 1) % cameras.length];
          if (next) await engine.switchCamera(next.deviceId);
          return;
        }
        if (name === "selectDevice") {
          const selected = args.device || args;
          if (selected.kind === "camera") {
            engine.setCameraCapturerConfiguration({ deviceId: selected.id });
            await engine.switchCamera(selected.id);
          }
          if (selected.kind === "microphone") engine.setMicrophoneDeviceId?.(selected.id);
          return;
        }
        if (name === "listDevices") return listDevices(session);
        throw new Error(`ARTC does not support ${name}.`);
      },
      async attachProcessedTrack(track) {
        const manager = engine.publisher?.streamManager;
        if (!manager || !("cameraCaptureDisabled" in manager)) {
          throw new Error("This ARTC SDK does not support the processed video input contract.");
        }
        manager.cameraCaptureDisabled = false;
        try {
          await engine.switchCamera(void 0, track);
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
        video.style.objectFit = "contain";
      },
      detachVideo(track) {
        if (track.isLocal) engine.setLocalViewConfig(null, track.isScreenShare ? screenTrack : cameraTrack);
        else engine.setRemoteViewConfig(null, track.participantId, track.isScreenShare ? screenTrack : cameraTrack);
      },
      async leave() {
        await engine.leaveChannel();
      },
      async dispose() {
        await engine.destroy();
      },
      async getStats() {
        return session.lastArtcStats || null;
      }
    };
    engine.on("networkQuality", (stats) => {
      session.lastArtcStats = {
        rttMs: stats?.subscribe?.rtt,
        downlinkPacketLossPercent: stats?.subscribe?.loss
      };
      emit(session, { type: "stats", timestampMs: Date.now(), ...session.lastArtcStats });
    });
    return session;
  }

  // src/media/ivs-session.js
  function createIvsSession(session, context) {
    const { global, StageEvents, createSdkProcessedVideo, parsePayload, providerBlock, emit, emitState, addParticipant, removeParticipant, addVideoTrack, removeVideoTrack, emitMessage, publishSnapshot, reportError, createSession, join, leave, dispose, startStats, stopStats, effectsTrack, command, listDevices, makeVideoElement, attachStreamTrack, getTrackAttachment, requireSession } = context;
    const info = providerBlock(session, "ivs");
    const sdk = global.IVSBroadcastClient;
    if (!sdk?.Stage || !sdk?.LocalStageStream) {
      throw new Error("Amazon IVS Web Broadcast SDK is unavailable in this browser build.");
    }
    const canPublish = session.role !== "viewer" && info.capabilities?.includes("PUBLISH");
    const localStreams = [];
    const remoteStreams = /* @__PURE__ */ new Map();
    let selectedMicrophoneId = null;
    let selectedCameraId = null;
    const createLocalStream = async (kind, deviceId) => {
      if (!canPublish) throw new Error("IVS credentials do not permit publishing media.");
      if (!navigator.mediaDevices?.getUserMedia) {
        throw new Error("This browser cannot access camera or microphone media devices.");
      }
      const option = deviceId ? { deviceId: { exact: deviceId } } : true;
      const media = await navigator.mediaDevices.getUserMedia(
        kind === "audio" ? { audio: option, video: false } : { audio: false, video: option }
      );
      const tracks = media.getTracks();
      const track = tracks.find((item) => item.kind === kind);
      for (const extra of tracks) if (extra !== track) extra.stop();
      if (!track) throw new Error(`No IVS ${kind} device track was returned.`);
      try {
        return new sdk.LocalStageStream(track);
      } catch (error) {
        track.stop();
        throw error;
      }
    };
    const replacePublishedStream = (old, replacement) => {
      const oldIndex = localStreams.indexOf(old);
      if (oldIndex >= 0) localStreams.splice(oldIndex, 1, replacement);
      else localStreams.push(replacement);
      try {
        stage.refreshStrategy();
      } catch (error) {
        const replacementIndex = localStreams.indexOf(replacement);
        if (replacementIndex >= 0) localStreams.splice(replacementIndex, 1);
        if (oldIndex >= 0) localStreams.splice(oldIndex, 0, old);
        replacement.mediaStreamTrack.stop();
        throw error;
      }
      old?.mediaStreamTrack.stop();
    };
    const remoteAudioStreams = /* @__PURE__ */ new Set();
    const releaseRemoteAudio = (stream) => {
      if (stream.__audioRetry) {
        global.document.removeEventListener("pointerdown", stream.__audioRetry);
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
      shouldSubscribeToParticipant: (participant) => participant.capabilities?.has("subscribe") ? sdk.SubscribeType.AUDIO_VIDEO : sdk.SubscribeType.NONE
    });
    stage.on(StageEvents.CONNECTION, (state) => {
      if (state === sdk.StageConnectionState.CONNECTED) emitState(session, "connected");
      else if (state === sdk.StageConnectionState.CONNECTING) emitState(session, "connecting");
      else if (state === sdk.StageConnectionState.DISCONNECTED) emitState(session, "disconnected");
    });
    stage.on(StageEvents.JOINED, (participant) => {
      addParticipant(session, participant.userId || participant.id, participant.userInfo?.displayName, participant.isLocal);
      publishSnapshot(session);
    });
    stage.on(StageEvents.LEFT, (participant) => {
      const participantId = String(participant.userId || participant.id);
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
            member.isMuted = typeof stream.isMuted === "boolean" ? stream.isMuted : Boolean(participant.audioMuted);
            publishSnapshot(session);
          }
          if (stream.__audioElement) continue;
          const audio = document.createElement("audio");
          audio.autoplay = true;
          audio.srcObject = new MediaStream([stream.mediaStreamTrack]);
          document.body.append(audio);
          stream.__audioElement = audio;
          stream.__participantId = participantId;
          remoteAudioStreams.add(stream);
          audio.play().catch((error) => {
            if (stream.__audioElement !== audio) return;
            reportError(session, new Error(`IVS remote audio playback blocked: ${error.message}. Tap the page to allow sound.`));
            const retry = () => {
              stream.__audioRetry = null;
              audio.play().catch((retryError) => reportError(session, retryError));
            };
            stream.__audioRetry = retry;
            global.document.addEventListener("pointerdown", retry, { once: true });
          });
        }
      }
    });
    stage.on(StageEvents.STREAM_MUTE_CHANGED, (participant, stream) => {
      const participantId = String(participant.userId || participant.id || "");
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
        session.localMuted = true;
        session.localVideoEnabled = false;
        await stage.join();
      },
      async command(name, args) {
        if (name === "setMuted") {
          const muted = Boolean(args.muted);
          if (!muted && !session.localAudioStream) {
            const replacement = await createLocalStream("audio", selectedMicrophoneId);
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
        if (name === "setVideoEnabled") {
          const enabled = Boolean(args.enabled);
          if (enabled && !session.localVideoStream) {
            const replacement = await createLocalStream("video", selectedCameraId);
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
        if (name === "setScreenShareEnabled") {
          if (args.enabled && !session.screenTrack) {
            const media = await navigator.mediaDevices.getDisplayMedia({
              video: { width: { max: 1280 }, height: { max: 720 } }
            });
            const track = media.getVideoTracks()[0];
            if (!track) throw new Error("Browser screen capture provided no video track.");
            let localStream;
            try {
              localStream = new sdk.LocalStageStream(track);
            } catch (error) {
              track.stop();
              throw error;
            }
            const pausedCamera = session.localVideoStream;
            const cameraIndex = localStreams.indexOf(pausedCamera);
            if (cameraIndex >= 0) localStreams.splice(cameraIndex, 1);
            session.screenPausedCamera = cameraIndex >= 0 ? pausedCamera : null;
            if (cameraIndex >= 0) {
              removeVideoTrack(session, [...session.tracks.values()].find(
                (item) => item.native === pausedCamera
              )?.id);
            }
            localStreams.push(localStream);
            session.screenTrack = localStream;
            try {
              stage.refreshStrategy();
            } catch (error) {
              localStreams.splice(localStreams.indexOf(localStream), 1);
              session.screenTrack = null;
              if (session.screenPausedCamera) {
                localStreams.push(session.screenPausedCamera);
                const camera = session.screenPausedCamera;
                addVideoTrack(session, {
                  id: `ivs:local:${camera.mediaStreamTrack.id}`,
                  participantId: session.localParticipantId,
                  isLocal: true,
                  native: camera
                });
                session.screenPausedCamera = null;
                stage.refreshStrategy();
              }
              track.stop();
              throw error;
            }
            addVideoTrack(session, { id: `ivs:screen:${track.id}`, participantId: session.localParticipantId, isLocal: true, isScreenShare: true, native: localStream });
            track.addEventListener("ended", () => this.command("setScreenShareEnabled", { enabled: false }).catch(() => {
            }), { once: true });
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
                isLocal: true,
                native: camera
              });
            }
            stage.refreshStrategy();
          }
          return;
        }
        if (name === "exchangeToken") {
          if (!args.token || typeof stage.exchangeToken !== "function") {
            throw new Error("IVS token exchange requires a supported SDK and a token.");
          }
          await stage.exchangeToken(args.token);
          return;
        }
        if (name === "switchCamera") {
          throw new Error("IVS desktop camera position switching is unavailable; select a camera device instead.");
        }
        if (name === "selectDevice") {
          const selected = args.device || args;
          if (selected.kind !== "camera" && selected.kind !== "microphone") return;
          if (!selected.id) throw new Error("IVS media device id is required.");
          const old = selected.kind === "camera" ? session.localVideoStream : session.localAudioStream;
          if (selected.kind === "microphone") selectedMicrophoneId = selected.id;
          else selectedCameraId = selected.id;
          if (!old) return;
          const replacement = await createLocalStream(selected.kind === "camera" ? "video" : "audio", selected.id);
          try {
            replacement.setMuted(selected.kind === "camera" ? !session.localVideoEnabled : session.localMuted);
            if (selected.kind === "camera" && session.screenTrack) {
              session.screenPausedCamera = replacement;
              old.mediaStreamTrack.stop();
            } else {
              replacePublishedStream(old, replacement);
            }
          } catch (error) {
            replacement.mediaStreamTrack.stop();
            throw error;
          }
          if (selected.kind === "camera") {
            session.localVideoStream = replacement;
            if (old) removeVideoTrack(session, [...session.tracks.values()].find((item) => item.native === old)?.id);
            if (session.screenTrack) {
              session.screenPausedCamera = replacement;
              return;
            }
            addVideoTrack(session, { id: `ivs:local:${replacement.id}`, participantId: session.localParticipantId, isLocal: true, native: replacement });
          } else {
            session.localAudioStream = replacement;
          }
          return;
        }
        if (name === "listDevices") return listDevices(session);
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
        addVideoTrack(session, { id: `ivs:local:${track.id}`, participantId: session.localParticipantId, isLocal: true, native: replacement });
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
      async attachVideo(track, container) {
        attachStreamTrack(track.native.mediaStreamTrack, container);
      },
      detachVideo(_track, container) {
        container.replaceChildren();
      },
      async leave() {
        try {
          await stage.leave();
        } finally {
          for (const stream of [...remoteAudioStreams]) releaseRemoteAudio(stream);
          remoteStreams.clear();
          for (const stream of [...localStreams]) stream.mediaStreamTrack.stop();
          if (session.screenPausedCamera && !localStreams.includes(session.screenPausedCamera)) {
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
        const loss = values.map((item) => item.packetsLost && item.packetsSent ? item.packetsLost / item.packetsSent * 100 : 0).reduce((a, b) => a + b, 0) / values.length;
        return { uplinkPacketLossPercent: loss };
      }
    };
    return session;
  }

  // src/media/chime-session.js
  function createChimeSession(session, context) {
    const { global, StageEvents, createSdkProcessedVideo, parsePayload, providerBlock, emit, emitState, addParticipant, removeParticipant, addVideoTrack, removeVideoTrack, emitMessage, publishSnapshot, reportError, createSession, join, leave, dispose, startStats, stopStats, effectsTrack, command, listDevices, makeVideoElement, attachStreamTrack, getTrackAttachment, requireSession } = context;
    const info = session.payload;
    const meeting = info.meeting || info.Meeting;
    const attendee = info.attendee || info.Attendee;
    if (!meeting || !attendee) throw new Error("Chime join data must include meeting and attendee objects.");
    const logger = new ChimeSDK.ConsoleLogger(`media-web-${session.id}`, ChimeSDK.LogLevel.WARN);
    const deviceController = new ChimeSDK.DefaultDeviceController(logger);
    const configuration = new ChimeSDK.MeetingSessionConfiguration(meeting, attendee);
    const meetingSession = new ChimeSDK.DefaultMeetingSession(configuration, logger, deviceController);
    const audioVideo = meetingSession.audioVideo;
    let remoteAudioElement = null;
    let microphones = [];
    let selectedMicrophoneId = null;
    let activeMicrophoneId = null;
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
      if (!videoTrack || videoTrack.readyState === "ended") {
        reportError(session, new Error("Chime content share started without an active screen video track."));
        return;
      }
      session.screenTrack = videoTrack;
      addVideoTrack(session, {
        id: localContentTrackId,
        participantId: session.localParticipantId,
        isLocal: true,
        isScreenShare: true,
        native: { track: videoTrack }
      });
      videoTrack.addEventListener?.("ended", () => {
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
      }
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
          global.document.addEventListener("pointerdown", pendingAudioUnlock, { once: true });
        }
      });
    };
    const tiles = /* @__PURE__ */ new Map();
    const tileIdFor = (tile) => `chime:tile:${tile.tileId}`;
    let settleStart = null;
    const observer = {
      audioVideoDidStart() {
        settleStart?.(null);
        emitState(session, "connected");
      },
      audioVideoDidStop(status) {
        const code = typeof status?.statusCode === "function" ? status.statusCode() : status?.statusCode;
        if (settleStart) {
          settleStart(new Error(`Chime connection stopped before joining (status ${code ?? "unknown"}).`));
        } else if (session.joined && code !== ChimeSDK.MeetingSessionStatusCode.Left) {
          reportError(session, new Error(`Chime meeting disconnected (status ${code ?? "unknown"}).`));
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
      connectionDidSuggestStop() {
        emitState(session, "reconnecting", "connection-did-suggest-stop");
      }
    };
    audioVideo.addObserver(observer);
    const presenceObserver = (attendeeId, present, externalUserId) => {
      if (!attendeeId || attendeeId.includes("#")) return;
      if (present) {
        addParticipant(
          session,
          attendeeId,
          externalUserId || attendeeId,
          attendeeId === session.localParticipantId
        );
        publishSnapshot(session);
      } else {
        removeParticipant(session, attendeeId);
      }
    };
    audioVideo.realtimeSubscribeToAttendeeIdPresence(presenceObserver);
    const dataTopic = "chat";
    const dataObserver = (dataMessage) => {
      let message = "";
      try {
        if (typeof dataMessage.text === "function") message = dataMessage.text();
        else if (dataMessage.data) message = new TextDecoder().decode(dataMessage.data);
      } catch (_) {
        message = "";
      }
      emitMessage(session, {
        participantId: dataMessage.senderAttendeeId,
        displayName: dataMessage.senderExternalUserId,
        message,
        topic: dataMessage.topic || dataTopic,
        timestampMs: dataMessage.timestampMs,
        throttled: dataMessage.throttled
      });
    };
    audioVideo.realtimeSubscribeToReceiveDataMessage(dataTopic, dataObserver);
    session.meetingSession = meetingSession;
    session.driver = {
      async join() {
        if (!remoteAudioElement) {
          const audio = global.document.createElement("audio");
          audio.autoplay = true;
          audio.playsInline = true;
          audio.style.display = "none";
          global.document.body.append(audio);
          try {
            audioVideo.bindAudioElement(audio);
            remoteAudioElement = audio;
          } catch (error) {
            audio.remove();
            throw error;
          }
        }
        microphones = [];
        activeMicrophoneId = null;
        const connected = new Promise((resolve, reject) => {
          const timeout = global.setTimeout(() => {
            settleStart?.(new Error("Chime signaling timed out after 30 seconds. Check network and AWS media region."));
          }, 3e4);
          settleStart = (error) => {
            global.clearTimeout(timeout);
            settleStart = null;
            if (error) reject(error);
            else resolve();
          };
        });
        try {
          audioVideo.start();
        } catch (error) {
          settleStart?.(error);
        }
        await connected;
        audioVideo.realtimeMuteLocalAudio();
        session.localMuted = true;
        session.localVideoEnabled = false;
        playRemoteAudio();
        for (const tile of audioVideo.getAllVideoTiles()) observer.videoTileDidUpdate(tile.state());
      },
      async command(name, args) {
        if (name === "setMuted") {
          if (args.muted) {
            audioVideo.realtimeMuteLocalAudio();
          } else {
            if (!microphones.length) {
              const available = await audioVideo.listAudioInputDevices();
              if (!available.length) throw new Error("No Chime microphone is available.");
              microphones = available;
            }
            const selected = selectedMicrophoneId || microphones[0]?.deviceId;
            if (!selected) throw new Error("Chime could not resolve a microphone input device.");
            // Reuse the capture on ordinary mute/unmute; switch input only
            // when the user selected a different device while muted.
            if (activeMicrophoneId !== selected) {
              await audioVideo.startAudioInput(selected);
              activeMicrophoneId = selected;
            }
            const unmuted = await audioVideo.realtimeUnmuteLocalAudio();
            if (unmuted === false) throw new Error("Chime failed to unmute local audio.");
          }
          session.localMuted = Boolean(args.muted);
          return;
        }
        if (name === "setVideoEnabled") {
          if (args.enabled) {
            if (session.processedTrack) await audioVideo.startVideoInput(new MediaStream([session.processedTrack]));
            else {
              const cameras = await audioVideo.listVideoInputDevices();
              const cameraId = selectedCameraId || cameras[0]?.deviceId;
              if (!cameraId) throw new Error("No Chime camera is available.");
              await audioVideo.startVideoInput(cameraId);
            }
            audioVideo.startLocalVideoTile();
          } else {
            audioVideo.stopLocalVideoTile();
            if (!session.processedTrack) await audioVideo.stopVideoInput?.();
          }
          session.localVideoEnabled = Boolean(args.enabled);
          return;
        }
        if (name === "setScreenShareEnabled") {
          if (args.enabled && !session.screenTrack) {
            const generation = contentShareGeneration;
            const stream = await audioVideo.startContentShareFromScreenCapture();
            if (generation !== contentShareGeneration || session.disposed) {
              stream?.getTracks?.().forEach((track) => track.stop?.());
              throw new Error("Chime screen capture ended before content sharing started.");
            }
            contentShareStream = stream;
            publishLocalContentShare();
          } else if (!args.enabled) {
            audioVideo.stopContentShare();
            releaseLocalContentShare();
          }
          return;
        }
        if (name === "selectDevice" || name === "selectAudioOutput") {
          const selected = args.device || args;
          if (selected.kind === "microphone") {
            if (!selected.id) throw new Error("Chime microphone device id is required.");
            if (!session.localMuted) {
              await audioVideo.startAudioInput(selected.id);
              activeMicrophoneId = selected.id;
            }
            selectedMicrophoneId = selected.id;
          }
          if (selected.kind === "camera") {
            if (!selected.id) throw new Error("Chime camera device id is required.");
            if (session.localVideoEnabled && !session.processedTrack) {
              await audioVideo.startVideoInput(selected.id);
            }
            selectedCameraId = selected.id;
          }
          if (selected.kind === "audioOutput") await audioVideo.chooseAudioOutput(selected.id);
          return;
        }
        if (name === "listDevices") {
          const [microphones2, cameras, outputs] = await Promise.all([audioVideo.listAudioInputDevices(), audioVideo.listVideoInputDevices(), audioVideo.listAudioOutputDevices()]);
          return [...microphones2.map((item) => ({ id: item.deviceId, label: item.label, groupId: item.groupId, kind: "microphone" })), ...cameras.map((item) => ({ id: item.deviceId, label: item.label, groupId: item.groupId, kind: "camera" })), ...outputs.map((item) => ({ id: item.deviceId, label: item.label, groupId: item.groupId, kind: "audioOutput" }))];
        }
        if (name === "sendMessage") {
          const topic = String(args.topic || dataTopic);
          const message = String(args.message || "");
          const lifetimeMs = Number(args.lifetimeMs || 3e5);
          if (!message || !topic || lifetimeMs <= 0) throw new Error("Chime data message requires message, topic, and positive lifetimeMs.");
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
          global.document.removeEventListener("pointerdown", pendingAudioUnlock);
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
      async getStats() {
        return null;
      }
    };
    return session;
  }

  // src/bridge.js
  (function installMediaProviderBridge(global) {
    "use strict";
    const sessions = /* @__PURE__ */ new Map();
    const StageEvents = {
      CONNECTION: "stageConnectionStateChanged",
      JOINED: "stageParticipantJoined",
      LEFT: "stageParticipantLeft",
      STREAMS_ADDED: "stageParticipantStreamsAdded",
      STREAMS_REMOVED: "stageParticipantStreamsRemoved",
      STREAM_MUTE_CHANGED: "stageStreamMuteChanged",
      ERROR: "stageError"
    };
    let nextPreviewSource = 0;
    async function createSdkProcessedVideo({ effect = { type: "none" }, deviceId = null } = {}) {
      const bridge2 = global.RealtimeVideoEffectsBridge;
      if (!bridge2) return createRawPreview({ effect, deviceId });
      const id = `provider-preview-${Date.now()}-${nextPreviewSource++}`;
      await bridge2.createSource(id, { effect, cameraDeviceId: deviceId });
      return {
        get track() {
          return bridge2.getTrack(id);
        },
        setEffect: (next) => bridge2.setEffect(id, next),
        setCameraDevice: (next) => bridge2.selectCamera(id, next),
        setEnabled: (enabled) => bridge2.setEnabled(id, enabled),
        stop: () => bridge2.disposeSource(id)
      };
    }
    async function createRawPreview({ effect, deviceId }) {
      if (effect.type !== "none") throw new Error("preview.effects.unregistered");
      let track = null;
      let stopped = false;
      async function setEnabled(enabled) {
        if (!enabled) {
          track?.stop();
          track = null;
          return;
        }
        if (stopped) throw new Error("preview.disposed");
        if (track) return;
        const stream = await global.navigator.mediaDevices.getUserMedia({ audio: false, video: deviceId ? { deviceId: { exact: deviceId } } : true });
        if (stopped) {
          stream.getTracks().forEach((item) => item.stop());
          throw new Error("preview.disposed");
        }
        track = stream.getVideoTracks()[0];
      }
      await setEnabled(true);
      return {
        get track() {
          return track;
        },
        setEnabled,
        async setEffect(next) {
          if (next.type !== "none") throw new Error("preview.effects.unregistered");
        },
        async setCameraDevice(next) {
          deviceId = next;
          if (track) {
            await setEnabled(false);
            await setEnabled(true);
          }
        },
        async stop() {
          stopped = true;
          await setEnabled(false);
        }
      };
    }
    function parsePayload(value) {
      return typeof value === "string" ? JSON.parse(value) : value;
    }
    function providerBlock(session, key = session.providerId) {
      const payload = session.payload;
      const block = payload[key];
      return block && typeof block === "object" ? block : payload;
    }
    function emit(session, event) {
      if (session.disposed) return;
      const callback = global.__flutterMediaProviderOnEvent;
      if (typeof callback === "function") {
        callback(session.id, JSON.stringify(event));
      }
    }
    function emitState(session, state, reason) {
      emit(session, { type: "state", state, reason });
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
        isVideoEnabled: Boolean(current.isVideoEnabled)
      };
      session.participants.set(participant.id, participant);
      return participant;
    }
    function removeParticipant(session, id) {
      const participantId = String(id || "");
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
        native
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
          (item) => item.participantId === track.participantId && !item.isScreenShare
        );
        participant.videoTrackId = replacement?.id;
        if (!replacement) participant.isVideoEnabled = false;
      }
      publishSnapshot(session);
    }
    function emitMessage(session, { participantId, displayName, message, topic = "chat", timestampMs = Date.now(), throttled = false }) {
      emit(session, {
        type: "message",
        participantId: String(participantId || ""),
        displayName: String(displayName || participantId || ""),
        message: String(message || ""),
        topic: String(topic || "chat"),
        timestampMs: Number(timestampMs || Date.now()),
        throttled: Boolean(throttled)
      });
    }
    function publishSnapshot(session) {
      const participants = [...session.participants.values()];
      emit(session, {
        type: "snapshot",
        localParticipantId: session.localParticipantId,
        localMuted: session.localMuted,
        localVideoEnabled: session.localVideoEnabled,
        participants,
        tracks: [...session.tracks.values()].map(({ native, ...track }) => track)
      });
    }
    function reportError(session, error) {
      emit(session, {
        type: "error",
        message: error && error.message ? error.message : String(error)
      });
    }
    function createSession(providerId, id, payload) {
      const context = { global, StageEvents, createSdkProcessedVideo, parsePayload, providerBlock, emit, emitState, addParticipant, removeParticipant, addVideoTrack, removeVideoTrack, emitMessage, publishSnapshot, reportError, createSession, join, leave, dispose, startStats, stopStats, effectsTrack, command, listDevices, makeVideoElement, attachStreamTrack, getTrackAttachment, requireSession };
      const role = String(payload.role || "participant").toLowerCase();
      const session = {
        id,
        providerId,
        payload,
        role,
        localParticipantId: String(payload.participantId || ""),
        localMuted: true,
        localVideoEnabled: false,
        joined: false,
        joining: false,
        disposed: false,
        participants: /* @__PURE__ */ new Map(),
        tracks: /* @__PURE__ */ new Map(),
        attachments: /* @__PURE__ */ new Map(),
        timers: /* @__PURE__ */ new Set(),
        screenTrack: null
      };
      addParticipant(session, session.localParticipantId, payload.displayName, true);
      switch (providerId) {
        case "agora":
          return createAgoraSession(session, context);
        case "chime":
          return createChimeSession(session, context);
        case "trtc":
          return createTrtcSession(session, context);
        case "artc":
          return createArtcSession(session, context);
        case "ivs":
          return createIvsSession(session, context);
        default:
          throw new Error(`No browser SDK driver is registered for ${providerId}.`);
      }
    }
    async function join(session) {
      session.joining = true;
      session.joinAttempted = true;
      emitState(session, "connecting");
      try {
        await session.driver.join();
        if (session.disposed) {
          await session.driver.leave();
          throw new Error("media.join.cancelled");
        }
      } catch (error) {
        if (session.providerId === "chime") {
          try {
            await session.driver.leave();
            session.joinAttempted = false;
          } catch (_) {
          }
        }
        throw error;
      } finally {
        session.joining = false;
      }
      session.joined = true;
      emitState(session, "connected");
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
      session.localParticipantId = "";
      emitState(session, "ended");
      publishSnapshot(session);
    }
    async function dispose(session) {
      if (session.disposeFuture) return session.disposeFuture;
      session.disposed = true;
      stopStats(session);
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
          if (stats) emit(session, { type: "stats", timestampMs: Date.now(), ...stats });
        } catch (_) {
        }
      }, 4e3);
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
      if (!session.joined && name !== "listDevices") {
        throw new Error(`Cannot run ${name} while the session is not connected.`);
      }
      args || (args = {});
      if (session.role === "viewer" && [
        "attachProcessedVideoSource",
        "setProcessedVideoEffect",
        "setScreenShareEnabled"
      ].includes(name)) {
        throw new Error("Viewers cannot publish camera or screen video.");
      }
      if (name === "attachProcessedVideoSource" && session.providerId !== "agora") {
        const sourceId2 = String(args.sourceId || "");
        if (session.processedSourceId === sourceId2) return "";
        if (!session.driver.attachProcessedTrack) throw new Error("Provider has no processed video input.");
        const sourceTrack = effectsTrack(sourceId2);
        const track = sourceTrack.clone?.() || sourceTrack;
        try {
          await session.driver.attachProcessedTrack(track);
        } catch (error) {
          if (track !== sourceTrack) track.stop?.();
          throw error;
        }
        session.processedTrack?.stop?.();
        session.processedSourceId = sourceId2;
        session.processedTrack = track;
        publishSnapshot(session);
        return "";
      }
      if (name === "detachProcessedVideoSource" && session.providerId !== "agora") {
        await session.driver.command("setVideoEnabled", { enabled: false });
        await session.driver.detachProcessedTrack?.();
        session.processedTrack?.stop?.();
        session.processedTrack = null;
        session.processedSourceId = null;
        publishSnapshot(session);
        return "";
      }
      const sourceId = session.processedSourceId;
      if (sourceId && name === "setProcessedVideoEffect") {
        await global.RealtimeVideoEffectsBridge.setEffect(sourceId, JSON.stringify(args));
        return "";
      }
      if (sourceId && name === "selectDevice" && (args.device || args).kind === "camera") {
        await global.RealtimeProcessedVideoBridge.selectCamera(sourceId, (args.device || args).id);
        return "";
      }
      if (sourceId && name === "switchCamera") {
        const cameras = (await listDevices(session)).filter((d) => d.kind === "camera");
        const next = cameras[(cameras.findIndex((d) => d.id === session.cameraId) + 1) % cameras.length];
        if (next) {
          await global.RealtimeProcessedVideoBridge.selectCamera(sourceId, next.id);
          session.cameraId = next.id;
        }
        return "";
      }
      if (sourceId && name === "setVideoEnabled") {
        await global.RealtimeProcessedVideoBridge.setEnabled(sourceId, Boolean(args.enabled));
      }
      const result = await session.driver.command(name, args);
      publishSnapshot(session);
      return result === void 0 ? "" : JSON.stringify(result);
    }
    async function listDevices(session) {
      if (!global.navigator || !navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) return [];
      const devices = await navigator.mediaDevices.enumerateDevices();
      return devices.map((device) => ({
        id: device.deviceId,
        label: device.label,
        groupId: device.groupId,
        kind: device.kind === "audioinput" ? "microphone" : device.kind === "audiooutput" ? "audioOutput" : "camera"
      }));
    }
    function makeVideoElement(container) {
      const existing = container.querySelector("video");
      if (existing) return existing;
      const video = document.createElement("video");
      video.autoplay = true;
      video.playsInline = true;
      video.muted = false;
      video.style.width = "100%";
      video.style.height = "100%";
      video.style.objectFit = "contain";
      container.replaceChildren(video);
      return video;
    }
    function attachStreamTrack(track, container) {
      const video = makeVideoElement(container);
      video.srcObject = new MediaStream([track]);
      video.play().catch(() => {
      });
      return video;
    }
    function getTrackAttachment(session, trackId) {
      return session.attachments.get(String(trackId));
    }
    const bridge = {
      // Version of the Dart/JS contract, independent of the pub release number.
      bridgeVersion: 1,
      async createLocalPreview(providerId, previewId, serializedArgs) {
        const args = parsePayload(serializedArgs || "{}") || {};
        if (sessions.has(previewId)) {
          throw new Error(`Duplicate local preview session ${previewId}.`);
        }
        let pipeline = null;
        let creatingPipeline = null;
        let effect = args.backgroundEffect || {
          type: "none",
          blurStrength: "medium"
        };
        let cameraId = args.cameraId || null;
        const preview = {
          id: previewId,
          providerId,
          payload: {},
          role: String(args.role || "participant"),
          localParticipantId: `preview:${previewId}`,
          localMuted: !Boolean(args.microphoneEnabled),
          localVideoEnabled: args.cameraEnabled === true,
          joined: true,
          participants: /* @__PURE__ */ new Map(),
          tracks: /* @__PURE__ */ new Map(),
          attachments: /* @__PURE__ */ new Map(),
          timers: /* @__PURE__ */ new Set(),
          screenTrack: null
        };
        const trackId = `preview:video:${previewId}`;
        addParticipant(
          preview,
          preview.localParticipantId,
          "Local preview",
          true
        );
        async function ensurePipeline() {
          if (pipeline) return pipeline;
          if (creatingPipeline) return creatingPipeline;
          creatingPipeline = (async () => {
            const created = await createSdkProcessedVideo({ effect, deviceId: cameraId });
            if (!preview.joined) {
              await created.stop();
              throw new Error("Local preview was disposed while enabling the camera.");
            }
            pipeline = created;
            addVideoTrack(preview, {
              id: trackId,
              participantId: preview.localParticipantId,
              isLocal: true,
              native: { mediaStreamTrack: pipeline.track }
            });
            return pipeline;
          })();
          try {
            return await creatingPipeline;
          } finally {
            creatingPipeline = null;
          }
        }
        if (preview.localVideoEnabled) {
          await (await ensurePipeline()).setEnabled(true);
        }
        preview.driver = {
          async command(name, commandArgs) {
            if (name === "setMuted") {
              preview.localMuted = Boolean(commandArgs.muted);
              return;
            }
            if (name === "setVideoEnabled") {
              const enabled = Boolean(commandArgs.enabled);
              const capture = enabled ? await ensurePipeline() : pipeline;
              if (capture) await capture.setEnabled(enabled);
              if (enabled && capture) addVideoTrack(preview, { id: trackId, participantId: preview.localParticipantId, isLocal: true, native: { mediaStreamTrack: capture.track } });
              else removeVideoTrack(preview, trackId);
              preview.localVideoEnabled = enabled;
              return;
            }
            if (name === "setBackgroundEffect") {
              effect = {
                type: String(commandArgs.type || "none"),
                blurStrength: String(commandArgs.blurStrength || "medium"),
                imageBytes: commandArgs.imageBytes || null
              };
              if (pipeline) await pipeline.setEffect(effect);
              return;
            }
            if (name === "selectDevice") {
              const selected = commandArgs.device || commandArgs;
              if (selected.kind === "camera") {
                cameraId = selected.id;
                if (pipeline) await pipeline.setCameraDevice(cameraId);
              }
              return;
            }
            if (name === "listDevices") return listDevices(preview);
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
          }
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
        return typeof result === "string" ? result : JSON.stringify(result || {});
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
      }
    };
    function requireSession(providerId, sessionId) {
      const session = sessions.get(sessionId);
      if (!session || session.providerId !== providerId) throw new Error(`Unknown ${providerId} session ${sessionId}.`);
      return session;
    }
    global.MediaProviderBridge = bridge;
  })(globalThis);
})();
