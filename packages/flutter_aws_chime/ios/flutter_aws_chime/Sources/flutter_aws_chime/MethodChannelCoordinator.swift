//
//  MethodChannelCoordinator.swift
//  flutter_aws_chime
//
//  Created by Conan on 2023/9/9.
//

import AmazonChimeSDK
import AmazonChimeSDKMedia
import AVFoundation
import Flutter
import Foundation
import UIKit
import MediaPlayer

class MethodChannelCoordinator {
    let methodChannel: FlutterMethodChannel

    var realtimeObserver: RealtimeObserver?

    var audioVideoObserver: AudioVideoObserver?

    var videoTileObserver: VideoTileObserver?

    var dataMessageObserver: DataMessageObserver?

    private var iosScreenSource: ChimeIosSystemScreenSource?
    private var iosContentSource: ContentShareSource?

    // Registering every vendor is required by the aggregated Flutter plugin,
    // but registration must not eagerly touch the process-wide audio session.
    // Capture volume only when the user actually toggles Chime output.
    private var currentVolumeValue: Float?


    init(binaryMessenger: FlutterBinaryMessenger) {
        self.methodChannel = FlutterMethodChannel(name: "com.oneplusdream.aws.chime.methodChannel", binaryMessenger: binaryMessenger)
    }

    //
    // ————————————————————————————————— Method Call Setup —————————————————————————————————
    //

    func setUpMethodCallHandler() {
        self.methodChannel.setMethodCallHandler { [unowned self]
            (call: FlutterMethodCall, result: @escaping FlutterResult) in
            let callMethod = MethodCall(rawValue: call.method)
            var response: MethodChannelResponse = .init(result: false, arguments: nil)
            switch callMethod {
            case .manageAudioPermissions:
                self.manageAudioPermissions { permissionResponse in
                    DispatchQueue.main.async {
                        result(permissionResponse.toFlutterCompatibleType())
                    }
                }
                return
            case .manageVideoPermissions:
                self.manageVideoPermissions { permissionResponse in
                    DispatchQueue.main.async {
                        result(permissionResponse.toFlutterCompatibleType())
                    }
                }
                return
            case .join:
                response = self.join(call: call)
            case .stop:
                response = self.stop()
            case .mute:
                response = self.mute()
            case .unmute:
                response = self.unmute()
            case .toggleSound:
                response = self.toggleVolume(off: call.arguments as? Bool ?? false)
            case .startLocalVideo:
                response = self.startLocalVideo()
            case .stopLocalVideo:
                response = self.stopLocalVideo()
            case .attachIosScreenCaptureKitSource:
                response = self.attachIosScreenCaptureKitSource(call: call)
            case .detachIosScreenCaptureKitSource:
                self.detachIosScreenCaptureKitSource()
                response = MethodChannelResponse(result: true, arguments: nil)
            case .initialAudioSelection:
                response = self.initialAudioSelection()
            case .listAudioDevices:
                response = self.listAudioDevices()
            case .updateAudioDevice:
                response = self.updateAudioDevice(call: call)
            case .setCameraPosition:
                response = self.setCameraPosition(call: call)
            case .sendMessage:
                response = self.sendMessage(call: call)
            default:
                response = MethodChannelResponse(result: false, arguments: Response.method_not_implemented.rawValue, code: "method_not_implemented")
            }
            result(response.toFlutterCompatibleType())
        }
    }

    func callFlutterMethod(method: MethodCall, args: Any?) {
        self.methodChannel.invokeMethod(method.rawValue, arguments: args)
    }

    func callFlutterEvent(_ type: String, args: [String: Any] = [:]) {
        var event = args
        event["type"] = type
        callFlutterMethod(method: .meetingEvent, args: event)
    }

    //
    // ————————————————————————————————— Method Call Options —————————————————————————————————
    //

    func manageAudioPermissions(completion: @escaping (MethodChannelResponse) -> Void) {
        let audioPermission = AVAudioSession.sharedInstance().recordPermission
        switch audioPermission {
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                completion(granted
                    ? MethodChannelResponse(result: true, arguments: Response.audio_authorized.rawValue)
                    : MethodChannelResponse(result: false, arguments: Response.audio_auth_not_granted.rawValue, code: "permission_denied"))
            }
        case .granted:
            completion(MethodChannelResponse(result: true, arguments: Response.audio_authorized.rawValue))
        case .denied:
            completion(MethodChannelResponse(result: false, arguments: Response.audio_auth_not_granted.rawValue, code: "permission_denied"))
        @unknown default:
            completion(MethodChannelResponse(result: false, arguments: Response.unknown_audio_authorization_status.rawValue, code: "permission_denied"))
        }
    }

    func manageVideoPermissions(completion: @escaping (MethodChannelResponse) -> Void) {
        let videoPermission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch videoPermission {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                completion(granted
                    ? MethodChannelResponse(result: true, arguments: Response.video_authorized.rawValue)
                    : MethodChannelResponse(result: false, arguments: Response.video_auth_not_granted.rawValue, code: "permission_denied"))
            }
        case .authorized:
            completion(MethodChannelResponse(result: true, arguments: Response.video_authorized.rawValue))
        case .denied:
            completion(MethodChannelResponse(result: false, arguments: Response.video_auth_not_granted.rawValue, code: "permission_denied"))
        case .restricted:
            completion(MethodChannelResponse(result: false, arguments: Response.video_restricted.rawValue, code: "permission_denied"))
        @unknown default:
            completion(MethodChannelResponse(result: false, arguments: Response.unknown_video_authorization_status.rawValue, code: "permission_denied"))
        }
    }

    func join(call: FlutterMethodCall) -> MethodChannelResponse {
        guard let json = call.arguments as? [String: String] else {
            return MethodChannelResponse(result: false, arguments: Response.create_meeting_failed.rawValue, code: "invalid_join_info")
        }

        // TODO: zmauricv: add a Json Decoder
        guard let meetingId = json["MeetingId"], let externalMeetingId = json["ExternalMeetingId"], let mediaRegion = json["MediaRegion"], let audioHostUrl = json["AudioHostUrl"], let audioFallbackUrl = json["AudioFallbackUrl"], let signalingUrl = json["SignalingUrl"], let turnControlUrl = json["TurnControlUrl"], let externalUserId = json["ExternalUserId"], let attendeeId = json["AttendeeId"], let joinToken = json["JoinToken"]
        else {
            return MethodChannelResponse(result: false, arguments: Response.incorrect_join_response_params.rawValue, code: "invalid_join_info")
        }

        guard MeetingSession.shared.meetingSession == nil else {
            return MethodChannelResponse(result: false, arguments: "A Chime meeting session is already active.", code: "meeting_already_active")
        }

        let meetingResponse = CreateMeetingResponse(meeting: Meeting(externalMeetingId: externalMeetingId, mediaPlacement: MediaPlacement(audioFallbackUrl: audioFallbackUrl, audioHostUrl: audioHostUrl, signalingUrl: signalingUrl, turnControlUrl: turnControlUrl), mediaRegion: mediaRegion, meetingId: meetingId))

        let attendeeResponse = CreateAttendeeResponse(attendee: Attendee(attendeeId: attendeeId, externalUserId: externalUserId, joinToken: joinToken))

        let meetingSessionConfiguration = MeetingSessionConfiguration(createMeetingResponse: meetingResponse, createAttendeeResponse: attendeeResponse)

        let logger = ConsoleLogger(name: "MeetingSession Logger", level: LogLevel.DEBUG)

        let meetingSession = DefaultMeetingSession(configuration: meetingSessionConfiguration, logger: logger)

        self.configureAudioSession()

        // Update Singleton Class
        MeetingSession.shared.meetingSession = meetingSession
        MeetingSession.shared.cameraPosition = "front"

        self.setupAudioVideoFacadeObservers()
        let meetingStartResponse = MeetingSession.shared.startMeetingAudio()
        if !meetingStartResponse.result {
            stopAudioVideoFacadeObservers()
            MeetingSession.shared.meetingSession = nil
            MeetingSession.shared.cameraPosition = "front"
        }
        return meetingStartResponse
    }

    func stop() -> MethodChannelResponse {
        guard let session = MeetingSession.shared.meetingSession else {
            return MethodChannelResponse(result: false, arguments: "No Chime meeting session is active.", code: "session_not_found")
        }
        detachIosScreenCaptureKitSource()
        stopAudioVideoFacadeObservers()
        session.audioVideo.stop()
        MeetingSession.shared.meetingSession = nil
        MeetingSession.shared.cameraPosition = "front"
        return MethodChannelResponse(result: true, arguments: Response.meeting_stopped_successfully.rawValue)
    }

    private func attachIosScreenCaptureKitSource(call: FlutterMethodCall) -> MethodChannelResponse {
        guard let session = MeetingSession.shared.meetingSession,
              let args = call.arguments as? [String: Any],
              let sourceId = args["sourceId"] as? String, !sourceId.isEmpty else {
            return MethodChannelResponse(result: false, arguments: "A joined Chime session and screen source are required.", code: "invalid_state")
        }
        detachIosScreenCaptureKitSource()
        let source = ChimeIosSystemScreenSource(sourceId: sourceId)
        do {
            try source.start()
            let content = ContentShareSource()
            content.videoSource = source
            session.audioVideo.startContentShare(source: content)
            iosScreenSource = source
            iosContentSource = content
            return MethodChannelResponse(result: true, arguments: nil)
        } catch {
            source.stop()
            return MethodChannelResponse(result: false, arguments: error.localizedDescription, code: "native_error")
        }
    }

    private func detachIosScreenCaptureKitSource() {
        if iosScreenSource != nil {
            MeetingSession.shared.meetingSession?.audioVideo.stopContentShare()
            iosScreenSource?.stop()
        }
        iosScreenSource = nil
        iosContentSource = nil
    }

    func toggleVolume(off:Bool) -> MethodChannelResponse {
        let slider = (MPVolumeView().subviews.filter{ NSStringFromClass($0.classForCoder) == "MPVolumeSlider" }.first as? UISlider);
        if(off){
            currentVolumeValue = AVAudioSession.sharedInstance().outputVolume;
            slider?.setValue(0, animated: false)
        }else {
            slider?.setValue(currentVolumeValue ?? AVAudioSession.sharedInstance().outputVolume, animated: false)
        }
        return MethodChannelResponse(result: true, arguments:"success")
    }

    func mute() -> MethodChannelResponse {
        guard let session = MeetingSession.shared.meetingSession else {
            return MethodChannelResponse(result: false, arguments: "No Chime meeting session is active.", code: "session_not_found")
        }
        let muted = session.audioVideo.realtimeLocalMute()
        if muted {
            return MethodChannelResponse(result: true, arguments: Response.mute_successful.rawValue)
        } else {
            return MethodChannelResponse(result: false, arguments: Response.mute_failed.rawValue)
        }
    }

    func unmute() -> MethodChannelResponse {
        guard let session = MeetingSession.shared.meetingSession else {
            return MethodChannelResponse(result: false, arguments: "No Chime meeting session is active.", code: "session_not_found")
        }
        let unmuted = session.audioVideo.realtimeLocalUnmute()

        if unmuted {
            return MethodChannelResponse(result: true, arguments: Response.unmute_successful.rawValue)
        } else {
            return MethodChannelResponse(result: false, arguments: Response.unmute_failed.rawValue)
        }
    }

    func startLocalVideo() -> MethodChannelResponse {
        guard let session = MeetingSession.shared.meetingSession else {
            return MethodChannelResponse(result: false, arguments: "No Chime meeting session is active.", code: "session_not_found")
        }
        do {
            try session.audioVideo.startLocalVideo()
            return MethodChannelResponse(result: true, arguments: Response.local_video_on_success.rawValue)
        } catch {
            session.logger.error(msg: "Error configuring AVAudioSession: \(error.localizedDescription)")
            return MethodChannelResponse(result: false, arguments: Response.local_video_on_failed.rawValue)
        }
    }

    func stopLocalVideo() -> MethodChannelResponse {
        guard let session = MeetingSession.shared.meetingSession else {
            return MethodChannelResponse(result: false, arguments: "No Chime meeting session is active.", code: "session_not_found")
        }
        session.audioVideo.stopLocalVideo()
        return MethodChannelResponse(result: true, arguments: Response.local_video_off_success.rawValue)
    }

    func initialAudioSelection() -> MethodChannelResponse {
        guard let session = MeetingSession.shared.meetingSession else {
            return MethodChannelResponse(result: false, arguments: "No Chime meeting session is active.", code: "session_not_found")
        }
        if let initialAudioDevice = session.audioVideo.getActiveAudioDevice() {
            return MethodChannelResponse(result: true, arguments: initialAudioDevice.label)
        }
        return MethodChannelResponse(result: false, arguments: Response.failed_to_get_initial_audio_device.rawValue)
    }

    func listAudioDevices() -> MethodChannelResponse {
        guard let session = MeetingSession.shared.meetingSession else {
            return MethodChannelResponse(result: false, arguments: "No Chime meeting session is active.", code: "session_not_found")
        }
        let audioDevices = session.audioVideo.listAudioDevices()
        return MethodChannelResponse(result: true, arguments: audioDevices.map { $0.label })
    }

    func updateAudioDevice(call: FlutterMethodCall) -> MethodChannelResponse {
        guard let device = call.arguments as? String else {
            return MethodChannelResponse(result: false, arguments: Response.audio_device_update_failed.rawValue, code: "invalid_argument")
        }
        guard let session = MeetingSession.shared.meetingSession else {
            return MethodChannelResponse(result: false, arguments: "No Chime meeting session is active.", code: "session_not_found")
        }
        let audioDevices = session.audioVideo.listAudioDevices()
        for dev in audioDevices {
            if device == dev.label {
                session.audioVideo.chooseAudioDevice(mediaDevice: dev)
                return MethodChannelResponse(result: true, arguments: Response.audio_device_updated.rawValue)
            }
        }

        return MethodChannelResponse(result: false, arguments: Response.audio_device_update_failed.rawValue, code: "invalid_argument")
    }

    func setCameraPosition(call: FlutterMethodCall) -> MethodChannelResponse {
        guard let arguments = call.arguments as? [String: Any],
              let position = arguments["position"] as? String,
              position == "front" || position == "back" else {
        return MethodChannelResponse(result: false, arguments: "Unsupported camera position.", code: "invalid_argument")
        }
        guard let session = MeetingSession.shared.meetingSession else {
            return MethodChannelResponse(result: false, arguments: "No Chime meeting session is active.", code: "session_not_found")
        }
        if position != MeetingSession.shared.cameraPosition {
            session.audioVideo.switchCamera()
            MeetingSession.shared.cameraPosition = position
        }
        return MethodChannelResponse(result: true, arguments: position)
    }

    func sendMessage(call: FlutterMethodCall) -> MethodChannelResponse {
        do {
            guard let json = call.arguments as? [String: Any],
                  let topic = json["topic"] as? String,
                  let message = json["message"] as? String else {
                return MethodChannelResponse(result: false, arguments: Response.message_payload_error.rawValue, code: "invalid_argument")
            }
            guard let session = MeetingSession.shared.meetingSession else {
                return MethodChannelResponse(result: false, arguments: "No Chime meeting session is active.", code: "session_not_found")
            }
            guard let messageData = message.data(using: .utf8) else {
                return MethodChannelResponse(result: false, arguments: Response.message_payload_error.rawValue, code: "invalid_argument")
            }
            let requestedLifetime = (json["lifetimeMs"] as? NSNumber)?.intValue ?? 300_000
            try session.audioVideo.realtimeSendDataMessage(
                topic: topic,
                data: messageData,
                lifetimeMs: Int32(clamping: requestedLifetime)
            )
        }catch {
            return MethodChannelResponse(result: false, arguments: "\(Response.message_sent_failed.rawValue) \(error.localizedDescription)")
        }


        return MethodChannelResponse(result: true, arguments: Response.message_sent_successful.rawValue)
    }

    //
    // ————————————————————————————————— Helper Functions —————————————————————————————————
    //

    private func setupAudioVideoFacadeObservers() {
        self.realtimeObserver = MyRealtimeObserver(withMethodChannel: self)
        if self.realtimeObserver != nil {
            MeetingSession.shared.meetingSession?.audioVideo.addRealtimeObserver(observer: self.realtimeObserver!)
            MeetingSession.shared.meetingSession?.logger.info(msg: "realtimeObserver set up...")
        }

        self.audioVideoObserver = MyAudioVideoObserver(withMethodChannel: self)
        if self.audioVideoObserver != nil {
            MeetingSession.shared.meetingSession?.audioVideo.addAudioVideoObserver(observer: self.audioVideoObserver!)
            MeetingSession.shared.meetingSession?.logger.info(msg: "audioVideoObserver set up...")
        }

        self.videoTileObserver = MyVideoTileObserver(withMethodChannel: self)
        if self.videoTileObserver != nil {
            MeetingSession.shared.meetingSession?.audioVideo.addVideoTileObserver(observer: self.videoTileObserver!)
            MeetingSession.shared.meetingSession?.logger.info(msg: "VideoTileObserver set up...")
        }

        self.dataMessageObserver = MyDataMessageObserver(withMethodChannel: self)
        if self.dataMessageObserver != nil {
            MeetingSession.shared.meetingSession?.audioVideo.addRealtimeDataMessageObserver(topic: "chat", observer: self.dataMessageObserver!)
            MeetingSession.shared.meetingSession?.logger.info(msg: "DataMessageObserver set up...")
        }
    }

    func stopAudioVideoFacadeObservers() {
        if let rtObserver = self.realtimeObserver {
            MeetingSession.shared.meetingSession?.audioVideo.removeRealtimeObserver(observer: rtObserver)
        }

        if let avObserver = self.audioVideoObserver {
            MeetingSession.shared.meetingSession?.audioVideo.removeAudioVideoObserver(observer: avObserver)
        }

        if let vtObserver = self.videoTileObserver {
            MeetingSession.shared.meetingSession?.audioVideo.removeVideoTileObserver(observer: vtObserver)
        }

        MeetingSession.shared.meetingSession?.audioVideo.removeRealtimeDataMessageObserverFromTopic(topic: "chat")
    }

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // A call with playAndRecord but without defaultToSpeaker routes
            // mixed remote audio to the earpiece on iPhone.
            try audioSession.setCategory(AVAudioSession.Category.playAndRecord,
                                         options: [.allowBluetoothHFP, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            if audioSession.mode != .voiceChat {
                try audioSession.setMode(.voiceChat)
            }
        } catch {
            MeetingSession.shared.meetingSession?.logger.error(msg: "Error configuring AVAudioSession: \(error.localizedDescription)")
        }
    }
}
