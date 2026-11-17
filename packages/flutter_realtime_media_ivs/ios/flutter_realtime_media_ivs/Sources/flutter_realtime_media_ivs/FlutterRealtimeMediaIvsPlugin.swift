@_implementationOnly import AmazonIVSBroadcast
import AVFoundation
import Flutter
import UIKit

public final class FlutterRealtimeMediaIvsPlugin:
    NSObject,
    FlutterPlugin,
    FlutterStreamHandler
{
    private static let methodChannelName =
        "com.oneplusdream.flutter_realtime_media_ivs/methods"
    private static let eventChannelName =
        "com.oneplusdream.flutter_realtime_media_ivs/events"
    private static let viewType =
        "com.oneplusdream.flutter_realtime_media_ivs/video"

    private var eventSink: FlutterEventSink?
    private var stage: IVSStage?
    private var contentStage: IVSStage?
    // Creating IVSDeviceDiscovery immediately changes the process-wide
    // AVAudioSession category/mode and can deactivate the active audio engine.
    // The combined Flutter SDK registers all vendor plugins at startup, so
    // this must never run until an IVS publisher actually needs its devices.
    private var discovery: IVSDeviceDiscovery?
    private var publishStreams: [IVSLocalStageStream] = []
    private var cameraStream: IVSLocalStageStream?
    private var microphoneStream: IVSLocalStageStream?
    private var processedVideoSource: IvsIosSystemScreenSource?
    private var iosScreenStream: IVSLocalStageStream?
    private var iosScreenSource: IvsIosSystemScreenSource?
    private var remoteVideoStreams: [String: IVSStageStream] = [:]
    private var platformViews: [IvsVideoPlatformView] = []
    private var shouldPublish = false
    private var videoEnabled = false
    private var connectedOnce = false
    private var pendingJoinResult: FlutterResult?
    private lazy var stageDelegate = IvsStageDelegateProxy(owner: self)

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FlutterRealtimeMediaIvsPlugin()
        let methods = FlutterMethodChannel(
            name: methodChannelName,
            binaryMessenger: registrar.messenger()
        )
        let events = FlutterEventChannel(
            name: eventChannelName,
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methods)
        events.setStreamHandler(instance)
        registrar.register(
            IvsVideoPlatformViewFactory(plugin: instance),
            withId: viewType
        )
    }

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            switch call.method {
            case "probeDevices":
                self.probeDevices(result: result)
            case "listAudioDevices":
                self.listAudioDevices(result: result)
            case "selectAudioDevice":
                self.selectAudioDevice(call.arguments, result: result)
            case "join":
                self.join(call.arguments, result: result)
            case "exchangeToken":
                self.exchangeToken(call.arguments, result: result)
            case "leave":
                self.leave()
                result(nil)
            case "setMuted":
                self.setMuted(call.arguments, result: result)
            case "setVideoEnabled":
                self.setVideoEnabled(call.arguments, result: result)
            case "attachProcessedVideoSource":
                self.attachProcessedVideoSource(call.arguments, result: result)
            case "detachProcessedVideoSource":
                self.detachProcessedVideoSource()
                result(nil)
            case "attachIosScreenCaptureKitSource":
                self.attachIosScreenCaptureKitSource(call.arguments, result: result)
            case "detachIosScreenCaptureKitSource":
                self.detachIosScreenCaptureKitSource()
                result(nil)
            case "switchCamera":
                self.switchCamera(call.arguments, result: result)
            case "requestStats":
                self.requestStats()
                result(nil)
            case "dispose":
                self.disposeStage()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func probeDevices(result: @escaping FlutterResult) {
        // Pre-join checks are read-only. Even a temporary IVSDeviceDiscovery
        // reconfigures AVAudioSession and can terminate a LiveKit capture.
        let cameras = AVCaptureDevice.devices(for: .video).count
        let microphones = AVCaptureDevice.devices(for: .audio).count
        result([
            "cameras": cameras,
            "microphones": microphones,
        ])
    }

    private func join(_ arguments: Any?, result: @escaping FlutterResult) {
        guard stage == nil else {
            result(
                FlutterError(
                    code: "invalid_state",
                    message: "An Amazon IVS Stage is already active.",
                    details: nil
                )
            )
            return
        }
        guard
            let values = arguments as? [String: Any],
            let token = nonEmptyString(values["token"]),
            let role = nonEmptyString(values["role"])
        else {
            result(
                FlutterError(
                    code: "invalid_join_info",
                    message: "IVS Stage token and role are required.",
                    details: nil
                )
            )
            return
        }

        shouldPublish = role != "viewer"
        connectedOnce = false
        prepareLocalStreams()

        do {
            let newStage = try IVSStage(token: token, strategy: stageDelegate)
            newStage.addRenderer(stageDelegate)
            stage = newStage
            pendingJoinResult = result
            try newStage.join()
        } catch {
            pendingJoinResult = nil
            stage = nil
            result(
                FlutterError(
                    code: "native_error",
                    message: error.localizedDescription,
                    details: String(describing: error)
                )
            )
        }
    }

    private func exchangeToken(
        _ arguments: Any?,
        result: @escaping FlutterResult
    ) {
        guard
            let stage,
            let values = arguments as? [String: Any],
            let token = nonEmptyString(values["token"])
        else {
            result(
                FlutterError(
                    code: "invalid_state",
                    message: "An active IVS Stage and replacement token are required.",
                    details: nil
                )
            )
            return
        }
        if let nextRole = nonEmptyString(values["role"]) {
            let nextPublish = nextRole != "viewer"
            if nextPublish != shouldPublish {
                shouldPublish = nextPublish
                if !nextPublish {
                    detachIosScreenCaptureKitSource()
                    detachProcessedVideoSource()
                }
                prepareLocalStreams()
            }
        }
        do {
            try stage.exchangeToken(token)
            stage.refreshStrategy()
            result(nil)
        } catch {
            result(
                FlutterError(
                    code: "native_error",
                    message: error.localizedDescription,
                    details: String(describing: error)
                )
            )
        }
    }

    private func listAudioDevices(result: @escaping FlutterResult) {
        let session = AVAudioSession.sharedInstance()
        var devices: [[String: String]] = [
            ["id": "speaker", "label": "Speaker"],
            ["id": "receiver", "label": "Receiver"],
        ]
        var seenIds: Set<String> = ["speaker", "receiver"]
        if let inputs = session.availableInputs {
            for input in inputs where input.portType != .builtInMic {
                if seenIds.insert(input.uid).inserted {
                    devices.append(["id": input.uid, "label": input.portName])
                }
            }
        }
        for output in session.currentRoute.outputs {
            if output.portType == .builtInSpeaker || output.portType == .builtInReceiver {
                continue
            }
            if seenIds.insert(output.uid).inserted {
                devices.append(["id": output.uid, "label": output.portName])
            }
        }
        result(devices)
    }

    private func selectAudioDevice(
        _ arguments: Any?,
        result: @escaping FlutterResult
    ) {
        guard let values = arguments as? [String: Any],
              let id = nonEmptyString(values["id"]) else {
            result(
                FlutterError(
                    code: "invalid_argument",
                    message: "Audio output device id is required.",
                    details: nil
                )
            )
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            if id == "speaker" {
                try session.overrideOutputAudioPort(.speaker)
            } else if id == "receiver" {
                try session.overrideOutputAudioPort(.none)
                if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                    try session.setPreferredInput(builtIn)
                }
            } else if let matchingInput = session.availableInputs?.first(where: { $0.uid == id }) {
                try session.overrideOutputAudioPort(.none)
                try session.setPreferredInput(matchingInput)
            } else {
                result(
                    FlutterError(
                        code: "invalid_argument",
                        message: "Unknown audio output device id: \(id).",
                        details: nil
                    )
                )
                return
            }
            result(nil)
        } catch {
            result(
                FlutterError(
                    code: "native_error",
                    message: error.localizedDescription,
                    details: String(describing: error)
                )
            )
        }
    }

    private func leave() {
        detachIosScreenCaptureKitSource()
        detachProcessedVideoSource()
        stage?.leave()
        if let stage {
            stage.remove(stageDelegate)
        }
        stage = nil
        pendingJoinResult = nil
        connectedOnce = false
        videoEnabled = false
        publishStreams.removeAll()
        cameraStream = nil
        microphoneStream = nil
        remoteVideoStreams.removeAll()
        discovery = nil
        refreshPlatformViews()
    }

    private func attachProcessedVideoSource(
        _ arguments: Any?, result: @escaping FlutterResult
    ) {
        guard let stage, shouldPublish else {
            result(FlutterError(code: "invalid_state",
                                message: "An active IVS publisher Stage is required.",
                                details: nil))
            return
        }
        guard let sourceId = nonEmptyString((arguments as? [String: Any])?["sourceId"]) else {
            result(FlutterError(code: "invalid_join_info",
                                message: "sourceId is required.",
                                details: nil))
            return
        }
        let wasEnabled = videoEnabled
        detachProcessedVideoSource()
        if let existing = cameraStream {
            existing.setMuted(true)
            publishStreams.removeAll { $0 === existing }
            cameraStream = nil
        }
        let device = deviceDiscovery().createImageSource(withName: "processed-camera")
        let stream = IVSLocalStageStream(device: device)
        stream.setMuted(!wasEnabled)
        stream.delegate = stageDelegate
        let source = IvsIosSystemScreenSource(sourceId: sourceId, output: device)
        do {
            try source.start()
            processedVideoSource = source
            cameraStream = stream
            videoEnabled = wasEnabled
            publishStreams.insert(stream, at: 0)
            stage.refreshStrategy()
            refreshPlatformViews()
            result(nil)
        } catch {
            source.stop()
            result(FlutterError(code: "native_error",
                                message: error.localizedDescription,
                                details: nil))
        }
    }

    private func detachProcessedVideoSource() {
        guard processedVideoSource != nil else { return }
        let wasEnabled = videoEnabled
        processedVideoSource?.stop()
        processedVideoSource = nil
        if let existing = cameraStream {
            existing.setMuted(true)
            publishStreams.removeAll { $0 === existing }
            cameraStream = nil
        }
        if shouldPublish, wasEnabled, let camera = defaultCameraDevice() {
            let stream = IVSLocalStageStream(device: camera)
            stream.setMuted(false)
            stream.delegate = stageDelegate
            cameraStream = stream
            publishStreams.insert(stream, at: 0)
        }
        stage?.refreshStrategy()
        refreshPlatformViews()
    }

    private func attachIosScreenCaptureKitSource(
        _ arguments: Any?, result: @escaping FlutterResult
    ) {
        let values = arguments as? [String: Any]
        guard let stage, shouldPublish,
              let sourceId = values?["sourceId"] as? String,
              !sourceId.isEmpty else {
            result(FlutterError(code: "invalid_state",
                                message: "IVS Stage and the native screen source must be active.",
                                details: nil))
            return
        }
        detachIosScreenCaptureKitSource()
        let auxiliaryToken = nonEmptyString(values?["auxiliaryToken"])
        let device = deviceDiscovery().createImageSource(withName: "screen-share")
        let stream = IVSLocalStageStream(device: device)
        stream.setMuted(false)
        stream.delegate = stageDelegate
        let source = IvsIosSystemScreenSource(sourceId: sourceId, output: device)
        var auxStage: IVSStage?
        do {
            try source.start()
            iosScreenSource = source
            iosScreenStream = stream
            if let auxiliaryToken {
                let created = try IVSStage(token: auxiliaryToken, strategy: stageDelegate)
                created.addRenderer(stageDelegate)
                auxStage = created
                contentStage = created
                try created.join()
            } else {
                stage.refreshStrategy()
            }
            refreshPlatformViews()
            result(nil)
        } catch {
            auxStage?.leave()
            if auxStage != nil {
                auxStage?.remove(stageDelegate)
            }
            contentStage = nil
            iosScreenSource = nil
            iosScreenStream = nil
            source.stop()
            result(FlutterError(code: "native_error", message: error.localizedDescription,
                                details: nil))
        }
    }

    private func detachIosScreenCaptureKitSource() {
        guard iosScreenStream != nil || iosScreenSource != nil || contentStage != nil else {
            return
        }
        if let auxStage = contentStage {
            auxStage.leave()
            auxStage.remove(stageDelegate)
            contentStage = nil
        }
        iosScreenSource?.stop()
        iosScreenSource = nil
        iosScreenStream = nil
        stage?.refreshStrategy()
        refreshPlatformViews()
    }

    private func disposeStage() {
        leave()
        platformViews.removeAll()
    }

    private func deviceDiscovery() -> IVSDeviceDiscovery {
        if let discovery { return discovery }
        let created = IVSDeviceDiscovery()
        discovery = created
        return created
    }

    private func defaultCameraDevice() -> IVSDevice? {
        let devices = deviceDiscovery().listLocalDevices()
        return devices.first {
            let descriptor = $0.descriptor()
            return descriptor.type == .camera && descriptor.position == .front
        } ?? devices.first {
            $0.descriptor().type == .camera
        }
    }

    private func prepareLocalStreams() {
        iosScreenSource?.stop()
        iosScreenSource = nil
        iosScreenStream = nil
        processedVideoSource?.stop()
        processedVideoSource = nil
        videoEnabled = false
        publishStreams.removeAll()
        cameraStream = nil
        microphoneStream = nil
        guard shouldPublish else {
            refreshPlatformViews()
            return
        }

        let devices = deviceDiscovery().listLocalDevices()
        let camera = defaultCameraDevice()
        let microphone = devices.first {
            let descriptor = $0.descriptor()
            return descriptor.type == .microphone && descriptor.isDefault
        } ?? devices.first {
            $0.descriptor().type == .microphone
        }

        if let camera {
            let stream = IVSLocalStageStream(device: camera)
            stream.setMuted(true)
            stream.delegate = stageDelegate
            cameraStream = stream
            publishStreams.append(stream)
        }
        if let microphone {
            let stream = IVSLocalStageStream(device: microphone)
            stream.setMuted(true)
            stream.delegate = stageDelegate
            microphoneStream = stream
            publishStreams.append(stream)
        }
        refreshPlatformViews()
    }

    private func setMuted(
        _ arguments: Any?,
        result: @escaping FlutterResult
    ) {
        guard shouldPublish else {
            result(
                FlutterError(
                    code: "unsupported_feature",
                    message: "IVS viewer sessions cannot publish audio.",
                    details: nil
                )
            )
            return
        }
        let muted =
            ((arguments as? [String: Any])?["muted"] as? Bool) ?? false
        guard let microphoneStream else {
            if muted {
                result(nil)
            } else {
                result(
                    FlutterError(
                        code: "invalid_state",
                        message: "No IVS microphone is available.",
                        details: nil
                    )
                )
            }
            return
        }
        microphoneStream.setMuted(muted)
        result(nil)
    }

    private func setVideoEnabled(
        _ arguments: Any?,
        result: @escaping FlutterResult
    ) {
        guard shouldPublish else {
            result(
                FlutterError(
                    code: "unsupported_feature",
                    message: "IVS viewer sessions cannot publish video.",
                    details: nil
                )
            )
            return
        }
        let enabled =
            ((arguments as? [String: Any])?["enabled"] as? Bool) ?? false
        videoEnabled = enabled
        if cameraStream == nil, processedVideoSource == nil, enabled,
           let camera = defaultCameraDevice()
        {
            let stream = IVSLocalStageStream(device: camera)
            stream.setMuted(true)
            stream.delegate = stageDelegate
            cameraStream = stream
            publishStreams.insert(stream, at: 0)
            stage?.refreshStrategy()
        }
        guard let cameraStream else {
            if !enabled {
                result(nil)
            } else {
                videoEnabled = false
                result(
                    FlutterError(
                        code: "invalid_state",
                        message: "No IVS camera is available.",
                        details: nil
                    )
                )
            }
            return
        }
        cameraStream.setMuted(!enabled)
        refreshPlatformViews()
        result(nil)
    }

    private func switchCamera(
        _ arguments: Any?,
        result: @escaping FlutterResult
    ) {
        guard
            shouldPublish,
            let cameraStream,
            let values = arguments as? [String: Any],
            let requested = nonEmptyString(values["position"]),
            let multiSource = cameraStream.device as? IVSMultiSourceDevice
        else {
            result(
                FlutterError(
                    code: "invalid_state",
                    message: "IVS camera switching requires an active camera.",
                    details: nil
                )
            )
            return
        }

        let desired: IVSDevicePosition =
            requested == "back" ? .back : .front
        guard let source = multiSource
            .listAvailableInputSources()
            .first(where: { $0.position == desired })
        else {
            result(
                FlutterError(
                    code: "invalid_state",
                    message: "Requested IVS camera is unavailable.",
                    details: nil
                )
            )
            return
        }

        multiSource.setPreferredInputSource(source) { error in
            DispatchQueue.main.async {
                if let error {
                    result(
                        FlutterError(
                            code: "native_error",
                            message: error.localizedDescription,
                            details: String(describing: error)
                        )
                    )
                } else {
                    self.refreshPlatformViews()
                    result(nil)
                }
            }
        }
    }

    private func requestStats() {
        for stream in publishStreams {
            try? stream.requestRTCStats()
        }
        for stream in remoteVideoStreams.values {
            try? stream.requestRTCStats()
        }
    }

    fileprivate func stage(
        _ stage: IVSStage,
        streamsToPublishForParticipant participant: IVSParticipantInfo
    ) -> [IVSLocalStageStream] {
        if stage === contentStage {
            return iosScreenStream.map { [$0] } ?? []
        }
        if let iosScreenStream, contentStage == nil {
            return [iosScreenStream, microphoneStream].compactMap { $0 }
        }
        return publishStreams
    }

    fileprivate func stage(
        _ stage: IVSStage,
        shouldPublishParticipant participant: IVSParticipantInfo
    ) -> Bool {
        if stage === contentStage { return true }
        return shouldPublish
    }

    fileprivate func stage(
        _ stage: IVSStage,
        shouldSubscribeToParticipant participant: IVSParticipantInfo
    ) -> IVSStageSubscribeType {
        if stage === contentStage { return .none }
        return participant.isLocal ? .none : .audioVideo
    }

    fileprivate func stage(
        _ stage: IVSStage,
        didChange connectionState: IVSStageConnectionState,
        withError error: Error?
    ) {
        if stage === contentStage {
            if connectionState == .disconnected, let error {
                emit([
                    "type": "error",
                    "code": -1,
                    "message": error.localizedDescription,
                ])
            }
            return
        }
        switch connectionState {
        case .connected:
            if let pendingJoinResult {
                self.pendingJoinResult = nil
                pendingJoinResult(nil)
            } else if connectedOnce {
                emit(["type": "recovered"])
            }
            connectedOnce = true
        case .connecting:
            if connectedOnce {
                emit(["type": "reconnecting"])
            }
        case .disconnected:
            if let pendingJoinResult, let error {
                self.pendingJoinResult = nil
                pendingJoinResult(
                    FlutterError(
                        code: "native_error",
                        message: error.localizedDescription,
                        details: String(describing: error)
                    )
                )
            }
        @unknown default:
            break
        }
    }

    private static func isContentUserId(_ userId: String) -> Bool {
        userId.hasSuffix("#content")
    }

    private static func stripContentSuffix(_ userId: String) -> String {
        isContentUserId(userId)
            ? String(userId.dropLast("#content".count))
            : userId
    }

    fileprivate func stage(
        _ stage: IVSStage,
        participantDidJoin participant: IVSParticipantInfo
    ) {
        guard stage === self.stage, !participant.isLocal else { return }
        if Self.isContentUserId(participant.userId) { return }
        emit([
            "type": "participantJoined",
            "userId": participant.userId,
            "displayName":
                participant.attributes["displayName"] ?? participant.userId,
        ])
    }

    fileprivate func stage(
        _ stage: IVSStage,
        participantMetadataDidUpdate participant: IVSParticipantInfo
    ) {
        self.stage(stage, participantDidJoin: participant)
    }

    fileprivate func stage(
        _ stage: IVSStage,
        participantDidLeave participant: IVSParticipantInfo
    ) {
        guard stage === self.stage, !participant.isLocal else { return }
        remoteVideoStreams.removeValue(forKey: participant.userId)
        refreshPlatformViews()
        if Self.isContentUserId(participant.userId) {
            emit([
                "type": "screenShareChanged",
                "userId": Self.stripContentSuffix(participant.userId),
                "trackUserId": participant.userId,
                "available": false,
            ])
            return
        }
        emit([
            "type": "participantLeft",
            "userId": participant.userId,
        ])
    }

    private static func isVideoDeviceType(_ type: IVSDeviceType) -> Bool {
        type == .camera || type == .userImage
    }

    fileprivate func stage(
        _ stage: IVSStage,
        participant: IVSParticipantInfo,
        didAdd streams: [IVSStageStream]
    ) {
        guard stage === self.stage else { return }
        let isContent = Self.isContentUserId(participant.userId)
        for stream in streams {
            stream.delegate = stageDelegate
            let type = stream.device.descriptor().type
            if !participant.isLocal,
               Self.isVideoDeviceType(type)
            {
                remoteVideoStreams[participant.userId] = stream
                if isContent {
                    emit([
                        "type": "screenShareChanged",
                        "userId": Self.stripContentSuffix(participant.userId),
                        "trackUserId": participant.userId,
                        "available": !stream.isMuted,
                    ])
                } else {
                    emit([
                        "type": "videoChanged",
                        "userId": participant.userId,
                        "available": !stream.isMuted,
                    ])
                }
            } else if !participant.isLocal,
                      !isContent,
                      type == .microphone
            {
                emit([
                    "type": "audioChanged",
                    "userId": participant.userId,
                    "available": !stream.isMuted,
                ])
            }
        }
        refreshPlatformViews()
    }

    fileprivate func stage(
        _ stage: IVSStage,
        participant: IVSParticipantInfo,
        didRemove streams: [IVSStageStream]
    ) {
        guard stage === self.stage else { return }
        let isContent = Self.isContentUserId(participant.userId)
        for stream in streams where !participant.isLocal {
            let type = stream.device.descriptor().type
            if Self.isVideoDeviceType(type) {
                remoteVideoStreams.removeValue(forKey: participant.userId)
                if isContent {
                    emit([
                        "type": "screenShareChanged",
                        "userId": Self.stripContentSuffix(participant.userId),
                        "trackUserId": participant.userId,
                        "available": false,
                    ])
                } else {
                    emit([
                        "type": "videoChanged",
                        "userId": participant.userId,
                        "available": false,
                    ])
                }
            } else if !isContent, type == .microphone {
                emit([
                    "type": "audioChanged",
                    "userId": participant.userId,
                    "available": false,
                ])
            }
        }
        refreshPlatformViews()
    }

    fileprivate func stage(
        _ stage: IVSStage,
        participant: IVSParticipantInfo,
        didChangeMutedStreams streams: [IVSStageStream]
    ) {
        guard stage === self.stage else { return }
        let isContent = Self.isContentUserId(participant.userId)
        for stream in streams where !participant.isLocal {
            let type = stream.device.descriptor().type
            if Self.isVideoDeviceType(type) {
                if isContent {
                    emit([
                        "type": "screenShareChanged",
                        "userId": Self.stripContentSuffix(participant.userId),
                        "trackUserId": participant.userId,
                        "available": !stream.isMuted,
                    ])
                } else {
                    emit([
                        "type": "videoChanged",
                        "userId": participant.userId,
                        "available": !stream.isMuted,
                    ])
                }
            } else if !isContent, type == .microphone {
                emit([
                    "type": "audioChanged",
                    "userId": participant.userId,
                    "available": !stream.isMuted,
                ])
            }
        }
    }

    fileprivate func stage(
        _ stage: IVSStage,
        participant: IVSParticipantInfo,
        didChange publishState: IVSParticipantPublishState
    ) {}

    fileprivate func stage(
        _ stage: IVSStage,
        participant: IVSParticipantInfo,
        didChange subscribeState: IVSParticipantSubscribeState
    ) {}

    fileprivate func stage(
        _ stage: IVSStage,
        participant: IVSParticipantInfo,
        stream: IVSRemoteStageStream,
        didChange layers: [IVSRemoteStageStreamLayer]
    ) {}

    fileprivate func stage(
        _ stage: IVSStage,
        participant: IVSParticipantInfo,
        stream: IVSRemoteStageStream,
        didSelect layer: IVSRemoteStageStreamLayer?,
        reason: IVSRemoteStageStream.LayerSelectedReason
    ) {}

    fileprivate func stage(
        _ stage: IVSStage,
        participant: IVSParticipantInfo,
        stream: IVSRemoteStageStream,
        didChangeStreamAdaption adaption: Bool
    ) {}

    fileprivate func stage(
        _ stage: IVSStage,
        didChangeSubscriberCount subscriberCount: Int
    ) {}

    fileprivate func streamDidChangeIsMuted(_ stream: IVSStageStream) {}

    fileprivate func stream(
        _ stream: IVSStageStream,
        didGenerateRTCStats stats: [String: [String: String]]
    ) {
        var event: [String: Any] = ["type": "stats"]
        if let rtt = firstStat(stats, keys: [
            "currentRoundTripTime",
            "roundTripTime",
        ]) {
            event["rttMs"] = Int(rtt * 1000.0)
        }
        if let jitter = firstStat(stats, keys: ["jitter"]) {
            event["jitterMs"] = Int(jitter * 1000.0)
        }
        emit(event)
    }

    fileprivate func stream(
        _ stream: IVSStageStream,
        didGenerate stats: IVSLocalAudioStats
    ) {}

    fileprivate func stream(
        _ stream: IVSStageStream,
        didGenerate stats: [IVSLocalVideoStats]
    ) {}

    fileprivate func stream(
        _ stream: IVSStageStream,
        didGenerate stats: IVSRemoteAudioStats
    ) {}

    fileprivate func stream(
        _ stream: IVSStageStream,
        didGenerate stats: IVSRemoteVideoStats
    ) {}

    fileprivate func add(_ view: IvsVideoPlatformView) {
        platformViews.append(view)
        refresh(view)
    }

    fileprivate func remove(_ view: IvsVideoPlatformView) {
        platformViews.removeAll { $0 === view }
    }

    private func refreshPlatformViews() {
        platformViews.forEach(refresh)
    }

    private func refresh(_ view: IvsVideoPlatformView) {
        let stream: IVSStageStream?
        if view.isLocal {
            stream = view.isScreenShare ? iosScreenStream : cameraStream
        } else {
            stream = remoteVideoStreams[view.userId]
        }
        view.bind(stream)
    }

    private func emit(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(event)
        }
    }

    private func firstStat(
        _ stats: [String: [String: String]],
        keys: [String]
    ) -> Double? {
        for report in stats.values {
            for key in keys {
                if let raw = report[key], let value = Double(raw) {
                    return value
                }
            }
        }
        return nil
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        let text = String(describing: value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

private final class IvsStageDelegateProxy:
    NSObject,
    IVSStageStrategy,
    IVSStageRenderer,
    IVSStageStreamDelegate
{
    private weak var owner: FlutterRealtimeMediaIvsPlugin?

    init(owner: FlutterRealtimeMediaIvsPlugin) {
        self.owner = owner
    }

    func stage(
        _ stage: IVSStage,
        streamsToPublishForParticipant participant: IVSParticipantInfo
    ) -> [IVSLocalStageStream] {
        owner?.stage(
            stage,
            streamsToPublishForParticipant: participant
        ) ?? []
    }

    func stage(
        _ stage: IVSStage,
        shouldPublishParticipant participant: IVSParticipantInfo
    ) -> Bool {
        owner?.stage(
            stage,
            shouldPublishParticipant: participant
        ) ?? false
    }

    func stage(
        _ stage: IVSStage,
        shouldSubscribeToParticipant participant: IVSParticipantInfo
    ) -> IVSStageSubscribeType {
        owner?.stage(
            stage,
            shouldSubscribeToParticipant: participant
        ) ?? .none
    }

    func stage(
        _ stage: IVSStage,
        didChange connectionState: IVSStageConnectionState,
        withError error: Error?
    ) {
        owner?.stage(
            stage,
            didChange: connectionState,
            withError: error
        )
    }

    func stage(
        _ stage: IVSStage,
        participantDidJoin participant: IVSParticipantInfo
    ) {
        owner?.stage(stage, participantDidJoin: participant)
    }

    func stage(
        _ stage: IVSStage,
        participantMetadataDidUpdate participant: IVSParticipantInfo
    ) {
        owner?.stage(stage, participantMetadataDidUpdate: participant)
    }

    func stage(
        _ stage: IVSStage,
        participantDidLeave participant: IVSParticipantInfo
    ) {
        owner?.stage(stage, participantDidLeave: participant)
    }

    func stage(
        _ stage: IVSStage,
        participant: IVSParticipantInfo,
        didChange publishState: IVSParticipantPublishState
    ) {
        owner?.stage(
            stage,
            participant: participant,
            didChange: publishState
        )
    }

    func stage(
        _ stage: IVSStage,
        participant: IVSParticipantInfo,
        didChange subscribeState: IVSParticipantSubscribeState
    ) {
        owner?.stage(
            stage,
            participant: participant,
            didChange: subscribeState
        )
    }

    func stage(
        _ stage: IVSStage,
        participant: IVSParticipantInfo,
        didAdd streams: [IVSStageStream]
    ) {
        owner?.stage(
            stage,
            participant: participant,
            didAdd: streams
        )
    }

    func stage(
        _ stage: IVSStage,
        participant: IVSParticipantInfo,
        didRemove streams: [IVSStageStream]
    ) {
        owner?.stage(
            stage,
            participant: participant,
            didRemove: streams
        )
    }

    func stage(
        _ stage: IVSStage,
        participant: IVSParticipantInfo,
        didChangeMutedStreams streams: [IVSStageStream]
    ) {
        owner?.stage(
            stage,
            participant: participant,
            didChangeMutedStreams: streams
        )
    }

    func stage(
        _ stage: IVSStage,
        participant: IVSParticipantInfo,
        stream: IVSRemoteStageStream,
        didChange layers: [IVSRemoteStageStreamLayer]
    ) {
        owner?.stage(
            stage,
            participant: participant,
            stream: stream,
            didChange: layers
        )
    }

    func stage(
        _ stage: IVSStage,
        participant: IVSParticipantInfo,
        stream: IVSRemoteStageStream,
        didSelect layer: IVSRemoteStageStreamLayer?,
        reason: IVSRemoteStageStream.LayerSelectedReason
    ) {
        owner?.stage(
            stage,
            participant: participant,
            stream: stream,
            didSelect: layer,
            reason: reason
        )
    }

    func stage(
        _ stage: IVSStage,
        participant: IVSParticipantInfo,
        stream: IVSRemoteStageStream,
        didChangeStreamAdaption adaption: Bool
    ) {
        owner?.stage(
            stage,
            participant: participant,
            stream: stream,
            didChangeStreamAdaption: adaption
        )
    }

    func stage(
        _ stage: IVSStage,
        didChangeSubscriberCount subscriberCount: Int
    ) {
        owner?.stage(
            stage,
            didChangeSubscriberCount: subscriberCount
        )
    }

    func streamDidChangeIsMuted(_ stream: IVSStageStream) {
        owner?.streamDidChangeIsMuted(stream)
    }

    func stream(
        _ stream: IVSStageStream,
        didGenerateRTCStats stats: [String: [String: String]]
    ) {
        owner?.stream(stream, didGenerateRTCStats: stats)
    }

    func stream(
        _ stream: IVSStageStream,
        didGenerate stats: IVSLocalAudioStats
    ) {
        owner?.stream(stream, didGenerate: stats)
    }

    func stream(
        _ stream: IVSStageStream,
        didGenerate stats: [IVSLocalVideoStats]
    ) {
        owner?.stream(stream, didGenerate: stats)
    }

    func stream(
        _ stream: IVSStageStream,
        didGenerate stats: IVSRemoteAudioStats
    ) {
        owner?.stream(stream, didGenerate: stats)
    }

    func stream(
        _ stream: IVSStageStream,
        didGenerate stats: IVSRemoteVideoStats
    ) {
        owner?.stream(stream, didGenerate: stats)
    }
}

private final class IvsVideoPlatformView:
    NSObject,
    FlutterPlatformView
{
    let userId: String
    let isLocal: Bool
    let isScreenShare: Bool
    let fit: String
    private weak var plugin: FlutterRealtimeMediaIvsPlugin?
    private let container = UIView()

    init(
        frame: CGRect,
        userId: String,
        isLocal: Bool,
        isScreenShare: Bool,
        fit: String,
        plugin: FlutterRealtimeMediaIvsPlugin
    ) {
        self.userId = userId
        self.isLocal = isLocal
        self.isScreenShare = isScreenShare
        self.fit = fit
        self.plugin = plugin
        super.init()
        container.frame = frame
        container.backgroundColor = .black
        container.clipsToBounds = true
        plugin.add(self)
    }

    func view() -> UIView { container }

    func bind(_ stream: IVSStageStream?) {
        container.subviews.forEach { $0.removeFromSuperview() }
        guard
            let imageDevice = stream?.device as? IVSImageDevice,
            let preview = try? imageDevice.previewView(with: fit == "cover" ? .fill : .fit)
        else {
            return
        }
        preview.frame = container.bounds
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(preview)
    }

    deinit {
        plugin?.remove(self)
    }
}

private final class IvsVideoPlatformViewFactory:
    NSObject,
    FlutterPlatformViewFactory
{
    private weak var plugin: FlutterRealtimeMediaIvsPlugin?

    init(plugin: FlutterRealtimeMediaIvsPlugin) {
        self.plugin = plugin
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        let values = args as? [String: Any] ?? [:]
        return IvsVideoPlatformView(
            frame: frame,
            userId: values["userId"] as? String ?? "",
            isLocal: values["isLocal"] as? Bool ?? false,
            isScreenShare: values["isScreenShare"] as? Bool ?? false,
            fit: values["fit"] as? String ?? "contain",
            plugin: plugin!
        )
    }
}
