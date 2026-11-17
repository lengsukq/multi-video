(function installProcessedVideoBridge(global) {
  if (global.RealtimeProcessedVideoBridge) return;
  const sources = new Map();
  function requireSource(id) {
    const source = sources.get(id);
    if (!source) throw new Error('processedVideo.source.unregistered');
    return source;
  }
  global.RealtimeProcessedVideoBridge = Object.freeze({
    register(id, source) {
      if (!id || sources.has(id)) throw new Error('processedVideo.source.duplicate');
      sources.set(id, source);
    },
    unregister(id) { sources.delete(id); },
    getTrack(id) { return requireSource(id).track; },
    setEnabled(id, enabled) { return requireSource(id).setEnabled(enabled); },
    selectCamera(id, deviceId) { return requireSource(id).setCameraDevice(deviceId); },
    attachPreviewElement(id, element, fit) {
      const source = requireSource(id);
      if (source.attachPreviewElement) return source.attachPreviewElement(element, fit);
      const video = global.document.createElement('video');
      video.autoplay = true; video.muted = true; video.playsInline = true;
      video.style.width = '100%'; video.style.height = '100%'; video.style.objectFit = fit;
      video.srcObject = new global.MediaStream([source.track]);
      element.replaceChildren(video);
      void video.play().catch(() => {}); // Browser playback policy; host still controls source ownership.
    },
  });
})(globalThis);

(function installRealtimeVideoEffectsBridge(global) {
  'use strict';

  const assetUrl = (relativePath) =>
    new URL(
      `assets/packages/flutter_realtime_video_effects/assets/web/${relativePath}`,
      document.baseURI,
    ).toString();

  let visionFilesetPromise = null;

  async function visionFileset() {
    const runtime = global.SdkVideoEffectsVision;
    if (!runtime?.FilesetResolver || !runtime?.ImageSegmenter) {
      throw new Error(
        'SDK video effects runtime is unavailable: MediaPipe Vision was not loaded.',
      );
    }
    if (!visionFilesetPromise) {
      visionFilesetPromise = runtime.FilesetResolver.forVisionTasks(
        assetUrl('wasm'),
      ).catch((error) => {
        visionFilesetPromise = null;
        throw error;
      });
    }
    return visionFilesetPromise;
  }

  async function createSegmenter() {
    const runtime = global.SdkVideoEffectsVision;
    const fileset = await visionFileset();
    return runtime.ImageSegmenter.createFromOptions(fileset, {
      baseOptions: {
        modelAssetPath: assetUrl(
          'models/selfie_segmenter_landscape.tflite',
        ),
        delegate: 'GPU',
      },
      runningMode: 'VIDEO',
      outputConfidenceMasks: true,
      outputCategoryMask: false,
    });
  }

  async function createFaceDetector() {
    const runtime = global.SdkVideoEffectsVision;
    if (!runtime?.FaceDetector) throw new Error('SDK face protection runtime is unavailable.');
    return runtime.FaceDetector.createFromOptions(await visionFileset(), {
      baseOptions: {modelAssetPath: assetUrl('models/blaze_face_short_range.tflite'), delegate: 'GPU'},
      runningMode: 'VIDEO', minDetectionConfidence: 0.75,
    });
  }

  function blurRadius(strength) {
    if (strength === 'low') return 10;
    if (strength === 'high') return 28;
    return 18;
  }

  function fallbackBlurScale(strength) {
    if (strength === 'low') return 0.1;
    if (strength === 'high') return 0.04;
    return 0.0625;
  }

  async function createProcessedVideo({
    effect = { type: 'none', blurStrength: 'medium' },
    deviceId = null,
    width = 1280,
    height = 720,
    frameRate = 24,
    onError = () => {},
  } = {}) {
    const mediaDevices = global.navigator?.mediaDevices;
    if (!mediaDevices?.getUserMedia) {
      throw new Error('Browser camera capture is unavailable.');
    }
    if (typeof document === 'undefined') {
      throw new Error('SDK video effects require a browser document.');
    }

    const video = document.createElement('video');
    video.autoplay = true;
    video.muted = true;
    video.playsInline = true;

    const outputCanvas = document.createElement('canvas');
    const foregroundCanvas = document.createElement('canvas');
    const maskCanvas = document.createElement('canvas');
    const blurCanvas = document.createElement('canvas');
    let downsampleCanvas = null;
    let downsampleContext = null;
    const outputContext = outputCanvas.getContext('2d', {
      alpha: false,
      desynchronized: true,
    });
    const foregroundContext = foregroundCanvas.getContext('2d', {
      alpha: true,
      desynchronized: true,
    });
    const maskContext = maskCanvas.getContext('2d', {
      alpha: true,
      willReadFrequently: true,
    });
    const blurContext = blurCanvas.getContext('2d', {
      alpha: false,
      desynchronized: true,
    });
    if (!outputContext || !foregroundContext || !maskContext || !blurContext) {
      throw new Error('Canvas 2D rendering is unavailable.');
    }
    const supportsCanvasFilter = 'filter' in blurContext;

    let sourceTrack = null;
    let sourceStream = null;
    let outputTrack = null;
    let currentEffect = { type: 'none', blurStrength: 'medium' };
    let backgroundImage = null;
    let enabled = true;
    let effectRevision = 0;
    let segmenter = null;
    let segmenterPromise = null;
    let faceDetector = null;
    let faceBoxes = [];
    let faceDetectCounter = 0;
    let outputSuspended = false;
    let lastFailure = null;
    let cancelReadyWait = null;
    let latestMask = null;
    let stopped = false;
    let frameHandle = null;
    let lastSegmentationAt = 0;
    let nextFrameAt = 0;
    let lastVideoFrame = null;
    let maskPixels = null;
    let maskImageData = null;
    const frameInterval = 1000 / frameRate;

    async function openCamera(nextDeviceId = null) {
      const nextStream = await mediaDevices.getUserMedia({
        audio: false,
        video: {
          width: { ideal: width },
          height: { ideal: height },
          frameRate: { ideal: frameRate, max: Math.max(frameRate, 30) },
          ...(nextDeviceId === 'front' || nextDeviceId === 'back'
            ? {facingMode: {ideal: nextDeviceId === 'front' ? 'user' : 'environment'}}
            : nextDeviceId ? { deviceId: { exact: String(nextDeviceId) } }
            : { facingMode: 'user' }),
        },
      });
      if (stopped) { nextStream.getTracks().forEach((track) => track.stop()); throw new Error('The video source was disposed.'); }
      const nextTrack = nextStream.getVideoTracks()[0];
      if (!nextTrack) {
        nextStream.getTracks().forEach((track) => track.stop());
        throw new Error('No camera video track was returned.');
      }

      const previousTrack = sourceTrack;
      const previousStream = sourceStream;
      nextTrack.enabled = enabled;
      video.srcObject = nextStream;
      try { await video.play?.(); } catch (error) {
        nextStream.getTracks().forEach((track) => track.stop());
        video.srcObject = previousStream;
        throw error;
      }
      if (stopped) { nextStream.getTracks().forEach((track) => track.stop()); video.srcObject = null; throw new Error('The video source was disposed.'); }
      sourceTrack = nextTrack;
      sourceStream = nextStream;
      latestMask = null;
      faceBoxes = [];
      faceDetectCounter = 0;
      nextFrameAt = 0;
      lastVideoFrame = null;
      previousTrack?.stop?.();
      previousStream?.getTracks?.().forEach((track) => {
        if (track !== previousTrack) track.stop?.();
      });

      const settings = nextTrack.getSettings?.() || {};
      const outputWidth = Math.max(
        1,
        Number(settings.width || video.videoWidth || width),
      );
      const outputHeight = Math.max(
        1,
        Number(settings.height || video.videoHeight || height),
      );
      outputCanvas.width = outputWidth;
      outputCanvas.height = outputHeight;
      foregroundCanvas.width = outputWidth;
      foregroundCanvas.height = outputHeight;

      if (!outputTrack) {
        // Use frameRate-backed captureStream so cloned provider tracks receive
        // rendered canvas frames across all browsers (including Safari/WebKit,
        // where captureStream(0) clones do not receive requestFrame() updates).
        const outputStream = outputCanvas.captureStream(frameRate);
        outputTrack = outputStream.getVideoTracks()[0];
        if (!outputTrack) {
          throw new Error('Canvas capture did not produce a video track.');
        }
        outputTrack.enabled = enabled && !outputSuspended;
      }
    }

    async function ensureSegmenter() {
      if (segmenter) return;
      if (!segmenterPromise) {
        segmenterPromise = (async () => {
          const created = await createSegmenter();
          let faces;
          try { faces = await createFaceDetector(); }
          catch (error) { created.close?.(); throw error; }
          if (stopped) { created.close?.(); faces.close?.(); throw new Error('The video source was disposed.'); }
          segmenter = created; faceDetector = faces;
        })().finally(() => { segmenterPromise = null; });
      }
      await segmenterPromise;
    }

    function blankOutput() {
      outputContext.save();
      if (supportsCanvasFilter) outputContext.filter = 'none';
      outputContext.fillStyle = '#000';
      outputContext.fillRect(0, 0, outputCanvas.width, outputCanvas.height);
      outputContext.restore();
      outputTrack?.requestFrame?.();
    }

    function failClosed(error) {
      lastFailure = error;
      outputSuspended = true;
      latestMask = null;
      // Cloned supplier tracks share the canvas, but their enabled flags are
      // independent. Clear that shared canvas as well as disabling our track.
      blankOutput();
      if (sourceTrack) sourceTrack.enabled = false;
      if (outputTrack) outputTrack.enabled = false;
      onError(error);
    }

    function videoIsReady() {
      return video.readyState >= 2 && video.videoWidth > 0 && video.videoHeight > 0;
    }

    async function renderReadyFrame() {
      if (!enabled || stopped || outputSuspended) return;
      if (!videoIsReady()) {
        await new Promise((resolve, reject) => {
          const finish = (error) => {
            global.clearTimeout(timeout);
            video.removeEventListener('loadeddata', check);
            video.removeEventListener('resize', check);
            cancelReadyWait = null;
            if (error) reject(error); else resolve();
          };
          const check = () => { if (videoIsReady()) finish(); };
          const timeout = global.setTimeout(
            () => finish(new Error('videoEffects.cameraFrame.timeout')),
            10000,
          );
          cancelReadyWait = () => finish(new Error('videoEffects.source.disposed'));
          video.addEventListener('loadeddata', check);
          video.addEventListener('resize', check);
          check();
        });
      }
      await updateSegmentation(global.performance.now());
      drawFrame();
    }

    function updateMask(mask) {
      latestMask = null;
      if (!mask) return;
      const values = mask.getAsFloat32Array?.();
      const maskWidth = Number(mask.width || 0);
      const maskHeight = Number(mask.height || 0);
      if (!values || maskWidth <= 0 || maskHeight <= 0) return;
      if (maskCanvas.width !== maskWidth) maskCanvas.width = maskWidth;
      if (maskCanvas.height !== maskHeight) maskCanvas.height = maskHeight;
      if (!maskPixels || maskImageData.width !== maskWidth || maskImageData.height !== maskHeight) {
        maskPixels = new Uint8ClampedArray(maskWidth * maskHeight * 4);
        maskImageData = new ImageData(maskPixels, maskWidth, maskHeight);
      }
      const pixels = maskPixels;
      // The landscape model outputs a small matte. Expand uncertain person
      // edges by at most one matte pixel and remap their confidence so hair
      // and shoulders stay in the sharp foreground. Feathering is confined
      // to the outer edge rather than blending blur through the whole person.
      for (let y = 0; y < maskHeight; y += 1) {
        const rowOffset = y * maskWidth;
        const yMin = y > 0 ? y - 1 : 0;
        const yMax = y + 1 < maskHeight ? y + 1 : maskHeight - 1;
        for (let x = 0; x < maskWidth; x += 1) {
          const idx = rowOffset + x;
          let confidence = Number(values[idx] || 0);
          if (confidence < 0) confidence = 0;
          else if (confidence > 1) confidence = 1;
          const xMin = x > 0 ? x - 1 : 0;
          const xMax = x + 1 < maskWidth ? x + 1 : maskWidth - 1;
          for (let ny = yMin; ny <= yMax; ny += 1) {
            const nRow = ny * maskWidth;
            const dy = ny - y;
            for (let nx = xMin; nx <= xMax; nx += 1) {
              const dx = nx - x;
              if (dx === 0 && dy === 0) continue;
              const weight = dx !== 0 && dy !== 0 ? 0.55 : 0.7;
              const neighbor = Number(values[nRow + nx] || 0) * weight;
              if (neighbor > confidence) confidence = neighbor;
            }
          }
          if (confidence > 1) confidence = 1;
          let alpha = 0;
          if (confidence > 0.1) {
            const t = confidence >= 0.55 ? 1 : (confidence - 0.1) / 0.45;
            alpha = Math.round(t * t * (3 - 2 * t) * 255);
          }
          const offset = idx * 4;
          pixels[offset] = 255;
          pixels[offset + 1] = 255;
          pixels[offset + 2] = 255;
          pixels[offset + 3] = alpha;
        }
      }

      // Independent face detection protects cheeks and temples when the
      // coarse person model misses a side-lit face. Evaluate only inside each
      // face bounding ellipse instead of running hypot across the full frame.
      if (faceBoxes.length > 0 && video.videoWidth > 0 && video.videoHeight > 0) {
        const scaleX = video.videoWidth / maskWidth;
        const scaleY = video.videoHeight / maskHeight;
        for (const box of faceBoxes) {
          const cx = box.originX + box.width * 0.5;
          const cy = box.originY + box.height * 0.5;
          const rx = box.width * 0.51;
          const ry = box.height * 0.53;
          if (rx <= 0 || ry <= 0) continue;
          const xStart = Math.max(0, Math.floor((cx - rx * 1.04) / scaleX - 0.5));
          const xEnd = Math.min(maskWidth - 1, Math.ceil((cx + rx * 1.04) / scaleX - 0.5));
          const yStart = Math.max(0, Math.floor((cy - ry * 1.04) / scaleY - 0.5));
          const yEnd = Math.min(maskHeight - 1, Math.ceil((cy + ry * 1.04) / scaleY - 0.5));
          for (let y = yStart; y <= yEnd; y += 1) {
            const py = (y + 0.5) * scaleY;
            const dy = (py - cy) / ry;
            const dySq = dy * dy;
            if (dySq >= 1.0816) continue;
            const rowOffset = y * maskWidth;
            for (let x = xStart; x <= xEnd; x += 1) {
              const alphaIndex = (rowOffset + x) * 4 + 3;
              if (pixels[alphaIndex] === 255) continue;
              const px = (x + 0.5) * scaleX;
              const dx = (px - cx) / rx;
              const distSq = dx * dx + dySq;
              if (distSq >= 1.0816) continue;
              if (distSq <= 0.7396) {
                pixels[alphaIndex] = 255;
                continue;
              }
              const distance = Math.sqrt(distSq);
              const faceAlpha = (1.04 - distance) / 0.18;
              const feathered = Math.round(
                faceAlpha * faceAlpha * (3 - 2 * faceAlpha) * 255,
              );
              if (feathered > pixels[alphaIndex]) {
                pixels[alphaIndex] = feathered;
              }
            }
          }
        }
      }

      maskContext.putImageData(
        maskImageData,
        0,
        0,
      );
      latestMask = maskCanvas;
    }

    async function updateSegmentation(now) {
      if (currentEffect.type === 'none' || !enabled || outputSuspended || !videoIsReady()) return;
      const revision = effectRevision;
      await ensureSegmenter();
      if (stopped || !enabled || outputSuspended || revision !== effectRevision || currentEffect.type === 'none') return;
      // Inference runs once per accepted camera frame, with a monotonic task
      // timestamp even when browser callback timestamps have limited precision.
      const timestamp = Math.max(now, lastSegmentationAt + 1);
      lastSegmentationAt = timestamp;
      if (faceDetectCounter === 0) {
        const faces = faceDetector.detectForVideo(video, timestamp);
        faceBoxes = (faces?.detections || []).map((face) => face.boundingBox)
          .filter((box) => box && box.width > 0 && box.height > 0).slice(0, 4);
      }
      faceDetectCounter = (faceDetectCounter + 1) % 5;
      const result = segmenter.segmentForVideo(video, timestamp);
      try {
        const masks = result?.confidenceMasks;
        updateMask(masks?.[masks.length > 1 ? 1 : 0]);
      } finally {
        result?.close?.();
      }
    }

    function drawBlurredBackground(outputWidth, outputHeight) {
      const blurWidth = Math.max(1, Math.round(outputWidth * 0.25));
      const blurHeight = Math.max(1, Math.round(outputHeight * 0.25));
      if (blurCanvas.width !== blurWidth) blurCanvas.width = blurWidth;
      if (blurCanvas.height !== blurHeight) blurCanvas.height = blurHeight;

      if (supportsCanvasFilter) {
        const scaledRadius = Math.max(
          2,
          Math.round(blurRadius(currentEffect.blurStrength) * 0.25),
        );
        blurContext.filter = `blur(${scaledRadius}px)`;
        blurContext.drawImage(video, 0, 0, blurWidth, blurHeight);
        blurContext.filter = 'none';
        outputContext.imageSmoothingEnabled = true;
        outputContext.drawImage(blurCanvas, 0, 0, outputWidth, outputHeight);
        return;
      }

      // Fallback for browsers without CanvasRenderingContext2D.filter support:
      // two-stage bilinear downscale/upscale avoids leaking a sharp background.
      blurContext.imageSmoothingEnabled = true;
      blurContext.drawImage(video, 0, 0, blurWidth, blurHeight);
      if (!downsampleCanvas) {
        downsampleCanvas = document.createElement('canvas');
        downsampleContext = downsampleCanvas.getContext('2d', {
          alpha: false,
          desynchronized: true,
        });
      }
      if (downsampleContext) {
        const scale = fallbackBlurScale(currentEffect.blurStrength);
        const dsWidth = Math.max(1, Math.round(outputWidth * scale));
        const dsHeight = Math.max(1, Math.round(outputHeight * scale));
        if (downsampleCanvas.width !== dsWidth) downsampleCanvas.width = dsWidth;
        if (downsampleCanvas.height !== dsHeight) downsampleCanvas.height = dsHeight;
        downsampleContext.imageSmoothingEnabled = true;
        downsampleContext.drawImage(blurCanvas, 0, 0, dsWidth, dsHeight);
        blurContext.drawImage(downsampleCanvas, 0, 0, blurWidth, blurHeight);
      }
      outputContext.imageSmoothingEnabled = true;
      outputContext.drawImage(blurCanvas, 0, 0, outputWidth, outputHeight);
    }

    function drawFrame() {
      const outputWidth = outputCanvas.width;
      const outputHeight = outputCanvas.height;
      if (!enabled || stopped || outputSuspended || !outputWidth || !outputHeight || !videoIsReady()) return;

      outputContext.save();
      outputContext.clearRect(0, 0, outputWidth, outputHeight);
      if (currentEffect.type === 'none') {
        if (supportsCanvasFilter) outputContext.filter = 'none';
        outputContext.drawImage(video, 0, 0, outputWidth, outputHeight);
        outputContext.restore();
        outputTrack?.requestFrame?.();
        return;
      }

      // Privacy first: before segmentation produces a usable person mask,
      // publish a fully blurred frame rather than leaking the raw background.
      if (currentEffect.type === 'replaceImage') {
        if (supportsCanvasFilter) outputContext.filter = 'none';
        const scale = Math.max(outputWidth / backgroundImage.width, outputHeight / backgroundImage.height);
        const w = backgroundImage.width * scale;
        const h = backgroundImage.height * scale;
        outputContext.drawImage(backgroundImage, (outputWidth - w) / 2, (outputHeight - h) / 2, w, h);
      } else {
        if (supportsCanvasFilter) outputContext.filter = 'none';
        drawBlurredBackground(outputWidth, outputHeight);
      }

      if (latestMask) {
        foregroundContext.save();
        foregroundContext.clearRect(0, 0, outputWidth, outputHeight);
        foregroundContext.globalCompositeOperation = 'source-over';
        foregroundContext.drawImage(video, 0, 0, outputWidth, outputHeight);
        foregroundContext.globalCompositeOperation = 'destination-in';
        foregroundContext.drawImage(
          latestMask,
          0,
          0,
          outputWidth,
          outputHeight,
        );
        foregroundContext.restore();
        outputContext.drawImage(
          foregroundCanvas,
          0,
          0,
          outputWidth,
          outputHeight,
        );
      }
      outputContext.restore();
      outputTrack?.requestFrame?.();
    }

    function currentVideoFrame() {
      const quality = video.getVideoPlaybackQuality?.();
      if (quality?.totalVideoFrames > 0) return quality.totalVideoFrames;
      if (video.webkitDecodedFrameCount > 0) return video.webkitDecodedFrameCount;
      return video.currentTime;
    }

    function frameSignature(metadata) {
      if (metadata && typeof metadata === 'object') {
        // Safari/WebKit reports mediaTime = 0 on every live MediaStream frame
        // while incrementing presentedFrames. Include presentedFrames when
        // present so live camera streams never freeze after frame 1.
        if (Number.isFinite(metadata.presentedFrames) && metadata.presentedFrames > 0) {
          return `p:${metadata.presentedFrames}:${metadata.mediaTime ?? 0}`;
        }
        if (Number.isFinite(metadata.mediaTime)) {
          return metadata.mediaTime;
        }
      }
      return currentVideoFrame();
    }

    function validFrameToken(frame) {
      return typeof frame === 'string'
        ? frame.length > 0
        : Number.isFinite(frame);
    }

    function acceptFrame(now, frame) {
      if (!enabled || outputSuspended || !videoIsReady()) return false;
      // requestAnimationFrame follows display refresh, which may be much faster
      // than the camera. Do not redraw or infer the same decoded frame twice.
      if (validFrameToken(frame) && frame === lastVideoFrame) return false;
      if (nextFrameAt && now + 1 < nextFrameAt) return false;
      // Preserve the deadline instead of resetting it to each capture time:
      // otherwise a 30 fps camera limited to 24 fps falls to about 15 fps.
      nextFrameAt = !nextFrameAt || now - nextFrameAt > frameInterval
        ? now + frameInterval : nextFrameAt + frameInterval;
      if (validFrameToken(frame)) lastVideoFrame = frame;
      return true;
    }

    function scheduleFrame() {
      if (stopped) return;
      const render = async (now, frame = currentVideoFrame()) => {
        try {
          if (acceptFrame(now, frame)) {
            await updateSegmentation(now);
            drawFrame();
          }
        } catch (error) {
          failClosed(error);
        }
        scheduleFrame();
      };
      if (typeof video.requestVideoFrameCallback === 'function') {
        frameHandle = video.requestVideoFrameCallback(
          (now, metadata) => render(now, frameSignature(metadata)),
        );
      } else {
        frameHandle = global.requestAnimationFrame(render);
      }
    }

    async function setEffect(nextEffect) {
      const revision = ++effectRevision;
      const type = nextEffect?.type || 'none';
      if (!['none', 'blur', 'replaceImage'].includes(type)) {
        throw new Error(`Unsupported background effect: ${type}`);
      }
      outputSuspended = true;
      blankOutput();
      if (outputTrack) outputTrack.enabled = false;
      let nextImage = null;
      try {
        if (type === 'replaceImage') {
          const bytes = nextEffect.imageBytes;
          if (!bytes?.length || bytes.length > 16 * 1024 * 1024) throw new Error('Background image bytes must be between 1 byte and 16 MiB.');
          nextImage = await global.createImageBitmap(new Blob([new Uint8Array(bytes)]));
          if (!nextImage.width || !nextImage.height || nextImage.width > 4096 || nextImage.height > 4096) throw new Error('Background image dimensions must be between 1 and 4096 pixels.');
        }
        if (type !== 'none') await ensureSegmenter();
        if (stopped || revision !== effectRevision) { nextImage?.close?.(); return; }
        const previous = backgroundImage;
        backgroundImage = nextImage;
        latestMask = null;
        faceDetectCounter = 0;
        nextFrameAt = 0;
        lastVideoFrame = null;
        currentEffect = { type, blurStrength: nextEffect?.blurStrength || 'medium' };
        previous?.close?.();
        outputSuspended = false;
        lastFailure = null;
        if (sourceTrack) sourceTrack.enabled = enabled;
        if (outputTrack) outputTrack.enabled = enabled;
        // Do not report success until the selected effect can render. This
        // also propagates first-inference errors to the caller's Future.
        if (sourceTrack) await renderReadyFrame();
      } catch (error) {
        nextImage?.close?.();
        if (!stopped && revision === effectRevision) failClosed(error);
        throw error;
      }
    }

    try {
      // Initialize effects before opening the camera or scheduling any output.
      await setEffect(effect);
      await openCamera(deviceId);
      await renderReadyFrame();
      scheduleFrame();
    } catch (error) {
      stopped = true;
      sourceStream?.getTracks?.().forEach((track) => track.stop());
      outputTrack?.stop?.();
      segmenter?.close?.();
      faceDetector?.close?.();
      backgroundImage?.close?.();
      video.srcObject = null;
      throw error;
    }

    return {
      get track() {
        return outputTrack;
      },
      get info() {
        const settings = sourceTrack?.getSettings?.() || {};
        return { width: outputCanvas.width, height: outputCanvas.height, frameRate: Math.min(Number(settings.frameRate) || frameRate, frameRate), cameraDeviceId: settings.deviceId || null, rotationDegrees: 0, pixelFormat: 'rgba8888', mirrored: false };
      },
      get effect() {
        return { ...currentEffect };
      },
      setEffect,
      async setCameraDevice(nextDeviceId) {
        await openCamera(nextDeviceId);
      },
      async setEnabled(value) {
        if (value && lastFailure) throw lastFailure;
        enabled = Boolean(value);
        if (!enabled) blankOutput();
        if (sourceTrack) sourceTrack.enabled = enabled && !outputSuspended;
        if (outputTrack) outputTrack.enabled = enabled && !outputSuspended;
        try {
          if (enabled) await renderReadyFrame();
        } catch (error) {
          failClosed(error);
          throw error;
        }
      },
      stop() {
        if (stopped) return;
        stopped = true;
        cancelReadyWait?.();
        effectRevision++;
        backgroundImage?.close?.();
        if (
          typeof video.cancelVideoFrameCallback === 'function' &&
          frameHandle != null
        ) {
          video.cancelVideoFrameCallback(frameHandle);
        } else if (frameHandle != null) {
          global.cancelAnimationFrame?.(frameHandle);
        }
        outputTrack?.stop?.();
        sourceStream?.getTracks?.().forEach((track) => track.stop?.());
        segmenter?.close?.();
        faceDetector?.close?.();
        segmenter = null; faceDetector = null; faceBoxes = [];
        maskPixels = null; maskImageData = null;
        downsampleCanvas = null; downsampleContext = null;
        video.srcObject = null;
      },
    };
  }

  const sources = new Map();

  function parsePayload(value) {
    if (!value) return {};
    return typeof value === 'string' ? JSON.parse(value) : value;
  }

  function requireSource(sourceId) {
    const id = String(sourceId || '');
    const source = sources.get(id);
    if (!source) {
      throw new Error(`Unknown processed video source: ${id}`);
    }
    return source;
  }

  global.RealtimeVideoEffectsBridge = {
    bridgeVersion: 1,
    async createSource(sourceId, serializedArgs) {
      const id = String(sourceId || '');
      if (!id) throw new Error('Processed video sourceId is required.');
      if (sources.has(id)) {
        throw new Error(`Duplicate processed video source: ${id}`);
      }
      const args = parsePayload(serializedArgs);
      const source = await createProcessedVideo({
        effect: args.effect || {
          type: 'none',
          blurStrength: 'medium',
        },
        deviceId: args.cameraDeviceId || null,
        width: Number(args.width || 1280),
        height: Number(args.height || 720),
        frameRate: Number(args.frameRate || 24),
        onError: (error) => global.__flutterVideoEffectsOnError?.(id, String(error?.message || error)),
      });
      sources.set(id, source);
      global.RealtimeProcessedVideoBridge.register(id, {
        get track() { return source.track; },
        setEnabled: (enabled) => source.setEnabled(enabled),
        setCameraDevice: (deviceId) => source.setCameraDevice(deviceId),
        attachPreviewElement: (element, fit) => global.RealtimeVideoEffectsBridge.attachPreviewElement(id, element, fit),
      });
      return source.info;
    },

    async setEffect(sourceId, serializedEffect) {
      await requireSource(sourceId).setEffect(
        parsePayload(serializedEffect),
      );
    },

    async setEnabled(sourceId, enabled) {
      await requireSource(sourceId).setEnabled(Boolean(enabled));
    },

    async selectCamera(sourceId, deviceId) {
      await requireSource(sourceId).setCameraDevice(deviceId || null);
    },

    getSourceInfo(sourceId) { return requireSource(sourceId).info; },

    getTrack(sourceId) {
      return requireSource(sourceId).track;
    },

    attachPreview(sourceId, elementId) {
      const container = document.getElementById(String(elementId || ''));
      if (container) this.attachPreviewElement(sourceId, container);
    },

    attachPreviewElement(sourceId, container, fit = 'contain') {
      if (!container) throw new Error('A preview container is required.');
      let video = container.querySelector('video');
      if (!video) {
        video = document.createElement('video');
        video.autoplay = true;
        video.playsInline = true;
        video.muted = true;
        video.style.width = '100%';
        video.style.height = '100%';
        container.replaceChildren(video);
      }
      video.style.objectFit = fit === 'cover' ? 'cover' : 'contain';
      container.style.backgroundColor = '#000000';
      video.srcObject = new MediaStream([requireSource(sourceId).track]);
      video.play().catch(() => {});
    },

    detachPreview(_sourceId, elementId) {
      const container = document.getElementById(String(elementId || ''));
      if (!container) return;
      const video = container.querySelector('video');
      if (video) {
        video.pause?.();
        video.srcObject = null;
      }
      container.replaceChildren();
    },

    disposeSource(sourceId) {
      global.RealtimeProcessedVideoBridge.unregister(sourceId);
      const id = String(sourceId || '');
      const source = sources.get(id);
      if (!source) return;
      sources.delete(id);
      source.stop();
    },
  };
})(globalThis);
