//
//  AudioVideoObserver.swift
//  flutter_aws_chime
//
//  Created by Conan on 2023/9/9.
//


import AmazonChimeSDK
import AmazonChimeSDKMedia
import Foundation
import os

class MyAudioVideoObserver: AudioVideoObserver {
    private static let logger = Logger(subsystem: "com.oneplusdream.aws.chime",
                                       category: "AudioVideoObserver")

    var methodChannel: MethodChannelCoordinator

    init(withMethodChannel methodChannel: MethodChannelCoordinator) {
        self.methodChannel = methodChannel
    }

    func audioSessionDidStartConnecting(reconnecting: Bool) {
        NSLog("[flutter_aws_chime] audioSessionDidStartConnecting reconnecting=%d", reconnecting ? 1 : 0)
        Self.logger.info("audioSessionDidStartConnecting reconnecting=\(reconnecting)")
        methodChannel.callFlutterEvent("audioSessionConnecting", args: ["reconnecting": reconnecting])
    }

    func audioSessionDidStart(reconnecting: Bool) {
        NSLog("[flutter_aws_chime] audioSessionDidStart reconnecting=%d", reconnecting ? 1 : 0)
        Self.logger.info("audioSessionDidStart reconnecting=\(reconnecting)")
        // Dart initializes the local attendee as muted. The native Chime
        // session must match on its first connection, otherwise iOS may
        // transmit before the user explicitly enables the microphone.
        if !reconnecting {
            _ = MeetingSession.shared.meetingSession?.audioVideo.realtimeLocalMute()
        }
        // Re-ensure remote video subscription once the native session starts or reconnects.
        MeetingSession.shared.meetingSession?.audioVideo.startRemoteVideo()
        methodChannel.callFlutterEvent("audioSessionStarted", args: ["reconnecting": reconnecting])
    }

    func audioSessionDidDrop() {
        NSLog("[flutter_aws_chime] audioSessionDidDrop")
        Self.logger.warning("audioSessionDidDrop")
        MeetingSession.shared.meetingSession?.logger.info(msg: "Meeting session dropped")
        methodChannel.callFlutterEvent("audioSessionDropped")
    }

    func audioSessionDidStopWithStatus(sessionStatus: MeetingSessionStatus) {
        NSLog("[flutter_aws_chime] audioSessionDidStopWithStatus status=%ld", sessionStatus.statusCode.rawValue)
        Self.logger.info("audioSessionDidStopWithStatus status=\(sessionStatus.statusCode.rawValue)")
        let stoppedSession = MeetingSession.shared.meetingSession
        methodChannel.stopAudioVideoFacadeObservers()
        stoppedSession?.logger.info(msg: "Meeting session stopped with status \(sessionStatus.description)")
        MeetingSession.shared.meetingSession = nil
        MeetingSession.shared.cameraPosition = "front"
        methodChannel.callFlutterEvent("audioSessionStopped", args: ["statusCode": String(sessionStatus.statusCode.rawValue)])
        methodChannel.callFlutterMethod(method: .audioSessionDidStop, args: nil)
    }

    func audioSessionDidCancelReconnect() {
        NSLog("[flutter_aws_chime] audioSessionDidCancelReconnect")
        Self.logger.warning("audioSessionDidCancelReconnect")
        methodChannel.callFlutterEvent("audioSessionReconnectCancelled")
    }

    func connectionDidRecover() {
        Self.logger.info("connectionDidRecover")
        methodChannel.callFlutterEvent("connectionRecovered")
    }

    func connectionDidBecomePoor() {
        Self.logger.warning("connectionDidBecomePoor")
        methodChannel.callFlutterEvent("connectionBecamePoor")
    }

    func videoSessionDidStartConnecting() {
        NSLog("[flutter_aws_chime] videoSessionDidStartConnecting")
        Self.logger.info("videoSessionDidStartConnecting")
        MeetingSession.shared.meetingSession?.logger.info(msg: "VideoSession started connecting...")
        methodChannel.callFlutterEvent("videoSessionConnecting")
    }

    func videoSessionDidStartWithStatus(sessionStatus: MeetingSessionStatus) {
        NSLog("[flutter_aws_chime] videoSessionDidStartWithStatus status=%ld", sessionStatus.statusCode.rawValue)
        Self.logger.info("videoSessionDidStartWithStatus status=\(sessionStatus.statusCode.rawValue)")
        MeetingSession.shared.meetingSession?.logger.info(msg:
            "VideoSession started with status \(sessionStatus.statusCode.description)")
        methodChannel.callFlutterEvent("videoSessionStarted", args: ["statusCode": String(sessionStatus.statusCode.rawValue)])
    }

    func videoSessionDidStopWithStatus(sessionStatus: MeetingSessionStatus) {
        NSLog("[flutter_aws_chime] videoSessionDidStopWithStatus status=%ld", sessionStatus.statusCode.rawValue)
        Self.logger.info("videoSessionDidStopWithStatus status=\(sessionStatus.statusCode.rawValue)")
        MeetingSession.shared.meetingSession?.logger.info(msg: "VideoSession stopped with status \(sessionStatus.statusCode.description)")
        methodChannel.callFlutterEvent("videoSessionStopped", args: ["statusCode": String(sessionStatus.statusCode.rawValue)])
    }

    func remoteVideoSourcesDidBecomeAvailable(sources: [RemoteVideoSource]) {
        for remoteSourceAvailable in sources {
            NSLog("[flutter_aws_chime] remoteVideoSourcesDidBecomeAvailable attendeeId=%@", remoteSourceAvailable.attendeeId)
            Self.logger.info("remoteVideoSourcesDidBecomeAvailable attendeeId=\(remoteSourceAvailable.attendeeId, privacy: .public)")
            MeetingSession.shared.meetingSession?.logger.info(msg: "Remote video source became available: \(remoteSourceAvailable.attendeeId)")
        }
    }

    func remoteVideoSourcesDidBecomeUnavailable(sources: [RemoteVideoSource]) {
        for remoteSourcesUnavailable in sources {
            NSLog("[flutter_aws_chime] remoteVideoSourcesDidBecomeUnavailable attendeeId=%@", remoteSourcesUnavailable.attendeeId)
            Self.logger.info("remoteVideoSourcesDidBecomeUnavailable attendeeId=\(remoteSourcesUnavailable.attendeeId, privacy: .public)")
            MeetingSession.shared.meetingSession?.logger.info(msg: "Remote video source became unavailable: \(remoteSourcesUnavailable.attendeeId)")
        }
    }

    func cameraSendAvailabilityDidChange(available: Bool) {
        NSLog("[flutter_aws_chime] cameraSendAvailabilityDidChange available=%d", available ? 1 : 0)
        methodChannel.callFlutterEvent("cameraAvailabilityChanged", args: ["available": available])
    }
}
