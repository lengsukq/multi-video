package com.oneplusdream.flutter_aws_chime

import com.amazonaws.services.chime.sdk.meetings.device.MediaDevice
import com.amazonaws.services.chime.sdk.meetings.audiovideo.contentshare.ContentShareSource
import com.amazonaws.services.chime.sdk.meetings.audiovideo.video.VideoContentHint
import com.amazonaws.services.chime.sdk.meetings.session.DefaultMeetingSession
import com.amazonaws.services.chime.sdk.meetings.session.MediaPlacement
import com.amazonaws.services.chime.sdk.meetings.session.MeetingSessionConfiguration
import com.amazonaws.services.chime.sdk.meetings.session.CreateMeetingResponse
import com.amazonaws.services.chime.sdk.meetings.session.Meeting
import com.amazonaws.services.chime.sdk.meetings.session.CreateAttendeeResponse
import com.amazonaws.services.chime.sdk.meetings.session.Attendee
import com.amazonaws.services.chime.sdk.meetings.utils.logger.ConsoleLogger
import com.amazonaws.services.chime.sdk.meetings.utils.logger.LogLevel
import com.oneplusdream.flutter_aws_chime.MethodCall as MethodCallFlutter
import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MethodChannelCoordinator(binaryMessenger: BinaryMessenger, activity: Activity) {
    val methodChannel: MethodChannel
    val context: Context
    val permissionsManager: PermissionManager =
            PermissionManager(activity.applicationContext, activity)

    init {
        methodChannel =
                MethodChannel(binaryMessenger, "com.oneplusdream.aws.chime.methodChannel")
        context = activity.applicationContext
    }

    private val NULL_MEETING_SESSION_RESPONSE: MethodChannelResult =
            MethodChannelResult(
                    false,
                    Response.meeting_session_is_null.msg,
                    "session_not_found"
            )

    fun setupMethodChannel() {
        methodChannel.setMethodCallHandler { call, result ->
            val callResult: MethodChannelResult
            when (call.method) {
                "attachProcessedVideoSource" -> {
                    try {
                        val sourceId = call.argument<String>("sourceId").orEmpty()
                        require(sourceId.isNotEmpty()) { "sourceId is required." }
                        check(MeetingSessionManager.meetingSession != null) { "No active Chime meeting session." }
                        val wasEnabled = MeetingSessionManager.localVideoEnabled
                        MeetingSessionManager.meetingSession?.audioVideo?.stopLocalVideo()
                        MeetingSessionManager.detachProcessedVideoSource()
                        val source = ProcessedChimeVideoSource(sourceId)
                        MeetingSessionManager.processedVideoSource = source
                        if (wasEnabled) {
                            MeetingSessionManager.meetingSession?.audioVideo?.startLocalVideo(source)
                            MeetingSessionManager.localVideoEnabled = true
                        }
                        result.success(null)
                    } catch (error: Throwable) { result.error("attach_provider_failed", error.message, null) }
                    return@setMethodCallHandler
                }
                "detachProcessedVideoSource" -> {
                    MeetingSessionManager.detachProcessedVideoSource()
                    result.success(null)
                    return@setMethodCallHandler
                }
                "attachAndroidScreenCaptureSource" -> {
                    try {
                        val sourceId = call.argument<String>("sourceId").orEmpty()
                        require(sourceId.isNotEmpty()) { "sourceId is required." }
                        val audioVideo = MeetingSessionManager.meetingSession?.audioVideo
                            ?: throw IllegalStateException("No active Chime meeting session.")
                        MeetingSessionManager.detachAndroidScreenCaptureSource()
                        val source = ProcessedChimeVideoSource(
                            sourceId = sourceId,
                            contentHint = VideoContentHint.Text,
                        )
                        MeetingSessionManager.androidScreenSource = source
                        val contentShare = ContentShareSource().apply {
                            videoSource = source
                        }
                        audioVideo.startContentShare(contentShare)
                        result.success(mapOf("success" to true))
                    } catch (error: Throwable) {
                        MeetingSessionManager.detachAndroidScreenCaptureSource()
                        result.error("attach_screen_share_failed", error.message, null)
                    }
                    return@setMethodCallHandler
                }
                "detachAndroidScreenCaptureSource" -> {
                    MeetingSessionManager.detachAndroidScreenCaptureSource()
                    result.success(true)
                    return@setMethodCallHandler
                }
                MethodCallFlutter.manageAudioPermissions.call -> {
                    permissionsManager.manageAudioPermissions(result)
                    return@setMethodCallHandler
                }

                MethodCallFlutter.manageVideoPermissions.call -> {
                    permissionsManager.manageVideoPermissions(result)
                    return@setMethodCallHandler
                }

                MethodCallFlutter.join.call -> {
                    callResult = join(call)
                }

                MethodCallFlutter.stop.call -> {
                    callResult = stop()
                }

                MethodCallFlutter.mute.call -> {
                    callResult = mute()
                }

                MethodCallFlutter.unmute.call -> {
                    callResult = unmute()
                }

                MethodCallFlutter.startLocalVideo.call -> {
                    callResult = startLocalVideo()
                }

                MethodCallFlutter.stopLocalVideo.call -> {
                    callResult = stopLocalVideo()
                }

                MethodCallFlutter.initialAudioSelection.call -> {
                    callResult = initialAudioSelection()
                }

                MethodCallFlutter.listAudioDevices.call -> {
                    callResult = listAudioDevices()
                }

                MethodCallFlutter.updateAudioDevice.call -> {
                    callResult = updateAudioDevice(call)
                }

                MethodCallFlutter.setCameraPosition.call -> {
                    callResult = setCameraPosition(call)
                }

                MethodCallFlutter.sendMessage.call -> {
                    callResult = sendMessage(call)
                }

                else -> callResult = MethodChannelResult(
                        false,
                        Response.method_not_implemented.msg,
                        "method_not_implemented"
                )
            }

            result.success(callResult.toFlutterCompatibleType())
        }
    }

    fun updateActivity(activity: Activity) {
        permissionsManager.updateActivity(activity)
    }

    fun detachActivity() {
        permissionsManager.updateActivity(null)
    }

    fun dispose() {
        MeetingSessionManager.detachAndroidScreenCaptureSource()
        MeetingSessionManager.detachProcessedVideoSource()
        permissionsManager.cancelPendingRequests()
        methodChannel.setMethodCallHandler(null)
    }

    companion object {
        private const val TAG = "AwsChimeMethod"
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    fun callFlutterMethod(method: MethodCallFlutter, args: Any?) {
        val invoke = { methodChannel.invokeMethod(method.call, args) }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            invoke()
        } else {
            mainHandler.post { invoke() }
        }
    }

    fun callFlutterEvent(type: String, values: Map<String, Any?> = emptyMap()) {
        val payload = mapOf("type" to type) + values
        if (Looper.myLooper() == Looper.getMainLooper()) {
            methodChannel.invokeMethod(MethodCallFlutter.meetingEvent.call, payload)
        } else {
            mainHandler.post {
                methodChannel.invokeMethod(MethodCallFlutter.meetingEvent.call, payload)
            }
        }
    }

    fun join(call: MethodCall): MethodChannelResult {
        if (MeetingSessionManager.meetingSession != null) {
            return MethodChannelResult(
                    false,
                    "A Chime meeting session is already active.",
                    "meeting_already_active"
            )
        }
        if (call.arguments == null) {
            return MethodChannelResult(
                    false,
                    Response.incorrect_join_response_params.msg,
                    "invalid_join_info"
            )
        }
        val meetingId: String? = call.argument("MeetingId")
        val externalMeetingId: String? = call.argument("ExternalMeetingId")
        val mediaRegion: String? = call.argument("MediaRegion")
        val audioHostUrl: String? = call.argument("AudioHostUrl")
        val audioFallbackUrl: String? = call.argument("AudioFallbackUrl")
        val signalingUrl: String? = call.argument("SignalingUrl")
        val turnControlUrl: String? = call.argument("TurnControlUrl")
        val externalUserId: String? = call.argument("ExternalUserId")
        val attendeeId: String? = call.argument("AttendeeId")
        val joinToken: String? = call.argument("JoinToken")

        if (meetingId == null ||
                mediaRegion == null ||
                audioHostUrl == null ||
                externalMeetingId == null ||
                audioFallbackUrl == null ||
                signalingUrl == null ||
                turnControlUrl == null ||
                externalUserId == null ||
                attendeeId == null ||
                joinToken == null
        ) {
            return MethodChannelResult(
                    false,
                    Response.incorrect_join_response_params.msg,
                    "invalid_join_info"
            )
        }

        val createMeetingResponse = CreateMeetingResponse(
                Meeting(
                        externalMeetingId,
                        MediaPlacement(audioFallbackUrl, audioHostUrl, signalingUrl, turnControlUrl),
                        mediaRegion,
                        meetingId
                )
        )
        val createAttendeeResponse =
                CreateAttendeeResponse(Attendee(attendeeId, externalUserId, joinToken))
        val meetingSessionConfiguration =
                MeetingSessionConfiguration(createMeetingResponse, createAttendeeResponse)

        Log.i(TAG, "join meetingId=$meetingId attendeeId=$attendeeId region=$mediaRegion")
        val meetingSession =
                DefaultMeetingSession(meetingSessionConfiguration, ConsoleLogger(LogLevel.DEBUG), context)

        MeetingSessionManager.meetingSession = meetingSession
        return MeetingSessionManager.startMeeting(
                RealtimeObserver(this),
                VideoTileObserver(this),
                AudioVideoObserver(this),
                DataMessageObserver(this)
        )
    }

    fun stop(): MethodChannelResult {
        Log.i(TAG, "stop")
        return MeetingSessionManager.stop()
    }

    fun mute(): MethodChannelResult {
        val muted = MeetingSessionManager.meetingSession?.audioVideo?.realtimeLocalMute()
                ?: return NULL_MEETING_SESSION_RESPONSE
        return if (muted) MethodChannelResult(
                true,
                Response.mute_successful.msg
        ) else MethodChannelResult(false, Response.mute_failed.msg)
    }

    fun unmute(): MethodChannelResult {
        val unmuted = MeetingSessionManager.meetingSession?.audioVideo?.realtimeLocalUnmute()
                ?: return NULL_MEETING_SESSION_RESPONSE
        return if (unmuted) MethodChannelResult(
                true,
                Response.unmute_successful.msg
        ) else MethodChannelResult(false, Response.unmute_failed.msg)
    }

    fun startLocalVideo(): MethodChannelResult {
        val audioVideo = MeetingSessionManager.meetingSession?.audioVideo
                ?: return NULL_MEETING_SESSION_RESPONSE
        val processed = MeetingSessionManager.processedVideoSource
        Log.i(TAG, "startLocalVideo processed=${processed != null}")
        if (processed != null) audioVideo.startLocalVideo(processed) else audioVideo.startLocalVideo()
        MeetingSessionManager.localVideoEnabled = true
        return MethodChannelResult(true, Response.local_video_on_success.msg)
    }

    fun stopLocalVideo(): MethodChannelResult {
        MeetingSessionManager.meetingSession?.audioVideo?.stopLocalVideo()
                ?: return NULL_MEETING_SESSION_RESPONSE
        Log.i(TAG, "stopLocalVideo")
        MeetingSessionManager.localVideoEnabled = false
        return MethodChannelResult(true, Response.local_video_off_success.msg)
    }

    fun initialAudioSelection(): MethodChannelResult {
        val device =
                MeetingSessionManager.meetingSession?.audioVideo?.getActiveAudioDevice()
                        ?: return NULL_MEETING_SESSION_RESPONSE
        return MethodChannelResult(true, device.label)
    }

    fun listAudioDevices(): MethodChannelResult {
        val audioDevices = MeetingSessionManager.meetingSession?.audioVideo?.listAudioDevices()
                ?: return NULL_MEETING_SESSION_RESPONSE
        val transform: (MediaDevice) -> String = { it.label }
        return MethodChannelResult(true, audioDevices.map(transform))
    }

    fun updateAudioDevice(call: MethodCall): MethodChannelResult {
        val device =
                call.arguments ?: return MethodChannelResult(
                        false,
                        Response.null_audio_device.msg,
                        "invalid_argument"
                )

        val audioDevices = MeetingSessionManager.meetingSession?.audioVideo?.listAudioDevices()
                ?: return NULL_MEETING_SESSION_RESPONSE

        for (dev in audioDevices) {
            if (device == dev.label) {
                MeetingSessionManager.meetingSession?.audioVideo?.chooseAudioDevice(dev)
                        ?: return MethodChannelResult(
                                false,
                                Response.audio_device_update_failed.msg,
                                "invalid_argument"
                        )
                return MethodChannelResult(true, Response.audio_device_updated.msg)
            }
        }
        return MethodChannelResult(
                false,
                Response.audio_device_update_failed.msg,
                "invalid_argument"
        )
    }

    fun setCameraPosition(call: MethodCall): MethodChannelResult {
        val position = call.argument<String>("position")?.lowercase()
                ?: return MethodChannelResult(false, "Camera position is required.", "invalid_argument")
        if (position != "front" && position != "back") {
            return MethodChannelResult(false, "Unsupported camera position: $position", "invalid_argument")
        }
        val session = MeetingSessionManager.meetingSession
                ?: return NULL_MEETING_SESSION_RESPONSE
        if (position != MeetingSessionManager.cameraPosition) {
            session.audioVideo.switchCamera()
            MeetingSessionManager.cameraPosition = position
        }
        return MethodChannelResult(true, position)
    }

    fun sendMessage(call: MethodCall): MethodChannelResult {
        val topic: String? = call.argument("topic")
        val message: String? = call.argument("message")
        val lifetimeMs: Int? = call.argument("lifetimeMs")
        if (topic == null || message == null) {
            return MethodChannelResult(false, Response.message_payload_error.msg, "invalid_argument")
        }
        if (MeetingSessionManager.meetingSession == null) return NULL_MEETING_SESSION_RESPONSE
        return try {
            MeetingSessionManager.meetingSession?.audioVideo?.realtimeSendDataMessage(topic, message, lifetimeMs
                    ?: 300000)
            MethodChannelResult(true, Response.send_message_success.msg)
        } catch (e: Exception) {
            MethodChannelResult(false, Response.send_message_failed.msg)
        }
    }
}
