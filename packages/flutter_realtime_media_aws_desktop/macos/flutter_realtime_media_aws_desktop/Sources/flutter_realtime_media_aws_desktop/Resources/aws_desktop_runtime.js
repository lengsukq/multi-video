(function installAwsDesktopRuntime(global) {
  'use strict';

  const native = global.webkit && global.webkit.messageHandlers
    ? global.webkit.messageHandlers.awsDesktop
    : null;
  const bindings = new Map();
  const snapshots = new Map();
  const pendingChatTokens = new Map();
  let nextChatTokenRequestId = 0;
  const processedSources = new Map();
  const processedProviders = new Map();
  const processedProviderOperations = new Map();

  function processedSourceKey(sourceId) {
    return String(sourceId).toLowerCase();
  }

  function enqueueProcessedProviderOperation(providerKey, operation) {
    const previous = processedProviderOperations.get(providerKey) || Promise.resolve();
    const current = previous.catch(function() {}).then(operation);
    processedProviderOperations.set(providerKey, current);
    return current;
  }

  function isCurrentProcessedProvider(providerKey, generation) {
    const provider = processedProviders.get(providerKey);
    return Boolean(provider && provider.generation === generation);
  }

  function releaseProcessedSourceReference(sourceKey) {
    const source = processedSources.get(sourceKey);
    if (!source) return;
    source.references = Math.max(0, source.references - 1);
    if (source.references === 0) disposeProcessedSource(source.sourceId);
  }

  function failProcessedSource(source, message) {
    if (!source || source.closed || source.failed) return;
    source.failed = true;
    global.clearTimeout(source.timer);
    if (source.image) {
      source.image.onload = null;
      source.image.onerror = null;
      source.image.src = '';
      source.image = null;
    }
    source.track.enabled = false;
    source.track.stop();
    post({ kind: 'processedVideoError', sourceId: source.sourceId, message: String(message) });
  }

  function getProcessedSource(sourceId) {
    const source = processedSources.get(processedSourceKey(sourceId));
    if (!source || source.closed) throw new Error('Unknown native processed video source: ' + sourceId);
    return source;
  }

  // This runtime never performs segmentation or opens a camera. Every image is
  // an encoded view of the shared native processor's output pixel buffer.
  function createProcessedSource(sourceId) {
    const sourceKey = processedSourceKey(sourceId);
    const existing = processedSources.get(sourceKey);
    if (existing) return existing;
    const canvas = document.createElement('canvas');
    canvas.width = 1280;
    canvas.height = 720;
    const context = canvas.getContext('2d', { alpha: false });
    if (!context || typeof canvas.captureStream !== 'function') {
      throw new Error('This WebKit version cannot consume native processed video.');
    }
    context.fillStyle = '#000';
    context.fillRect(0, 0, canvas.width, canvas.height);
    const stream = canvas.captureStream(0);
    const track = stream.getVideoTracks()[0];
    if (!track || typeof track.requestFrame !== 'function') {
      stream.getTracks().forEach(function(value) { value.stop(); });
      throw new Error('WebKit does not expose canvas video frame input.');
    }
    const source = { sourceId: sourceId, references: 0, canvas: canvas, context: context,
      stream: stream, track: track, enabled: true, closed: false, failed: false,
      timer: null, image: null, requestIndex: 0, pendingTimestamp: null, renderedTimestamp: null, loadFrame: null };
    processedSources.set(sourceKey, source);
    track.requestFrame();

    function loadFrame() {
      if (source.closed || source.failed || !source.enabled || source.image) return;
      if (source.pendingTimestamp === source.renderedTimestamp && source.requestIndex > 0) return;
      const timestamp = source.pendingTimestamp;
      const image = new Image();
      source.image = image;
      image.crossOrigin = 'anonymous';
      image.onload = function() {
        source.image = null;
        if (source.closed || source.failed) return;
        try {
          if (source.enabled) {
            if (canvas.width !== image.naturalWidth || canvas.height !== image.naturalHeight) {
              canvas.width = image.naturalWidth;
              canvas.height = image.naturalHeight;
            }
            context.drawImage(image, 0, 0, canvas.width, canvas.height);
            track.requestFrame();
            source.renderedTimestamp = timestamp;
          }
          // Decode the newest pending frame immediately, without a second FPS timer.
          if (source.pendingTimestamp !== timestamp) loadFrame();
        } catch (error) {
          failProcessedSource(source, error);
        }
      };
      image.onerror = function() {
        source.image = null;
        failProcessedSource(source, 'The native processed video frame could not be decoded.');
      };
      image.src = 'realtime-video://' + encodeURIComponent(sourceId) + '/frame?request=' + String(++source.requestIndex);
    }
    source.loadFrame = loadFrame;
    loadFrame();
    return source;
  }

  function disposeProcessedSource(sourceId) {
    const key = processedSourceKey(sourceId);
    const source = processedSources.get(key);
    if (!source) return;
    source.closed = true;
    global.clearTimeout(source.timer);
    if (source.image) { source.image.onload = null; source.image.onerror = null; source.image.src = ''; }
    source.stream.getTracks().forEach(function(track) { track.stop(); });
    source.canvas.width = 0;
    source.canvas.height = 0;
    processedSources.delete(key);
  }

  global.RealtimeVideoEffectsBridge = {
    getTrack: function(sourceId) { return getProcessedSource(sourceId).track; },
    setEnabled: async function(sourceId, enabled) {
      const source = getProcessedSource(sourceId);
      if (enabled && source.failed) throw new Error('Native processed video input failed.');
      source.enabled = Boolean(enabled);
      source.track.enabled = Boolean(enabled);
      if (!enabled) {
        source.context.fillStyle = '#000';
        source.context.fillRect(0, 0, source.canvas.width, source.canvas.height);
        source.track.requestFrame();
      } else {
        source.loadFrame();
      }
    },
    setEffect: async function() { throw new Error('Configure the effect through the native SDK bridge.'); },
    selectCamera: async function() { throw new Error('Select the camera through the native SDK bridge.'); }
  };

  function post(value) {
    if (native) native.postMessage(value);
  }

  global.__flutterMediaProviderOnEvent = function(sessionId, serializedEvent) {
    let event;
    try {
      event = typeof serializedEvent === 'string'
        ? JSON.parse(serializedEvent)
        : serializedEvent;
    } catch (error) {
      event = { type: 'error', message: String(error) };
    }
    if (event && event.type === 'snapshot') snapshots.set(sessionId, event);
    post({ kind: 'event', sessionId: sessionId, event: event });
  };

  global.__flutterIvsChatOnEvent = function(sessionId, type, serializedPayload) {
    let payload;
    try {
      payload = typeof serializedPayload === 'string'
        ? JSON.parse(serializedPayload)
        : serializedPayload;
    } catch (error) {
      payload = { type: 'error', code: -1, message: String(error) };
    }
    post({
      kind: 'chatEvent',
      sessionId: sessionId,
      event: Object.assign({ type: type }, payload || {}),
    });
  };

  global.__flutterIvsChatRequestToken = function(sessionId) {
    return new Promise(function(resolve, reject) {
      const requestId = 'ivs-chat-token-' + String(++nextChatTokenRequestId);
      const timeout = global.setTimeout(function() {
        pendingChatTokens.delete(requestId);
        reject(new Error('Timed out waiting for refreshed IVS Chat credentials.'));
      }, 30000);
      pendingChatTokens.set(requestId, {
        resolve: resolve,
        reject: reject,
        timeout: timeout,
      });
      post({
        kind: 'chatTokenRequest',
        requestId: requestId,
        sessionId: sessionId,
      });
    });
  };

  function requireBridge() {
    if (!global.MediaProviderBridge) {
      throw new Error('MediaProviderBridge is unavailable in the AWS desktop runtime.');
    }
    return global.MediaProviderBridge;
  }

  async function invoke(providerId, sessionId, operation, payload) {
    const bridge = requireBridge();
    switch (operation) {
      case 'create':
        return bridge.create(providerId, sessionId, JSON.stringify(payload || {}));
      case 'join':
        return bridge.join(providerId, sessionId);
      case 'leave':
        return bridge.leave(providerId, sessionId);
      case 'dispose':
        return bridge.dispose(providerId, sessionId);
      case 'command':
        return bridge.command(
          providerId,
          sessionId,
          String(payload && payload.name || ''),
          JSON.stringify(payload && payload.args || {}),
        );
      default:
        throw new Error('Unsupported AWS desktop operation: ' + operation);
    }
  }

  async function bindTrack(providerId, sessionId, trackId, viewKey) {
    unbindTrack(viewKey);
    const container = document.createElement('div');
    container.className = 'capture';
    container.id = 'aws-desktop-' + String(viewKey).replace(/[^a-zA-Z0-9_-]/g, '_');
    document.body.appendChild(container);
    await requireBridge().attachVideo(providerId, sessionId, trackId, container.id);

    const canvas = document.createElement('canvas');
    const context = canvas.getContext('2d', { alpha: false });
    const binding = { providerId: providerId, sessionId: sessionId, trackId: trackId,
      container: container, frameHandle: null, video: null, closed: false,
      usesVideoCallback: false, nextFrameAt: 0, lastMediaTime: null };
    bindings.set(viewKey, binding);

    function render(now, mediaTime) {
      if (binding.closed) return;
      const video = container.querySelector('video');
      if (video && video.readyState >= 2 && video.videoWidth && video.videoHeight &&
          (mediaTime == null || mediaTime !== binding.lastMediaTime) &&
          (!binding.nextFrameAt || now + 1 >= binding.nextFrameAt)) {
        try {
          const scale = Math.min(1, 960 / video.videoWidth);
          const width = Math.max(1, Math.round(video.videoWidth * scale));
          const height = Math.max(1, Math.round(video.videoHeight * scale));
          if (canvas.width !== width || canvas.height !== height) {
            canvas.width = width; canvas.height = height;
          }
          context.drawImage(video, 0, 0, width, height);
          post({ kind: 'frame', viewKey: viewKey,
            data: canvas.toDataURL('image/jpeg', 0.72), width: width, height: height });
          binding.lastMediaTime = mediaTime;
          binding.nextFrameAt = !binding.nextFrameAt || now - binding.nextFrameAt > 1000 / 30
            ? now + 1000 / 30 : binding.nextFrameAt + 1000 / 30;
        } catch (_) {}
      }
      schedule();
    }

    function schedule() {
      if (binding.closed) return;
      const video = container.querySelector('video');
      binding.video = video;
      binding.usesVideoCallback = Boolean(video && typeof video.requestVideoFrameCallback === 'function');
      binding.frameHandle = binding.usesVideoCallback
        ? video.requestVideoFrameCallback((now, metadata) => render(now, metadata.mediaTime))
        : global.requestAnimationFrame(now => render(now, video && video.currentTime));
    }
    schedule();
  }

  function unbindTrack(viewKey) {
    const binding = bindings.get(viewKey);
    if (!binding) return;
    binding.closed = true;
    if (binding.usesVideoCallback) binding.video?.cancelVideoFrameCallback(binding.frameHandle);
    else global.cancelAnimationFrame(binding.frameHandle);
    try {
      requireBridge().detachVideo(
        binding.providerId,
        binding.sessionId,
        binding.trackId,
        binding.container.id,
      );
    } catch (_) {}
    binding.container.remove();
    bindings.delete(viewKey);
  }

  global.AwsDesktopRuntime = {
    notifyProcessedFrame: function(sourceId, timestampNs) {
      const source = processedSources.get(processedSourceKey(sourceId));
      if (!source || source.closed || source.failed) return;
      const timestamp = String(timestampNs);
      if (source.pendingTimestamp === timestamp) return;
      source.pendingTimestamp = timestamp;
      source.loadFrame();
    },
    invoke: invoke,
    bindTrack: bindTrack,
    unbindTrack: unbindTrack,
    snapshot: function(sessionId) { return snapshots.get(sessionId) || null; },
    attachProcessedVideo: async function(providerId, sessionId, sourceId, generation) {
      const providerKey = String(providerId) + ':' + String(sessionId);
      const normalizedSourceId = String(sourceId);
      const sourceKey = processedSourceKey(normalizedSourceId);
      const current = processedProviders.get(providerKey);
      const requestedGeneration = Number.isSafeInteger(Number(generation))
        ? Number(generation)
        : ((current && current.generation) || 0) + 1;
      if (current && requestedGeneration < current.generation) return false;
      if (current && requestedGeneration === current.generation && current.sourceKey) {
        return current.sourceKey === sourceKey;
      }
      if (current && current.sourceKey) releaseProcessedSourceReference(current.sourceKey);
      processedProviders.set(providerKey, {
        sourceId: null, sourceKey: null, generation: requestedGeneration,
      });
      if (!await global.AwsDesktopRuntime.canConsumeProcessedVideo()) {
        throw new Error('WebKit does not support the native processed video transport.');
      }
      if (!isCurrentProcessedProvider(providerKey, requestedGeneration)) return false;
      const source = createProcessedSource(normalizedSourceId);
      source.references += 1;
      processedProviders.set(providerKey, {
        sourceId: normalizedSourceId,
        sourceKey: sourceKey,
        generation: requestedGeneration,
      });
      try {
        await enqueueProcessedProviderOperation(providerKey, function() {
          if (!isCurrentProcessedProvider(providerKey, requestedGeneration)) return false;
          return invoke(providerId, sessionId, 'command', {
            name: 'attachProcessedVideoSource', args: { sourceId: normalizedSourceId }
          });
        });
        return true;
      } catch (error) {
        if (isCurrentProcessedProvider(providerKey, requestedGeneration)) {
          const attached = processedProviders.get(providerKey);
          if (attached && attached.sourceKey) releaseProcessedSourceReference(attached.sourceKey);
          processedProviders.set(providerKey, {
            sourceId: null, sourceKey: null, generation: requestedGeneration,
          });
          await enqueueProcessedProviderOperation(providerKey, function() {
            return invoke(providerId, sessionId, 'command', {
              name: 'detachProcessedVideoSource', args: {}
            });
          }).catch(function() {});
        }
        throw error;
      }
    },
    detachProcessedVideo: async function(providerId, sessionId, sourceId, generation) {
      const providerKey = String(providerId) + ':' + String(sessionId);
      const current = processedProviders.get(providerKey);
      const requestedGeneration = Number.isSafeInteger(Number(generation))
        ? Number(generation)
        : ((current && current.generation) || 0) + 1;
      if (current && requestedGeneration < current.generation) return false;
      if (current && current.sourceKey && sourceId &&
          current.sourceKey !== processedSourceKey(sourceId)) return false;
      if (current && current.sourceKey) releaseProcessedSourceReference(current.sourceKey);
      processedProviders.set(providerKey, {
        sourceId: null, sourceKey: null, generation: requestedGeneration,
      });
      try {
        return await enqueueProcessedProviderOperation(providerKey, function() {
          if (!isCurrentProcessedProvider(providerKey, requestedGeneration)) return false;
          return invoke(providerId, sessionId, 'command', {
            name: 'detachProcessedVideoSource', args: {}
          });
        });
      } catch (error) {
        throw error;
      }
    },
    failProcessedVideo: function(sourceId, message) {
      const source = processedSources.get(processedSourceKey(sourceId));
      if (source) failProcessedSource(source, message);
    },
    disposeProcessedVideo: disposeProcessedSource,
    canConsumeProcessedVideo: async function() {
      const canvas = document.createElement('canvas');
      if (typeof canvas.captureStream !== 'function') return false;
      const context = canvas.getContext('2d');
      if (!context) return false;
      const loaded = await new Promise(function(resolve) {
        const image = new Image();
        const timeout = global.setTimeout(function() { resolve(null); }, 3000);
        image.crossOrigin = 'anonymous';
        image.onload = function() { global.clearTimeout(timeout); resolve(image); };
        image.onerror = function() { global.clearTimeout(timeout); resolve(null); };
        image.src = 'realtime-video://probe/frame';
      });
      if (!loaded) return false;
      try { context.drawImage(loaded, 0, 0); canvas.toDataURL(); }
      catch (_) { return false; }
      const stream = canvas.captureStream(0);
      const track = stream.getVideoTracks()[0];
      const supported = Boolean(track && typeof track.requestFrame === 'function');
      stream.getTracks().forEach(function(value) { value.stop(); });
      return supported;
    },
  };

  global.AwsDesktopChatRuntime = {
    invoke: async function(operation, sessionId, payload) {
      const bridge = global.IvsChatMessagingBridge;
      if (!bridge) throw new Error('The bundled Amazon IVS Chat bridge is unavailable.');
      switch (operation) {
        case 'create':
          return bridge.create(sessionId, JSON.stringify(payload || {}));
        case 'connect':
          return bridge.connect(sessionId);
        case 'command':
          return bridge.command(
            sessionId,
            String(payload && payload.name || ''),
            JSON.stringify(payload && payload.arguments || {}),
          );
        case 'dispose':
          return bridge.dispose(sessionId);
        default:
          throw new Error('Unsupported Amazon IVS Chat operation: ' + operation);
      }
    },
    resolveToken: function(requestId, response, errorMessage) {
      const pending = pendingChatTokens.get(requestId);
      if (!pending) return false;
      pendingChatTokens.delete(requestId);
      global.clearTimeout(pending.timeout);
      if (errorMessage) {
        pending.reject(new Error(String(errorMessage)));
      } else {
        pending.resolve(response);
      }
      return true;
    },
  };

  post({ kind: 'ready' });
})(globalThis);
