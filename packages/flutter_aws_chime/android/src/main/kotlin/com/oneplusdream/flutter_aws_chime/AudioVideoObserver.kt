package com.oneplusdream.flutter_aws_chime

import android.util.Log
import com.amazonaws.services.chime.sdk.meetings.audiovideo.AudioVideoObserver
import com.amazonaws.services.chime.sdk.meetings.audiovideo.video.RemoteVideoSource
import com.amazonaws.services.chime.sdk.meetings.session.MeetingSessionStatus

class AudioVideoObserver(val methodChannel: MethodChannelCoordinator) : AudioVideoObserver {
    companion object {
        private const val TAG = "AwsChimeAV"
    }

    override fun onAudioSessionCancelledReconnect() {
        Log.w(TAG, "onAudioSessionCancelledReconnect")
        methodChannel.callFlutterEvent("audioSessionReconnectCancelled")
    }

    override fun onAudioSessionDropped() {
        Log.w(TAG, "onAudioSessionDropped")
        methodChannel.callFlutterEvent("audioSessionDropped")
    }

    override fun onAudioSessionStarted(reconnecting: Boolean) {
        Log.i(TAG, "onAudioSessionStarted reconnecting=$reconnecting")
        MeetingSessionManager.meetingSession?.audioVideo?.startRemoteVideo()
        methodChannel.callFlutterEvent(
                "audioSessionStarted",
                mapOf("reconnecting" to reconnecting)
        )
    }

    override fun onAudioSessionStartedConnecting(reconnecting: Boolean) {
        Log.i(TAG, "onAudioSessionStartedConnecting reconnecting=$reconnecting")
        methodChannel.callFlutterEvent(
                "audioSessionConnecting",
                mapOf("reconnecting" to reconnecting)
        )
    }

    override fun onAudioSessionStopped(sessionStatus: MeetingSessionStatus) {
        Log.i(TAG, "onAudioSessionStopped status=${sessionStatus.statusCode?.value}")
        MeetingSessionManager.onSessionStopped()
        methodChannel.callFlutterEvent(
                "audioSessionStopped",
                mapOf("statusCode" to sessionStatus.statusCode?.value?.toString())
        )
        methodChannel.callFlutterMethod(MethodCall.audioSessionDidStop, null)
    }

    override fun onCameraSendAvailabilityUpdated(available: Boolean) {
        Log.i(TAG, "onCameraSendAvailabilityUpdated available=$available")
        methodChannel.callFlutterEvent(
                "cameraAvailabilityChanged",
                mapOf("available" to available)
        )
    }

    override fun onConnectionBecamePoor() {
        Log.w(TAG, "onConnectionBecamePoor")
        methodChannel.callFlutterEvent("connectionBecamePoor")
    }

    override fun onConnectionRecovered() {
        Log.i(TAG, "onConnectionRecovered")
        methodChannel.callFlutterEvent("connectionRecovered")
    }

    override fun onRemoteVideoSourceAvailable(sources: List<RemoteVideoSource>) {
        Log.i(TAG, "onRemoteVideoSourceAvailable count=${sources.size} ids=${sources.map { it.attendeeId }}")
    }

    override fun onRemoteVideoSourceUnavailable(sources: List<RemoteVideoSource>) {
        Log.i(TAG, "onRemoteVideoSourceUnavailable count=${sources.size} ids=${sources.map { it.attendeeId }}")
    }

    override fun onVideoSessionStarted(sessionStatus: MeetingSessionStatus) {
        Log.i(TAG, "onVideoSessionStarted status=${sessionStatus.statusCode?.value}")
        methodChannel.callFlutterEvent(
                "videoSessionStarted",
                mapOf("statusCode" to sessionStatus.statusCode?.value?.toString())
        )
    }

    override fun onVideoSessionStartedConnecting() {
        Log.i(TAG, "onVideoSessionStartedConnecting")
        methodChannel.callFlutterEvent("videoSessionConnecting")
    }

    override fun onVideoSessionStopped(sessionStatus: MeetingSessionStatus) {
        Log.i(TAG, "onVideoSessionStopped status=${sessionStatus.statusCode?.value}")
        methodChannel.callFlutterEvent(
                "videoSessionStopped",
                mapOf("statusCode" to sessionStatus.statusCode?.value?.toString())
        )
    }
}
