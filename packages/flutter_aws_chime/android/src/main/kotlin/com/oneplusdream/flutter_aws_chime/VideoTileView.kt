package com.oneplusdream.flutter_aws_chime

import android.content.Context
import android.view.View
import io.flutter.plugin.platform.PlatformView
import com.amazonaws.services.chime.sdk.meetings.audiovideo.video.DefaultVideoRenderView
import com.amazonaws.services.chime.sdk.meetings.audiovideo.video.VideoScalingType
import com.amazonaws.services.chime.sdk.meetings.utils.logger.ConsoleLogger

internal class VideoTileView(context: Context?, creationParams: Any?) : PlatformView {
    private val view: DefaultVideoRenderView
    private val tileId: Int?
    private val fitMode: String

    private val videoTileViewLogger: ConsoleLogger = ConsoleLogger()

    override fun getView(): View {
        return view
    }

    override fun dispose() {
        tileId?.let { MeetingSessionManager.meetingSession?.audioVideo?.unbindVideoView(it) }
    }

    init {
        when (creationParams) {
            is Number -> {
                tileId = creationParams.toInt()
                fitMode = "contain"
            }
            is Map<*, *> -> {
                tileId = (creationParams["tileId"] as? Number)?.toInt()
                fitMode = creationParams["fit"]?.toString() ?: "contain"
            }
            else -> {
                tileId = null
                fitMode = "contain"
            }
        }
        view = DefaultVideoRenderView(context as Context)
        view.scalingType = if (fitMode == "cover") {
            VideoScalingType.AspectBalanced
        } else {
            VideoScalingType.AspectFit
        }
        tileId?.let { MeetingSessionManager.meetingSession?.audioVideo?.bindVideoView(view, it) }
                ?: videoTileViewLogger.error("VideoTileView", "Error while binding video view.")
    }
}
