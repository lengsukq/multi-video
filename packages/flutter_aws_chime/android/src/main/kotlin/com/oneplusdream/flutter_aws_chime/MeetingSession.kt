package com.oneplusdream.flutter_aws_chime

import com.amazonaws.services.chime.sdk.meetings.session.DefaultMeetingSession
import com.amazonaws.services.chime.sdk.meetings.audiovideo.AudioVideoObserver
import com.amazonaws.services.chime.sdk.meetings.audiovideo.AudioVideoFacade
import com.amazonaws.services.chime.sdk.meetings.realtime.datamessage.DataMessageObserver
import com.amazonaws.services.chime.sdk.meetings.utils.logger.ConsoleLogger

object MeetingSessionManager {
    private val meetingSessionlogger: ConsoleLogger = ConsoleLogger()

    var realtimeObserver: RealtimeObserver? = null
    var videoTileObserver: VideoTileObserver? = null
    var audioVideoObserver: AudioVideoObserver? = null
    var dataMessageObserver: DataMessageObserver? = null

    var meetingSession: DefaultMeetingSession? = null
    var cameraPosition: String = "front"
    internal var processedVideoSource: ProcessedChimeVideoSource? = null
    internal var localVideoEnabled = false

    @Synchronized
    internal fun detachProcessedVideoSource() {
        val source = processedVideoSource ?: return
        processedVideoSource = null
        localVideoEnabled = false
        meetingSession?.audioVideo?.stopLocalVideo()
        source.dispose()
    }


    private val NULL_MEETING_SESSION_RESPONSE: MethodChannelResult =
            MethodChannelResult(
                    false,
                    Response.meeting_session_is_null.msg,
                    "session_not_found"
            )

    fun startMeeting(
            realtimeObserver: RealtimeObserver? = null,
            videoTileObserver: VideoTileObserver? = null,
            audioVideoObserver: AudioVideoObserver? = null,
            dataMessageObserver: DataMessageObserver? = null
    ): MethodChannelResult {
        val audioVideo: AudioVideoFacade =
                meetingSession?.audioVideo ?: return NULL_MEETING_SESSION_RESPONSE
        cameraPosition = "front"
        localVideoEnabled = false
        addObservers(realtimeObserver, videoTileObserver, audioVideoObserver, dataMessageObserver)
        audioVideo.start()
        audioVideo.startRemoteVideo()
        return MethodChannelResult(true, Response.create_meeting_success.msg)
    }

    fun stop(): MethodChannelResult {
        val session = meetingSession ?: return NULL_MEETING_SESSION_RESPONSE
        detachProcessedVideoSource()
        VideoTileView.clearAll()
        removeObservers()
        session.audioVideo.stopRemoteVideo()
        session.audioVideo.stop()
        meetingSession = null
        cameraPosition = "front"
        return MethodChannelResult(true, Response.meeting_stopped_successfully.msg)
    }

    @Synchronized
    fun onSessionStopped() {
        detachProcessedVideoSource()
        VideoTileView.clearAll()
        removeObservers()
        meetingSession = null
        cameraPosition = "front"
    }

    private fun addObservers(
            realtimeObserver: RealtimeObserver?,
            videoTileObserver: VideoTileObserver?,
            audioVideoObserver: AudioVideoObserver?,
            dataMessageObserver: DataMessageObserver?,
    ) {
        val audioVideo: AudioVideoFacade = meetingSession?.audioVideo ?: return
        realtimeObserver?.let {
            audioVideo.addRealtimeObserver(it)
            this.realtimeObserver = realtimeObserver
            meetingSessionlogger.debug("RealtimeObserver", "RealtimeObserver initialized")
        }
        audioVideoObserver?.let {
            audioVideo.addAudioVideoObserver(it)
            this.audioVideoObserver = audioVideoObserver
            meetingSessionlogger.debug("AudioVideoObserver", "AudioVideoObserver initialized")
        }
        videoTileObserver?.let {
            audioVideo.addVideoTileObserver(videoTileObserver)
            this.videoTileObserver = videoTileObserver
            meetingSessionlogger.debug("VideoTileObserver", "VideoTileObserver initialized")
        }

        dataMessageObserver?.let {
            audioVideo.addRealtimeDataMessageObserver("chat", dataMessageObserver)
            this.dataMessageObserver = dataMessageObserver
            meetingSessionlogger.debug("DataMessageObserver", "DataMessageObserver initialized")
        }
    }

    private fun removeObservers() {
        val audioVideo = meetingSession?.audioVideo ?: return
        realtimeObserver?.let { audioVideo.removeRealtimeObserver(it) }
        audioVideoObserver?.let { audioVideo.removeAudioVideoObserver(it) }
        videoTileObserver?.let { audioVideo.removeVideoTileObserver(it) }
        dataMessageObserver?.let {
            audioVideo.removeRealtimeDataMessageObserverFromTopic("chat")
        }
        realtimeObserver = null
        audioVideoObserver = null
        videoTileObserver = null
        dataMessageObserver = null
    }
}
