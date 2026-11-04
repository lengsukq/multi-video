//
//  AudioVideoObserver.swift
//  flutter_aws_chime
//
//  Created by Conan on 2023/9/9.
//


import AmazonChimeSDK
import AmazonChimeSDKMedia
import Foundation

class MyAudioVideoObserver: AudioVideoObserver {

    var methodChannel: MethodChannelCoordinator

    init(withMethodChannel methodChannel: MethodChannelCoordinator) {
        self.methodChannel = methodChannel
    }

    func audioSessionDidStartConnecting(reconnecting: Bool) {
        methodChannel.callFlutterEvent("audioSessionConnecting", args: ["reconnecting": reconnecting])
    }

    func audioSessionDidStart(reconnecting: Bool) {
        // Dart initializes the local attendee as muted. The native Chime
        // session must match on its first connection, otherwise iOS may
        // transmit before the user explicitly enables the microphone.
        if !reconnecting {
            _ = MeetingSession.shared.meetingSession?.audioVideo.realtimeLocalMute()
        }
        methodChannel.callFlutterEvent("audioSessionStarted", args: ["reconnecting": reconnecting])
    }

    func audioSessionDidDrop() {
        MeetingSession.shared.meetingSession?.logger.info(msg: "Meeting session dropped")
        methodChannel.callFlutterEvent("audioSessionDropped")
    }

    func audioSessionDidStopWithStatus(sessionStatus: MeetingSessionStatus) {
        let stoppedSession = MeetingSession.shared.meetingSession
        methodChannel.stopAudioVideoFacadeObservers()
        stoppedSession?.logger.info(msg: "Meeting session stopped with status \(sessionStatus.description)")
        MeetingSession.shared.meetingSession = nil
        MeetingSession.shared.cameraPosition = "front"
        methodChannel.callFlutterEvent("audioSessionStopped", args: ["statusCode": String(sessionStatus.statusCode.rawValue)])
        methodChannel.callFlutterMethod(method: .audioSessionDidStop, args: nil)
    }

    func audioSessionDidCancelReconnect() {
        methodChannel.callFlutterEvent("audioSessionReconnectCancelled")
    }

    func connectionDidRecover() {
        methodChannel.callFlutterEvent("connectionRecovered")
    }

    func connectionDidBecomePoor() {
        methodChannel.callFlutterEvent("connectionBecamePoor")
    }

    func videoSessionDidStartConnecting() {
        MeetingSession.shared.meetingSession?.logger.info(msg: "VideoSession started connecting...")
        methodChannel.callFlutterEvent("videoSessionConnecting")
    }

    func videoSessionDidStartWithStatus(sessionStatus: MeetingSessionStatus) {
        MeetingSession.shared.meetingSession?.logger.info(msg:
            "VideoSession started with status \(sessionStatus.statusCode.description)")
        methodChannel.callFlutterEvent("videoSessionStarted", args: ["statusCode": String(sessionStatus.statusCode.rawValue)])
    }

    func videoSessionDidStopWithStatus(sessionStatus: MeetingSessionStatus) {
        MeetingSession.shared.meetingSession?.logger.info(msg: "VideoSession stopped with status \(sessionStatus.statusCode.description)")
        methodChannel.callFlutterEvent("videoSessionStopped", args: ["statusCode": String(sessionStatus.statusCode.rawValue)])
    }

    func remoteVideoSourcesDidBecomeAvailable(sources: [RemoteVideoSource]) {
        for remoteSourceAvailable in sources {
            MeetingSession.shared.meetingSession?.logger.info(msg: "Remote video source became available: \(remoteSourceAvailable.attendeeId)")
        }
    }

    func remoteVideoSourcesDidBecomeUnavailable(sources: [RemoteVideoSource]) {
        for remoteSourcesUnavailable in sources {
            MeetingSession.shared.meetingSession?.logger.info(msg: "Remote video source became available: \(remoteSourcesUnavailable.attendeeId)")
        }
    }

    func cameraSendAvailabilityDidChange(available: Bool) {
        methodChannel.callFlutterEvent("cameraAvailabilityChanged", args: ["available": available])
    }
}
