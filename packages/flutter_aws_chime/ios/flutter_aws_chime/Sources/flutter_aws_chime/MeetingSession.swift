//
//  MeetingSession.swift
//  flutter_aws_chime
//
//  Created by Conan on 2023/9/9.
//

import AmazonChimeSDK
import AmazonChimeSDKMedia
import AVFoundation
import Flutter
import Foundation

// Singleton Pattern Class
class MeetingSession {
    static let shared = MeetingSession()

    var meetingSession: DefaultMeetingSession?
    var cameraPosition = "front"

    let audioVideoConfig = AudioVideoConfiguration()
    private let logger = ConsoleLogger(name: "MeetingSession")

    private init() {}

    func startMeetingAudio() -> MethodChannelResponse {
        let audioSessionConfigured = configureAudioSession()
        let audioSessionStarted = startAudioVideoConnection()
        if audioSessionStarted, audioSessionConfigured {
            return MethodChannelResponse(result: true, arguments: Response.create_meeting_success.rawValue)
        }
        return MethodChannelResponse(result: false, arguments: Response.meeting_start_failed.rawValue)
    }

    private func startAudioVideoConnection() -> Bool {
        do {
            try meetingSession?.audioVideo.start()
            meetingSession?.audioVideo.startRemoteVideo()
        } catch PermissionError.audioPermissionError {
            NSLog("[flutter_aws_chime] Audio permissions error.")
            logger.error(msg: "Audio permissions error.")
            return false
        } catch {
            NSLog("[flutter_aws_chime] Error starting the Meeting: %@", error.localizedDescription)
            logger.error(msg: "Error starting the Meeting: \(error.localizedDescription)")
            return false
        }
        return true
    }

    private func configureAudioSession() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            try audioSession.setMode(.voiceChat)
        } catch {
            NSLog("[flutter_aws_chime] Error configuring AVAudioSession: %@", error.localizedDescription)
            logger.error(msg: "Error configuring AVAudioSession: \(error.localizedDescription)")
            return false
        }
        return true
    }
}
