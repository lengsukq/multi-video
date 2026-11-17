package com.oneplusdream.flutter_aws_chime

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import io.flutter.plugin.platform.PlatformView
import com.amazonaws.services.chime.sdk.meetings.audiovideo.video.DefaultVideoRenderView
import com.amazonaws.services.chime.sdk.meetings.audiovideo.video.VideoScalingType
import com.amazonaws.services.chime.sdk.meetings.utils.logger.ConsoleLogger
import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

internal class VideoTileView(context: Context?, creationParams: Any?) : PlatformView {
    companion object {
        private const val TAG = "AwsChimeTileView"
        private val nextInstanceId = AtomicInteger(0)
        private val activeBindings = ConcurrentHashMap<Int, BoundTileView>()
        private val mainHandler = Handler(Looper.getMainLooper())

        private data class BoundTileView(
                val instanceId: Int,
                val viewRef: WeakReference<DefaultVideoRenderView>
        )

        internal fun rebindIfActive(tileId: Int) {
            val binding = activeBindings[tileId] ?: return
            val renderView = binding.viewRef.get() ?: return
            val action = Runnable {
                val current = activeBindings[tileId]
                if (current == null || current.instanceId != binding.instanceId) {
                    return@Runnable
                }
                val session = MeetingSessionManager.meetingSession ?: return@Runnable
                Log.i(TAG, "rebindIfActive tileId=$tileId instanceId=${binding.instanceId}")
                session.audioVideo.bindVideoView(renderView, tileId)
            }
            if (Looper.myLooper() == Looper.getMainLooper()) {
                action.run()
            } else {
                mainHandler.post(action)
            }
        }

        internal fun clearTile(tileId: Int) {
            activeBindings.remove(tileId)
        }

        internal fun clearAll() {
            activeBindings.clear()
        }
    }

    private val instanceId = nextInstanceId.incrementAndGet()
    private val view: DefaultVideoRenderView
    private val tileId: Int?
    private val fitMode: String
    private val isLocalOverlay: Boolean

    private val videoTileViewLogger: ConsoleLogger = ConsoleLogger()

    override fun getView(): View {
        return view
    }

    override fun dispose() {
        val id = tileId ?: return
        val existing = activeBindings[id]
        // Only unbind if this PlatformView still owns the active binding for tileId;
        // Flutter layout transitions construct the replacement PlatformView before
        // disposing the old one, and Chime's unbindVideoView(id) is keyed only by id.
        if (existing != null && existing.instanceId == instanceId && activeBindings.remove(id, existing)) {
            Log.i(TAG, "dispose tileId=$id instanceId=$instanceId (unbinding)")
            MeetingSessionManager.meetingSession?.audioVideo?.unbindVideoView(id)
        } else {
            Log.i(TAG, "dispose tileId=$id instanceId=$instanceId skipped unbind; active=${existing?.instanceId}")
        }
    }

    init {
        when (creationParams) {
            is Number -> {
                tileId = creationParams.toInt()
                fitMode = "contain"
                isLocalOverlay = false
            }
            is Map<*, *> -> {
                tileId = (creationParams["tileId"] as? Number)?.toInt()
                fitMode = creationParams["fit"]?.toString() ?: "contain"
                isLocalOverlay = creationParams["isLocal"] == true
            }
            else -> {
                tileId = null
                fitMode = "contain"
                isLocalOverlay = false
            }
        }
        view = DefaultVideoRenderView(context as Context)
        if (isLocalOverlay) {
            view.setZOrderMediaOverlay(true)
        }
        view.scalingType = if (fitMode == "cover") {
            VideoScalingType.AspectBalanced
        } else {
            VideoScalingType.AspectFit
        }
        val session = MeetingSessionManager.meetingSession
        Log.i(TAG, "init tileId=$tileId instanceId=$instanceId fit=$fitMode isLocal=$isLocalOverlay hasSession=${session != null}")
        tileId?.let {
            activeBindings[it] = BoundTileView(instanceId, WeakReference(view))
            session?.audioVideo?.bindVideoView(view, it)
        } ?: videoTileViewLogger.error("VideoTileView", "Error while binding video view.")
    }
}
