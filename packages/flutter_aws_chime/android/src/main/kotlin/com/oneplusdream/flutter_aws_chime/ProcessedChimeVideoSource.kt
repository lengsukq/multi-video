package com.oneplusdream.flutter_aws_chime

import com.amazonaws.services.chime.sdk.meetings.audiovideo.video.VideoContentHint
import com.amazonaws.services.chime.sdk.meetings.audiovideo.video.VideoFrame
import com.amazonaws.services.chime.sdk.meetings.audiovideo.video.VideoRotation
import com.amazonaws.services.chime.sdk.meetings.audiovideo.video.VideoSink
import com.amazonaws.services.chime.sdk.meetings.audiovideo.video.VideoSource
import com.amazonaws.services.chime.sdk.meetings.audiovideo.video.buffer.VideoFrameI420Buffer
import com.oneplusdream.flutter_realtime_processed_video.ProcessedVideoFrame
import com.oneplusdream.flutter_realtime_processed_video.ProcessedVideoFrameHub
import com.oneplusdream.flutter_realtime_processed_video.ProcessedVideoFrameSink
import java.util.concurrent.CopyOnWriteArraySet
import org.amazon.chime.webrtc.JavaI420Buffer
import org.amazon.chime.webrtc.YuvHelper

/** Native conversion of the common processed frame; Chime never owns a second camera. */
internal class ProcessedChimeVideoSource(
    private val sourceId: String,
    override val contentHint: VideoContentHint = VideoContentHint.Motion,
    private val convertFrame: (ProcessedVideoFrame) -> VideoFrameI420Buffer = ::convertChimeFrame,
) : VideoSource, ProcessedVideoFrameSink {
    private val sinks = CopyOnWriteArraySet<VideoSink>()
    private var disposed = false

    init { ProcessedVideoFrameHub.register(sourceId, this) }
    @Synchronized override fun addVideoSink(sink: VideoSink) { if (!disposed) sinks.add(sink) }
    @Synchronized override fun removeVideoSink(sink: VideoSink) { sinks.remove(sink) }

    @Synchronized override fun onVideoFrame(input: ProcessedVideoFrame) {
        if (disposed || sinks.isEmpty()) return
        val buffer = convertFrame(input)
        val rotation = when (input.rotationDegrees) {
            90 -> VideoRotation.Rotation90
            180 -> VideoRotation.Rotation180
            270 -> VideoRotation.Rotation270
            else -> VideoRotation.Rotation0
        }
        val frame = VideoFrame(input.timestampNs, buffer, rotation)
        try { sinks.forEach { it.onVideoFrameReceived(frame) } }
        finally { frame.release() }
    }

    @Synchronized fun dispose() {
        if (disposed) return
        disposed = true
        ProcessedVideoFrameHub.unregister(sourceId, this)
        sinks.clear()
    }

}

/** Uses the WebRTC/libyuv implementation already bundled by Chime, not another RTC SDK. */
private fun convertChimeFrame(input: ProcessedVideoFrame): VideoFrameI420Buffer {
    val rgba = input.rgba.duplicate()
    val required = input.rowStride.toLong() * (input.height - 1) + input.width.toLong() * 4
    require(input.pixelFormat == "rgba8888" && rgba.isDirect &&
        input.width > 0 && input.height > 0 && input.rowStride.toLong() >= input.width.toLong() * 4 &&
        required <= rgba.limit()) { "Expected a direct RGBA frame with valid row strides." }
    rgba.position(0)
    val native = JavaI420Buffer.allocate(input.width, input.height)
    try {
        // RGBA byte order is libyuv's ABGR convention on little-endian Android.
        YuvHelper.ABGRToI420(rgba, input.rowStride,
            native.dataY, native.strideY, native.dataU, native.strideU,
            native.dataV, native.strideV, input.width, input.height)
        // The Chime frame owns the allocation until its last consumer releases it.
        return VideoFrameI420Buffer(input.width, input.height,
            native.dataY, native.dataU, native.dataV,
            native.strideY, native.strideU, native.strideV, Runnable { native.release() })
    } catch (error: Throwable) {
        native.release()
        throw error
    }
}
