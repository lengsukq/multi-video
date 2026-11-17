package com.oneplusdream.flutter_realtime_processed_video

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.DisplayMetrics
import android.view.WindowManager
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.nio.ByteBuffer
import java.util.UUID
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Shared Android MediaProjection screen capture source.
 *
 * Captures frames into [ProcessedVideoFrameHub] as tightly packed `rgba8888`
 * buffers so any provider (Chime, IVS, etc.) can subscribe without duplicating
 * MediaProjection consent, foreground service, or VirtualDisplay code.
 */
internal class AndroidSystemScreenCapture(
    private val context: Context,
    private val channel: MethodChannel,
    private val onStateChanged: (() -> Unit)? = null,
) : PluginRegistry.ActivityResultListener {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()
    private var activity: Activity? = null
    private var pendingResult: MethodChannel.Result? = null
    private var activeSourceId: String? = null
    private var stopped = false
    private var firstFrameSent = false
    private var wasActive = false
    private var lastFrameNs = 0L

    private var mediaProjection: MediaProjection? = null
    private var projectionCallback: MediaProjection.Callback? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var captureThread: HandlerThread? = null
    private var captureHandler: Handler? = null
    private var rgbaScratch: ByteBuffer? = null

    fun setActivity(activity: Activity?) {
        synchronized(lock) {
            this.activity = activity
        }
    }

    val isAvailable: Boolean
        get() = synchronized(lock) { activity != null }

    val isCapturing: Boolean
        get() = synchronized(lock) { pendingResult != null || activeSourceId != null }

    fun start(result: MethodChannel.Result) {
        val currentActivity = synchronized(lock) {
            if (pendingResult != null || activeSourceId != null) {
                result.error(
                    "screen_capture_busy",
                    "An Android screen capture is already active.",
                    null,
                )
                return
            }
            val bound = activity
            if (bound == null) {
                result.error(
                    "screen_capture_unavailable",
                    "An active Android Activity is required for screen capture.",
                    null,
                )
                return
            }
            pendingResult = result
            stopped = false
            firstFrameSent = false
            wasActive = false
            lastFrameNs = 0L
            bound
        }

        val manager =
            currentActivity.getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                as? MediaProjectionManager
        if (manager == null) {
            failStart(
                "screen_capture_unavailable",
                "MediaProjection service is unavailable on this device.",
            )
            return
        }

        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
        } else {
            manager.createScreenCaptureIntent()
        }
        try {
            currentActivity.startActivityForResult(intent, REQUEST_CODE_MEDIA_PROJECTION)
        } catch (error: Throwable) {
            failStart(
                "screen_capture_failed",
                error.message ?: "Could not open Android screen capture prompt.",
            )
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE_MEDIA_PROJECTION) return false
        if (resultCode != Activity.RESULT_OK || data == null) {
            failStart("screen_capture_cancelled", "Screen sharing permission was cancelled.")
            return true
        }
        synchronized(lock) {
            if (stopped || pendingResult == null) return true
        }
        ScreenCaptureService.start(context) {
            beginProjection(resultCode, data)
        }
        return true
    }

    private fun beginProjection(resultCode: Int, data: Intent) {
        synchronized(lock) {
            if (stopped || pendingResult == null) {
                ScreenCaptureService.stop(context)
                return
            }
        }
        val manager =
            context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
        val projection = manager?.getMediaProjection(resultCode, data)
        if (projection == null) {
            failStart("screen_capture_failed", "Failed to acquire MediaProjection.")
            return
        }

        val (width, height, densityDpi) = computeCaptureGeometry()
        val sourceId = UUID.randomUUID().toString()
        val thread = HandlerThread(VIRTUAL_DISPLAY_NAME).apply { start() }
        val handler = Handler(thread.looper)

        val callback = object : MediaProjection.Callback() {
            override fun onStop() {
                mainHandler.post { handleSystemStopped(sourceId) }
            }
        }
        projection.registerCallback(callback, handler)

        val reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        val scratch = ByteBuffer.allocateDirect(width * height * 4)

        synchronized(lock) {
            if (stopped) {
                projection.unregisterCallback(callback)
                projection.stop()
                reader.close()
                thread.quitSafely()
                ScreenCaptureService.stop(context)
                return
            }
            activeSourceId = sourceId
            mediaProjection = projection
            projectionCallback = callback
            imageReader = reader
            captureThread = thread
            captureHandler = handler
            rgbaScratch = scratch
        }

        reader.setOnImageAvailableListener({ r ->
            onImageAvailable(r, sourceId, width, height, scratch)
        }, handler)

        virtualDisplay = projection.createVirtualDisplay(
            VIRTUAL_DISPLAY_NAME,
            width,
            height,
            densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader.surface,
            null,
            handler,
        )
    }

    private fun onImageAvailable(
        reader: ImageReader,
        sourceId: String,
        width: Int,
        height: Int,
        scratch: ByteBuffer,
    ) {
        var image: Image? = null
        try {
            image = reader.acquireLatestImage() ?: return
            val nowNs = System.nanoTime()
            val isFirst: Boolean
            synchronized(lock) {
                if (stopped || activeSourceId != sourceId) return
                if (lastFrameNs != 0L && nowNs - lastFrameNs < MIN_FRAME_INTERVAL_NS) return
                lastFrameNs = nowNs
                isFirst = !firstFrameSent
                if (isFirst) firstFrameSent = true
            }

            val plane = image.planes[0]
            val src = plane.buffer
            val rowStride = plane.rowStride
            val rowBytes = width * 4
            scratch.clear()
            if (rowStride == rowBytes && src.remaining() >= width * height * 4) {
                val slice = src.duplicate()
                slice.position(0)
                slice.limit(width * height * 4)
                scratch.put(slice)
            } else {
                val rowScratch = ByteArray(rowBytes)
                val copyLen = min(rowBytes, rowStride)
                for (y in 0 until height) {
                    src.position(y * rowStride)
                    src.get(rowScratch, 0, copyLen)
                    scratch.put(rowScratch, 0, copyLen)
                }
            }
            scratch.flip()

            ProcessedVideoFrameHub.publish(
                ProcessedVideoFrame(
                    sourceId = sourceId,
                    rgba = scratch,
                    width = width,
                    height = height,
                    timestampNs = nowNs,
                    rotationDegrees = 0,
                    pixelFormat = "rgba8888",
                    rowStride = rowBytes,
                ),
            )

            if (isFirst) {
                mainHandler.post {
                    val result: MethodChannel.Result?
                    synchronized(lock) {
                        result = pendingResult
                        pendingResult = null
                        if (result != null && !stopped && activeSourceId == sourceId) {
                            wasActive = true
                        }
                    }
                    result?.success(
                        mapOf(
                            "id" to sourceId,
                            "platform" to "android",
                            "kind" to "nativeFrameHub",
                            "width" to width,
                            "height" to height,
                            "frameRate" to MAX_FRAME_RATE,
                        ),
                    )
                }
            }
        } catch (error: Throwable) {
            ProcessedVideoFrameHub.reportSourceFailure(sourceId, error)
        } finally {
            image?.close()
        }
    }

    private fun handleSystemStopped(sourceId: String) {
        val emitEnded: Boolean
        val hadPending: Boolean
        synchronized(lock) {
            if (activeSourceId != sourceId || stopped) return
            emitEnded = wasActive
            hadPending = pendingResult != null
        }
        if (hadPending) {
            failStart("screen_capture_failed", "Android screen capture stopped before its first frame.")
            return
        }
        stop()
        if (emitEnded) {
            channel.invokeMethod(
                "androidScreenCaptureEnded",
                mapOf(
                    "sourceId" to sourceId,
                    "message" to "Screen sharing was stopped by the system.",
                ),
            )
        }
    }

    private fun failStart(code: String, message: String) {
        val result: MethodChannel.Result?
        synchronized(lock) {
            result = pendingResult
            pendingResult = null
        }
        stop()
        mainHandler.post {
            result?.error(code, message, null)
        }
    }

    fun stop() {
        val stalePending: MethodChannel.Result?
        val sourceId: String?
        val display: VirtualDisplay?
        val reader: ImageReader?
        val projection: MediaProjection?
        val callback: MediaProjection.Callback?
        val thread: HandlerThread?

        synchronized(lock) {
            stopped = true
            stalePending = pendingResult
            pendingResult = null
            sourceId = activeSourceId
            activeSourceId = null
            wasActive = false
            display = virtualDisplay
            virtualDisplay = null
            reader = imageReader
            imageReader = null
            projection = mediaProjection
            mediaProjection = null
            callback = projectionCallback
            projectionCallback = null
            thread = captureThread
            captureThread = null
            captureHandler = null
            rgbaScratch = null
        }

        if (stalePending != null) {
            mainHandler.post {
                stalePending.error("screen_capture_cancelled", "Screen capture was stopped.", null)
            }
        }
        try {
            display?.release()
        } catch (_: Throwable) {}
        try {
            reader?.setOnImageAvailableListener(null, null)
            reader?.close()
        } catch (_: Throwable) {}
        try {
            if (projection != null && callback != null) {
                projection.unregisterCallback(callback)
            }
            projection?.stop()
        } catch (_: Throwable) {}
        try {
            thread?.quitSafely()
        } catch (_: Throwable) {}
        if (sourceId != null) {
            ProcessedVideoFrameHub.clear(sourceId)
        }
        ScreenCaptureService.stop(context)
        if (stalePending != null || sourceId != null) {
            mainHandler.post { onStateChanged?.invoke() }
        }
    }

    private fun computeCaptureGeometry(): Triple<Int, Int, Int> {
        val metrics = DisplayMetrics()
        val wm = (activity ?: context).getSystemService(Context.WINDOW_SERVICE) as? WindowManager
        @Suppress("DEPRECATION")
        wm?.defaultDisplay?.getRealMetrics(metrics)
        val rawW = if (metrics.widthPixels > 0) metrics.widthPixels else 720
        val rawH = if (metrics.heightPixels > 0) metrics.heightPixels else 1280
        val density = if (metrics.densityDpi > 0) metrics.densityDpi else DisplayMetrics.DENSITY_DEFAULT
        val maxEdge = max(rawW, rawH).toDouble()
        val ratio = if (maxEdge > MAX_DIMENSION) MAX_DIMENSION / maxEdge else 1.0
        val w = evenDimension(rawW * ratio)
        val h = evenDimension(rawH * ratio)
        return Triple(w, h, density)
    }

    private fun evenDimension(value: Double): Int {
        val rounded = value.roundToInt()
        return max(2, rounded - (rounded % 2))
    }

    companion object {
        internal const val VIRTUAL_DISPLAY_NAME = "RealtimeScreenCapture"
        private const val REQUEST_CODE_MEDIA_PROJECTION = 41028
        private const val MAX_DIMENSION = 1280.0
        private const val MAX_FRAME_RATE = 15.0
        private const val MIN_FRAME_INTERVAL_NS = 1_000_000_000L / 15L
    }
}
