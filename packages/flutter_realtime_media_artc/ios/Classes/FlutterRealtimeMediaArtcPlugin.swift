import AVFoundation
import Flutter
import AliVCSDK_ARTC
import UIKit

public final class FlutterRealtimeMediaArtcPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private static let methodChannelName = "com.oneplusdream.flutter_realtime_media_artc/methods"
    private static let eventChannelName = "com.oneplusdream.flutter_realtime_media_artc/events"
    private static let viewType = "com.oneplusdream.flutter_realtime_media_artc/video"

    private var methodChannel: FlutterMethodChannel?
    private var eventSink: FlutterEventSink?
    private var engine: AliRtcEngine?
    private var viewer = false
    private var inChannel = false
    private var disposed = false
    private var localUserId: String?
    private var pendingJoinResult: FlutterResult?
    private var pendingLeaveResult: FlutterResult?
    private var leaveTimeout: DispatchWorkItem?
    private var videoViews: [ArtcVideoPlatformView] = []
    private var iosScreenSink: ArtcIosExternalScreenSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FlutterRealtimeMediaArtcPlugin()
        let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: registrar.messenger())
        let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: registrar.messenger())
        instance.methodChannel = methods
        registrar.addMethodCallDelegate(instance, channel: methods)
        events.setStreamHandler(instance)
        registrar.register(ArtcVideoPlatformViewFactory(plugin: instance), withId: viewType)
    }

    private func attachIosScreenCaptureKitSource(
        _ arguments: Any?, result: @escaping FlutterResult
    ) {
        guard requirePublisher(result) else { return }
        guard let sourceId = (arguments as? [String: Any])?["sourceId"] as? String,
              !sourceId.isEmpty, let engine else {
            fail(result, code: "invalid_argument", message: "The ScreenCaptureKit native source ID is missing.")
            return
        }
        iosScreenSink?.stop()
        let sink = ArtcIosExternalScreenSink(sourceId: sourceId, engine: engine)
        do {
            try sink.start()
            iosScreenSink = sink
            result(nil)
        } catch {
            fail(result, code: "native_error",
                 message: "ARTC rejected the external iOS screen video source: \(error.localizedDescription)")
        }
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
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
            case "join": self.join(call.arguments, result: result)
            case "leave": self.leave(result: result)
            case "setMuted": self.setMuted(call.arguments, result: result)
            case "setVideoEnabled": self.setVideoEnabled(call.arguments, result: result)
            case "switchCamera": self.switchCamera(call.arguments, result: result)
            case "sendMessage": self.sendMessage(call.arguments, result: result)
            case "attachIosScreenCaptureKitSource":
                self.attachIosScreenCaptureKitSource(call.arguments, result: result)
            case "detachIosScreenCaptureKitSource":
                self.iosScreenSink?.stop()
                self.iosScreenSink = nil
                result(nil)
            case "dispose": self.disposeEngine(); result(nil)
            default: result(FlutterMethodNotImplemented)
            }
        }
    }

    private func join(_ arguments: Any?, result: @escaping FlutterResult) {
        guard !disposed, let values = arguments as? [String: Any] else {
            fail(result, code: "invalid_join_info", message: "ARTC join data is missing or invalid.")
            return
        }
        if inChannel {
            fail(result, code: "invalid_state", message: "Leave the current ARTC channel before joining another.")
            return
        }
        let appId = string(values, "appId")
        let channelId = string(values, "channelId")
        let userId = string(values, "userId")
        let authInfo = string(values, "authInfo")
        let displayName = string(values, "displayName")
        let role = string(values, "role")
        let roomMode = string(values, "roomMode")
        guard !appId.isEmpty, !channelId.isEmpty, !userId.isEmpty, !authInfo.isEmpty,
              ["participant", "host", "viewer"].contains(role),
              (role == "participant") == (roomMode == "communication") else {
            fail(result, code: "invalid_join_info", message: "ARTC join data is invalid or the role does not match its channel mode.")
            return
        }

        let rtc = AliRtcEngine.sharedInstance(self, extras: nil)
        engine = rtc
        viewer = role == "viewer"
        localUserId = userId
        let profile = roomMode == "communication" ? AliRtcChannelProfile.communication : AliRtcChannelProfile.interactivelive
        guard rtc.setChannelProfile(profile) == 0 else {
            fail(result, code: "native_error", message: "ARTC rejected the channel profile.")
            return
        }
        if roomMode == "interactiveLive" {
            let clientRole = viewer ? AliRtcClientRole.rolelive : AliRtcClientRole.roleInteractive
            guard rtc.setClientRole(clientRole) == 0 else {
                fail(result, code: "native_error", message: "ARTC rejected the client role.")
                return
            }
        }
        _ = rtc.setParameter("{\"data\":{\"enablePubDataChannel\":true,\"enableSubDataChannel\":true}}")
        _ = rtc.publishLocalAudioStream(false)
        _ = rtc.publishLocalVideoStream(false)
        _ = rtc.enableLocalVideo(false)
        pendingJoinResult = result
        let code = rtc.joinChannel(authInfo, channelId: channelId, userId: userId, name: displayName, onResultWithUserId: nil)
        if code != 0 {
            pendingJoinResult = nil
            fail(result, code: "native_error", message: "ARTC failed to start joining (\(code)).")
        }
    }

    private func leave(result: @escaping FlutterResult) {
        iosScreenSink?.stop()
        iosScreenSink = nil
        guard let engine, inChannel else { result(nil); return }
        if pendingLeaveResult != nil {
            fail(result, code: "invalid_state", message: "ARTC leave is already in progress.")
            return
        }
        pendingLeaveResult = result
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishLeave(error: "ARTC did not confirm channel leave before timeout.")
        }
        leaveTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
        let code = engine.leaveChannel()
        if code != 0 {
            finishLeave(error: "ARTC failed to leave the channel (\(code)).")
        }
    }

    private func finishLeave(error: String?) {
        leaveTimeout?.cancel()
        leaveTimeout = nil
        inChannel = false
        detachViews()
        let pending = pendingLeaveResult
        pendingLeaveResult = nil
        guard let pending else { return }
        if let error { fail(pending, code: "native_error", message: error) }
        else { pending(nil) }
    }

    private func setMuted(_ arguments: Any?, result: @escaping FlutterResult) {
        guard requirePublisher(result) else { return }
        let muted = ((arguments as? [String: Any])?["muted"] as? Bool) ?? false
        if muted {
            let code = engine!.publishLocalAudioStream(false)
            complete(code, result: result, message: "ARTC failed to stop publishing audio")
        } else {
            withPermission(.audio, result: result) {
                let code = self.engine!.publishLocalAudioStream(true)
                self.complete(code, result: result, message: "ARTC failed to publish audio")
            }
        }
    }

    private func setVideoEnabled(_ arguments: Any?, result: @escaping FlutterResult) {
        guard requirePublisher(result) else { return }
        let enabled = ((arguments as? [String: Any])?["enabled"] as? Bool) ?? false
        if !enabled {
            let publish = engine!.publishLocalVideoStream(false)
            let capture = engine!.enableLocalVideo(false)
            complete(publish == 0 ? capture : publish, result: result, message: "ARTC failed to disable local video")
        } else {
            withPermission(.video, result: result) {
                let capture = self.engine!.enableLocalVideo(true)
                let publish = capture == 0 ? self.engine!.publishLocalVideoStream(true) : capture
                self.complete(publish, result: result, message: "ARTC failed to enable local video")
            }
        }
    }

    private func switchCamera(_ arguments: Any?, result: @escaping FlutterResult) {
        guard requirePublisher(result) else { return }
        guard engine!.isCameraOn() else {
            fail(result, code: "invalid_state", message: "Enable the camera before switching cameras.")
            return
        }
        let position = string(arguments as? [String: Any] ?? [:], "position")
        let current = engine!.getCurrentCameraDirection()
        if (position == "front" && current == .front) || (position == "back" && current == .back) {
            result(nil)
            return
        }
        let code = engine!.switchCamera()
        complete(code, result: result, message: "ARTC failed to switch cameras")
    }

    private func sendMessage(_ arguments: Any?, result: @escaping FlutterResult) {
        guard requirePublisher(result) else { return }
        let values = arguments as? [String: Any] ?? [:]
        let envelope: [String: String] = ["topic": string(values, "topic"), "message": string(values, "message")]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            fail(result, code: "invalid_argument", message: "ARTC message could not be encoded.")
            return
        }
        let message = AliRtcDataChannelMsg()
        message.type = .custom
        message.data = data
        let code = engine!.sendDataChannelMessage(message)
        complete(code, result: result, message: "ARTC failed to send the data message")
    }

    private func requirePublisher(_ result: @escaping FlutterResult) -> Bool {
        guard let engine, inChannel else {
            fail(result, code: "invalid_state", message: "ARTC controls require an active channel.")
            return false
        }
        if viewer {
            fail(result, code: "unsupported_feature", message: "ARTC viewer sessions cannot publish or send data.")
            return false
        }
        return true
    }

    private func withPermission(_ mediaType: AVMediaType, result: @escaping FlutterResult, action: @escaping () -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: mediaType)
        if status == .authorized { action(); return }
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                DispatchQueue.main.async {
                    if granted { action() }
                    else { self.fail(result, code: "permission_denied", message: "Camera or microphone permission was denied.") }
                }
            }
            return
        }
        fail(result, code: "permission_denied", message: "Camera or microphone permission was denied in Settings.")
    }

    private func complete(_ code: Int32, result: @escaping FlutterResult, message: String) {
        if code == 0 { result(nil) }
        else { fail(result, code: "native_error", message: "\(message) (\(code)).") }
    }

    private func disposeEngine() {
        iosScreenSink?.stop()
        iosScreenSink = nil
        disposed = true
        if let pendingJoinResult { fail(pendingJoinResult, code: "invalid_state", message: "ARTC engine was disposed during join.") }
        pendingJoinResult = nil
        leaveTimeout?.cancel()
        leaveTimeout = nil
        pendingLeaveResult?(nil)
        pendingLeaveResult = nil
        inChannel = false
        detachViews()
        if engine != nil { AliRtcEngine.destroy() }
        engine = nil
        localUserId = nil
        disposed = false
    }

    fileprivate func add(_ view: ArtcVideoPlatformView) {
        videoViews.append(view)
        view.attach(to: engine, inChannel: inChannel)
    }

    fileprivate func remove(_ view: ArtcVideoPlatformView) {
        videoViews.removeAll { $0 === view }
        view.detach(from: engine)
    }

    private func attachViews() { videoViews.forEach { $0.attach(to: engine, inChannel: inChannel) } }
    private func detachViews() { videoViews.forEach { $0.detach(from: engine) } }

    private func emit(_ values: [String: Any]) {
        DispatchQueue.main.async { self.eventSink?(values) }
    }

    private func string(_ values: [String: Any], _ key: String) -> String { values[key] as? String ?? "" }

    private func fail(_ result: @escaping FlutterResult, code: String, message: String) {
        result(FlutterError(code: code, message: message, details: nil))
    }
}

extension FlutterRealtimeMediaArtcPlugin: AliRtcEngineDelegate {
    public func onJoinChannelResult(_ result: Int, channel: String, userId: String, elapsed: Int) {
        DispatchQueue.main.async {
            let pending = self.pendingJoinResult
            self.pendingJoinResult = nil
            if result == 0 {
                self.inChannel = true
                self.attachViews()
                pending?(nil)
            } else {
                self.inChannel = false
                self.emit(["type": "error", "code": result, "message": "ARTC failed to join channel."])
                pending?(FlutterError(code: "native_error", message: "ARTC failed to join channel (\(result)).", details: nil))
            }
        }
    }

    public func onRemoteUserOnLineNotify(_ uid: String, elapsed: Int) {
        emit(["type": "participantJoined", "userId": uid])
    }

    public func onRemoteUserOffLineNotify(_ uid: String, offlineReason: AliRtcUserOfflineReason) {
        emit(["type": "participantLeft", "userId": uid])
    }

    public func onRemoteTrackAvailableNotify(_ uid: String, audioTrack: AliRtcAudioTrack, videoTrack: AliRtcVideoTrack) {
        emit(["type": "audioChanged", "userId": uid, "available": audioTrack != .no])
        emit(["type": "videoChanged", "userId": uid, "available": (videoTrack.rawValue & 1) != 0])
        emit(["type": "screenChanged", "userId": uid, "available": (videoTrack.rawValue & 2) != 0])
    }

    public func onDataChannelMessage(_ uid: String, controlMsg: AliRtcDataChannelMsg) {
        let data = String(data: controlMsg.data, encoding: .utf8) ?? ""
        emit(["type": "message", "userId": uid, "data": data])
    }

    public func onAuthInfoWillExpire() { emit(["type": "authWillExpire"]) }
    public func onAuthInfoExpired() { emit(["type": "authWillExpire"]) }

    public func onConnectionStatusChange(_ status: AliRtcConnectionStatus, reason: AliRtcConnectionStatusChangeReason) {
        if status == .reconnecting || status == .disconnected { emit(["type": "reconnecting"]) }
        else if status == .connected { emit(["type": "recovered"]) }
    }

    public func onOccurError(_ error: Int, message: String) {
        emit(["type": "error", "code": error, "message": message])
    }

    public func onLeaveChannelResult(_ result: Int, stats: AliRtcStats) {
        DispatchQueue.main.async {
            self.finishLeave(error: result == 0 ? nil : "ARTC leave completed with error \(result).")
        }
    }
}

private final class ArtcVideoPlatformView: NSObject, FlutterPlatformView {
    private let containerView = UIView()
    private let userId: String
    private let isLocal: Bool
    private let isScreen: Bool
    /// 0 = cover/crop, 1 = contain/letterbox.
    private let fitMode: Int
    private weak var plugin: FlutterRealtimeMediaArtcPlugin?
    private var boundEngine: AliRtcEngine?

    init(
        frame: CGRect,
        userId: String,
        isLocal: Bool,
        isScreen: Bool,
        fitMode: Int,
        plugin: FlutterRealtimeMediaArtcPlugin
    ) {
        self.userId = userId
        self.isLocal = isLocal
        self.isScreen = isScreen
        self.fitMode = fitMode
        self.plugin = plugin
        super.init()
        containerView.frame = frame
        containerView.backgroundColor = .black
        plugin.add(self)
    }

    func view() -> UIView { containerView }

    func attach(to engine: AliRtcEngine?, inChannel: Bool) {
        detach(from: boundEngine)
        guard let engine, inChannel else { return }
        boundEngine = engine
        let canvas = AliVideoCanvas()
        canvas.view = containerView
        canvas.renderMode = fitMode == 1 ? .fill : .crop
        let source: AliRtcVideoTrack = isScreen ? .screen : .camera
        if isLocal {
            _ = engine.setLocalViewConfig(canvas, for: source)
            if engine.isCameraOn() { _ = engine.startPreview() }
        } else { _ = engine.setRemoteViewConfig(canvas, uid: userId, for: source) }
    }

    func detach(from engine: AliRtcEngine?) {
        guard let target = boundEngine ?? engine else { return }
        let source: AliRtcVideoTrack = isScreen ? .screen : .camera
        if isLocal { _ = target.setLocalViewConfig(nil, for: source) }
        else { _ = target.setRemoteViewConfig(nil, uid: userId, for: source) }
        boundEngine = nil
    }

    deinit { plugin?.remove(self) }
}

private final class ArtcVideoPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
    private weak var plugin: FlutterRealtimeMediaArtcPlugin?
    init(plugin: FlutterRealtimeMediaArtcPlugin) { self.plugin = plugin }
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        let values = args as? [String: Any] ?? [:]
        return ArtcVideoPlatformView(
            frame: frame,
            userId: values["userId"] as? String ?? "",
            isLocal: values["isLocal"] as? Bool ?? false,
            isScreen: values["isScreenShare"] as? Bool ?? false,
            fitMode: values["fitMode"] as? Int ?? 0,
            plugin: plugin!
        )
    }
}
