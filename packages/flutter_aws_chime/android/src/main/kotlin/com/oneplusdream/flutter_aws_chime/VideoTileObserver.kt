package com.oneplusdream.flutter_aws_chime

import android.util.Log
import com.amazonaws.services.chime.sdk.meetings.audiovideo.video.VideoTileObserver
import com.amazonaws.services.chime.sdk.meetings.audiovideo.video.VideoTileState
import com.amazonaws.services.chime.sdk.meetings.utils.logger.ConsoleLogger

class VideoTileObserver(val methodChannel: MethodChannelCoordinator) : VideoTileObserver {
    companion object {
        private const val TAG = "AwsChimeTile"
    }

    private val videoTileObserverLogger: ConsoleLogger = ConsoleLogger()

    override fun onVideoTileAdded(tileState: VideoTileState) {
        Log.i(TAG, "onVideoTileAdded tileId=${tileState.tileId} attendeeId=${tileState.attendeeId} local=${tileState.isLocalTile} content=${tileState.isContent} size=${tileState.videoStreamContentWidth}x${tileState.videoStreamContentHeight}")
        VideoTileView.rebindIfActive(tileState.tileId)
        methodChannel.callFlutterMethod(MethodCall.videoTileAdd, videoTileStateToMap(tileState))
    }

    override fun onVideoTilePaused(tileState: VideoTileState) {
        Log.i(TAG, "onVideoTilePaused tileId=${tileState.tileId}")
        callVideoTileEvent("videoTilePaused", tileState)
    }

    override fun onVideoTileRemoved(tileState: VideoTileState) {
        Log.i(TAG, "onVideoTileRemoved tileId=${tileState.tileId} attendeeId=${tileState.attendeeId} local=${tileState.isLocalTile}")
        VideoTileView.clearTile(tileState.tileId)
        MeetingSessionManager.meetingSession?.audioVideo?.unbindVideoView(tileState.tileId)
                ?: videoTileObserverLogger.error(
                        "onVideoTileRemoved",
                        "Error while unbinding video view."
                )
        methodChannel.callFlutterMethod(MethodCall.videoTileRemove, videoTileStateToMap(tileState))
    }

    override fun onVideoTileResumed(tileState: VideoTileState) {
        Log.i(TAG, "onVideoTileResumed tileId=${tileState.tileId}")
        callVideoTileEvent("videoTileResumed", tileState)
    }

    override fun onVideoTileSizeChanged(tileState: VideoTileState) {
        Log.i(TAG, "onVideoTileSizeChanged tileId=${tileState.tileId} size=${tileState.videoStreamContentWidth}x${tileState.videoStreamContentHeight}")
        callVideoTileEvent("videoTileSizeChanged", tileState)
    }

    private fun callVideoTileEvent(type: String, state: VideoTileState) {
        methodChannel.callFlutterEvent(
                type,
                mapOf("videoTile" to videoTileStateToMap(state))
        )
    }

    private fun videoTileStateToMap(state: VideoTileState): Map<String, Any?> {
        return mapOf(
                "tileId" to state.tileId,
                "attendeeId" to state.attendeeId,
                "videoStreamContentWidth" to state.videoStreamContentWidth,
                "videoStreamContentHeight" to state.videoStreamContentHeight,
                "isLocalTile" to state.isLocalTile,
                "isContent" to state.isContent
        )
    }
}
