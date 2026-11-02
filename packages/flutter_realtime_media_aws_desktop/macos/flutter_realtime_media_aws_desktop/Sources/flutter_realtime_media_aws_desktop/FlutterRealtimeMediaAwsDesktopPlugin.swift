import AppKit
import AVFoundation
import FlutterMacOS
import WebKit

public final class FlutterRealtimeMediaAwsDesktopPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let runtime = AwsDesktopRuntime(registrar: registrar)

    let chime = FlutterMethodChannel(
      name: "com.oneplusdream.aws.chime.methodChannel",
      binaryMessenger: registrar.messenger
    )
    runtime.chimeChannel = chime
    let chimeHandler = AwsDesktopMethodHandler(runtime: runtime, provider: .chime)
    registrar.addMethodCallDelegate(chimeHandler, channel: chime)

    let ivsMethods = FlutterMethodChannel(
      name: "com.oneplusdream.flutter_realtime_media_ivs/methods",
      binaryMessenger: registrar.messenger
    )
    let ivsHandler = AwsDesktopMethodHandler(runtime: runtime, provider: .ivs)
    registrar.addMethodCallDelegate(ivsHandler, channel: ivsMethods)
    let ivsEvents = FlutterEventChannel(
      name: "com.oneplusdream.flutter_realtime_media_ivs/events",
      binaryMessenger: registrar.messenger
    )
    ivsEvents.setStreamHandler(runtime)

    let ivsChatMethods = FlutterMethodChannel(
      name: "com.oneplusdream.flutter_realtime_chat_ivs/methods",
      binaryMessenger: registrar.messenger
    )
    runtime.ivsChatChannel = ivsChatMethods
    let ivsChatHandler = AwsDesktopIvsChatMethodHandler(runtime: runtime)
    registrar.addMethodCallDelegate(ivsChatHandler, channel: ivsChatMethods)
    let ivsChatEvents = FlutterEventChannel(
      name: "com.oneplusdream.flutter_realtime_chat_ivs/events",
      binaryMessenger: registrar.messenger
    )
    let ivsChatStreamHandler = AwsDesktopIvsChatStreamHandler(runtime: runtime)
    ivsChatEvents.setStreamHandler(ivsChatStreamHandler)

    registrar.register(
      AwsDesktopVideoViewFactory(runtime: runtime, provider: .chime),
      withId: "videoTile"
    )
    registrar.register(
      AwsDesktopVideoViewFactory(runtime: runtime, provider: .ivs),
      withId: "com.oneplusdream.flutter_realtime_media_ivs/video"
    )

    runtime.retain(chimeHandler)
    runtime.retain(ivsHandler)
    runtime.retain(ivsChatHandler)
    runtime.retain(ivsChatStreamHandler)
  }
}

private enum AwsDesktopProvider: String {
  case chime
  case ivs

  var sessionId: String { "aws-desktop-" + rawValue }
}

private final class AwsDesktopMethodHandler: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    // Registered by FlutterRealtimeMediaAwsDesktopPlugin so both AWS engines
    // can share one WebKit runtime.
  }

  let runtime: AwsDesktopRuntime
  let provider: AwsDesktopProvider

  init(runtime: AwsDesktopRuntime, provider: AwsDesktopProvider) {
    self.runtime = runtime
    self.provider = provider
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch provider {
    case .chime:
      runtime.handleChime(call, result: result)
    case .ivs:
      runtime.handleIvs(call, result: result)
    }
  }
}

private final class AwsDesktopIvsChatMethodHandler: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    // Registered by FlutterRealtimeMediaAwsDesktopPlugin to share its WebKit runtime.
  }

  let runtime: AwsDesktopRuntime

  init(runtime: AwsDesktopRuntime) {
    self.runtime = runtime
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    runtime.handleIvsChat(call, result: result)
  }
}

private final class AwsDesktopIvsChatStreamHandler: NSObject, FlutterStreamHandler {
  let runtime: AwsDesktopRuntime

  init(runtime: AwsDesktopRuntime) {
    self.runtime = runtime
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    runtime.ivsChatSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    runtime.ivsChatSink = nil
    return nil
  }
}

private final class AwsDesktopRuntime: NSObject,
  FlutterStreamHandler, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate
{
  let registrar: FlutterPluginRegistrar
  var chimeChannel: FlutterMethodChannel?
  var ivsChatChannel: FlutterMethodChannel?
  var ivsSink: FlutterEventSink?
  var ivsChatSink: FlutterEventSink?
  var webView: WKWebView?

  private var bridgeReady = false
  private var loadingStarted = false
  private var readyTimeout: DispatchWorkItem?
  private var readyWaiters: [(Error?) -> Void] = []
  private var retainedHandlers: [AnyObject] = []
  private var ivsChatSessionId: String?
  private var loadedPackageScripts: Set<String> = []
  private var loadingPackageScripts: Set<String> = []
  private var packageScriptWaiters: [String: [(Error?) -> Void]] = [:]
  private var snapshots: [AwsDesktopProvider: [String: Any]] = [:]
  private var payloads: [AwsDesktopProvider: [String: Any]] = [:]
  private var chimeDevices: [[String: Any]] = []
  private let processedFrameHandler = AwsProcessedFrameSchemeHandler()
  private var processedFeeds: [AwsDesktopProvider: AwsProcessedFrameFeed] = [:]
  private var processedFeedPool: [String: AwsProcessedFrameFeed] = [:]
  private var pendingProcessedFrames: [String: Int64] = [:]
  private var notifyingProcessedFrames: Set<String> = []
  private var processedFeedReferenceCounts: [String: Int] = [:]
  private var processedAttachGenerations: [AwsDesktopProvider: Int] = [:]
  private var reportedProcessedFailures: Set<String> = []
  private let views = NSMapTable<NSString, AwsDesktopVideoView>(
    keyOptions: .strongMemory,
    valueOptions: .weakMemory
  )

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  func retain(_ handler: AnyObject) {
    retainedHandlers.append(handler)
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    ivsSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    ivsSink = nil
    return nil
  }

  func handleChime(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "probeProcessedVideoInput":
      probeProcessedVideoInput(result: result)
    case "attachProcessedVideoSource":
      attachProcessedVideo(.chime, arguments: arguments, result: result)
    case "detachProcessedVideoSource":
      detachProcessedVideo(.chime) { error in
        error == nil ? result(nil) : result(self.flutterError(error!))
      }
    case "manageAudioPermissions":
      requestPermission(.audio) { granted in
        granted ? self.chimeSuccess(result) : self.chimeFailure(
          result, code: "permission_denied", message: "Microphone permission was denied."
        )
      }
    case "manageVideoPermissions":
      requestPermission(.video) { granted in
        granted ? self.chimeSuccess(result) : self.chimeFailure(
          result, code: "permission_denied", message: "Camera permission was denied."
        )
      }
    case "join":
      guard let payload = chimePayload(arguments) else {
        chimeFailure(result, code: "invalid_join_info", message: "Chime join information is incomplete.")
        return
      }
      payloads[.chime] = payload
      createAndJoin(.chime, payload: payload) { error in
        error == nil
          ? self.chimeSuccess(result)
          : self.chimeFailure(result, code: "native_error", message: error!)
      }
    case "stop":
      leaveAndDispose(.chime) { error in
        error == nil
          ? self.chimeSuccess(result)
          : self.chimeFailure(result, code: "native_error", message: error!)
      }
    case "mute":
      command(.chime, name: "setMuted", args: ["muted": true]) { _, error in
        error == nil ? self.chimeSuccess(result) : self.chimeFailure(result, code: "native_error", message: error!)
      }
    case "unmute":
      command(.chime, name: "setMuted", args: ["muted": false]) { _, error in
        error == nil ? self.chimeSuccess(result) : self.chimeFailure(result, code: "native_error", message: error!)
      }
    case "startLocalVideo":
      command(.chime, name: "setVideoEnabled", args: ["enabled": true]) { _, error in
        error == nil ? self.chimeSuccess(result) : self.chimeFailure(result, code: "native_error", message: error!)
      }
    case "stopLocalVideo":
      command(.chime, name: "setVideoEnabled", args: ["enabled": false]) { _, error in
        error == nil ? self.chimeSuccess(result) : self.chimeFailure(result, code: "native_error", message: error!)
      }
    case "setCameraPosition":
      chimeFailure(
        result,
        code: "method_not_implemented",
        message: "Chime macOS does not expose mobile front/back camera switching."
      )
    case "listAudioDevices":
      command(.chime, name: "listDevices", args: [:]) { value, error in
        guard error == nil else {
          self.chimeFailure(result, code: "native_error", message: error!)
          return
        }
        let devices = self.decodeArray(value)
        self.chimeDevices = devices
        let labels = devices
          .filter { ($0["kind"] as? String) == "audioOutput" }
          .compactMap { $0["label"] as? String }
        self.chimeSuccess(result, data: labels)
      }
    case "initialAudioSelection":
      let label = chimeDevices.first(where: {
        ($0["kind"] as? String) == "audioOutput"
      })?["label"] as? String
      chimeSuccess(result, data: label)
    case "updateAudioDevice":
      let label = call.arguments as? String ?? ""
      guard let device = chimeDevices.first(where: {
        ($0["kind"] as? String) == "audioOutput" &&
          ($0["label"] as? String) == label
      }) else {
        chimeFailure(result, code: "invalid_argument", message: "Unknown Chime audio output device.")
        return
      }
      command(.chime, name: "selectAudioOutput", args: device) { _, error in
        error == nil ? self.chimeSuccess(result) : self.chimeFailure(result, code: "native_error", message: error!)
      }
    case "sendMessage":
      command(.chime, name: "sendMessage", args: arguments) { _, error in
        error == nil ? self.chimeSuccess(result) : self.chimeFailure(result, code: "native_error", message: error!)
      }
    default:
      chimeFailure(
        result,
        code: "method_not_implemented",
        message: "Chime macOS does not implement " + call.method + "."
      )
    }
  }

  func handleIvs(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "probeProcessedVideoInput":
      probeProcessedVideoInput(result: result)
    case "attachProcessedVideoSource":
      attachProcessedVideo(.ivs, arguments: arguments, result: result)
    case "detachProcessedVideoSource":
      detachProcessedVideo(.ivs) { error in
        error == nil ? result(nil) : result(self.flutterError(error!))
      }
    case "probeDevices":
      result([
        "microphones": AVCaptureDevice.default(for: .audio) == nil ? 0 : 1,
        "cameras": AVCaptureDevice.default(for: .video) == nil ? 0 : 1,
      ])
    case "join":
      let payload = ivsPayload(arguments)
      payloads[.ivs] = payload
      createAndJoin(.ivs, payload: payload) { error in
        error == nil ? result(nil) : result(self.flutterError(error!))
      }
    case "exchangeToken":
      guard var payload = payloads[.ivs],
        var ivs = payload["ivs"] as? [String: Any],
        let token = arguments["token"] as? String,
        !token.isEmpty
      else {
        result(FlutterError(code: "invalid_join_info", message: "Missing refreshed IVS token.", details: nil))
        return
      }
      ivs["token"] = token
      payload["ivs"] = ivs
      payloads[.ivs] = payload
      leaveAndDispose(.ivs) { _ in
        self.createAndJoin(.ivs, payload: payload) { error in
          error == nil ? result(nil) : result(self.flutterError(error!))
        }
      }
    case "leave":
      leaveAndDispose(.ivs) { error in
        error == nil ? result(nil) : result(self.flutterError(error!))
      }
    case "setMuted":
      command(.ivs, name: "setMuted", args: arguments) { _, error in
        error == nil ? result(nil) : result(self.flutterError(error!))
      }
    case "setVideoEnabled":
      command(.ivs, name: "setVideoEnabled", args: arguments) { _, error in
        error == nil ? result(nil) : result(self.flutterError(error!))
      }
    case "switchCamera":
      result(FlutterError(
        code: "unsupported_feature",
        message: "IVS macOS uses desktop camera selection instead of front/back switching.",
        details: nil
      ))
    case "requestStats":
      result(nil)
    case "dispose":
      leaveAndDispose(.ivs) { _ in result(nil) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func handleIvsChat(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "connect":
      guard ivsChatSessionId == nil else {
        result(FlutterError(
          code: "invalid_state",
          message: "An Amazon IVS Chat room is already active.",
          details: nil
        ))
        return
      }
      guard
        let region = nonEmptyString(arguments["region"]),
        let token = nonEmptyString(arguments["token"]),
        let tokenExpirationTimeMs = positiveInteger(arguments["tokenExpirationTimeMs"]),
        let sessionExpirationTimeMs = positiveInteger(arguments["sessionExpirationTimeMs"])
      else {
        result(FlutterError(
          code: "invalid_argument",
          message: "Valid Amazon IVS Chat credentials are required.",
          details: nil
        ))
        return
      }

      let sessionId = "aws-desktop-ivs-chat-" + UUID().uuidString
      ivsChatSessionId = sessionId
      let chatPayload: [String: Any] = [
        "chat": [
          "region": region,
          "token": token,
          "tokenExpirationTimeMs": tokenExpirationTimeMs,
          "sessionExpirationTimeMs": sessionExpirationTimeMs,
        ],
      ]
      invokeIvsChat("create", sessionId: sessionId, payload: chatPayload) { error in
        if let error {
          self.ivsChatSessionId = nil
          result(self.ivsChatError(error, operation: "create"))
          return
        }
        self.invokeIvsChat("connect", sessionId: sessionId, payload: [:]) { error in
          guard let error else {
            result(nil)
            return
          }
          self.invokeIvsChat("dispose", sessionId: sessionId, payload: [:]) { _ in
            self.ivsChatSessionId = nil
            result(self.ivsChatError(error, operation: "connect"))
          }
        }
      }
    case "sendMessage":
      runIvsChatCommand(
        "sendMessage",
        arguments: ["message": arguments["message"] ?? ""],
        result: result
      )
    case "deleteMessage":
      runIvsChatCommand(
        "deleteMessage",
        arguments: ["messageId": arguments["messageId"] ?? ""],
        result: result
      )
    case "disconnectUser":
      runIvsChatCommand(
        "disconnectUser",
        arguments: ["userId": arguments["userId"] ?? ""],
        result: result
      )
    case "disconnect":
      guard let sessionId = ivsChatSessionId else {
        result(nil)
        return
      }
      runIvsChatCommand(
        "disconnect",
        arguments: [:],
        sessionId: sessionId,
        result: result
      )
    case "dispose":
      guard let sessionId = ivsChatSessionId else {
        result(nil)
        return
      }
      invokeIvsChat("dispose", sessionId: sessionId, payload: [:]) { error in
        self.ivsChatSessionId = nil
        if let error {
          result(self.ivsChatError(error, operation: "dispose"))
        } else {
          result(nil)
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func runIvsChatCommand(
    _ name: String,
    arguments: [String: Any],
    sessionId: String? = nil,
    result: @escaping FlutterResult
  ) {
    guard let sessionId = sessionId ?? ivsChatSessionId else {
      result(FlutterError(
        code: "invalid_state",
        message: "No active Amazon IVS Chat room.",
        details: nil
      ))
      return
    }
    invokeIvsChat(
      "command",
      sessionId: sessionId,
      payload: ["name": name, "arguments": arguments]
    ) { error in
      if let error {
        result(self.ivsChatError(error, operation: name))
      } else {
        result(nil)
      }
    }
  }

  private func ivsChatError(_ message: String, operation: String) -> FlutterError {
    FlutterError(
      code: "native_error",
      message: "Amazon IVS Chat \(operation) failed: \(message)",
      details: ["operation": operation]
    )
  }

  private func nonEmptyString(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func positiveInteger(_ value: Any?) -> Int64? {
    let parsed: Int64?
    if let number = value as? NSNumber {
      parsed = number.int64Value
    } else if let text = value as? String {
      parsed = Int64(text)
    } else {
      parsed = nil
    }
    guard let parsed, parsed > 0 else { return nil }
    return parsed
  }

  private func chimePayload(_ value: [String: Any]) -> [String: Any]? {
    let required = [
      "MeetingId", "ExternalMeetingId", "MediaRegion", "AudioHostUrl",
      "AudioFallbackUrl", "SignalingUrl", "TurnControlUrl",
      "ExternalUserId", "AttendeeId", "JoinToken",
    ]
    guard required.allSatisfy({
      (value[$0] as? String)?.isEmpty == false
    }) else { return nil }
    return [
      "provider": "chime",
      "participantId": value["AttendeeId"]!,
      "displayName": value["ExternalUserId"]!,
      "role": "participant",
      "meeting": [
        "MeetingId": value["MeetingId"]!,
        "ExternalMeetingId": value["ExternalMeetingId"]!,
        "MediaRegion": value["MediaRegion"]!,
        "MediaPlacement": [
          "AudioHostUrl": value["AudioHostUrl"]!,
          "AudioFallbackUrl": value["AudioFallbackUrl"]!,
          "SignalingUrl": value["SignalingUrl"]!,
          "TurnControlUrl": value["TurnControlUrl"]!,
        ],
      ],
      "attendee": [
        "ExternalUserId": value["ExternalUserId"]!,
        "AttendeeId": value["AttendeeId"]!,
        "JoinToken": value["JoinToken"]!,
      ],
    ]
  }

  private func ivsPayload(_ value: [String: Any]) -> [String: Any] {
    var block: [String: Any] = [
      "token": value["token"] ?? "",
      "stageArn": value["stageArn"] ?? "",
      "tokenParticipantId": value["tokenParticipantId"] ?? value["userId"] ?? "",
      "capabilities": value["capabilities"] ?? [],
      "expiresAtMs": value["expiresAtMs"] ?? 0,
    ]
    if let region = value["region"] { block["region"] = region }
    return [
      "provider": "ivs",
      "participantId": value["userId"] ?? "",
      "displayName": value["displayName"] ?? "",
      "role": value["role"] ?? "viewer",
      "ivs": block,
    ]
  }

  private func createAndJoin(
    _ provider: AwsDesktopProvider,
    payload: [String: Any],
    completion: @escaping (String?) -> Void
  ) {
    invoke(provider, operation: "create", payload: payload) { _, error in
      if let error {
        completion(error)
        return
      }
      self.invoke(provider, operation: "join", payload: [:]) { _, error in
        completion(error)
      }
    }
  }

  private func leaveAndDispose(
    _ provider: AwsDesktopProvider,
    completion: @escaping (String?) -> Void
  ) {
    detachProcessedVideo(provider) { _ in
      self.invoke(provider, operation: "leave", payload: [:]) { _, _ in
        self.invoke(provider, operation: "dispose", payload: [:]) { _, error in
          self.snapshots.removeValue(forKey: provider)
          self.refreshViews(provider, snapshot: nil)
          completion(error)
        }
      }
    }
  }

  private func probeProcessedVideoInput(result: @escaping FlutterResult) {
    ensureReady { error in
      guard error == nil, let view = self.webView else { result(false); return }
      Task { @MainActor in
        let supported = try? await view.callAsyncJavaScript(
          "return await AwsDesktopRuntime.canConsumeProcessedVideo()",
          arguments: [:], in: nil, contentWorld: .page
        ) as? Bool
        result(supported ?? false)
      }
    }
  }

  private func attachProcessedVideo(
    _ provider: AwsDesktopProvider,
    arguments: [String: Any],
    result: @escaping FlutterResult
  ) {
    guard let sourceId = nonEmptyString(arguments["sourceId"]) else {
      result(FlutterError(code: "invalid_argument", message: "A processed source ID is required.", details: nil))
      return
    }
    guard let payload = payloads[provider], payload["role"] as? String != "viewer" else {
      result(FlutterError(code: "unsupported_feature", message: "Only joined publishers can attach processed video.", details: nil))
      return
    }
    let generation = nextProcessedAttachGeneration(for: provider)
    detachProcessedVideo(provider, generation: generation) { detachError in
      guard self.isCurrentProcessedAttach(provider, generation: generation) else {
        result(self.processedAttachCancelledError())
        return
      }
      if let detachError { result(self.flutterError(detachError)); return }
      let feed: AwsProcessedFrameFeed
      do { feed = try self.acquireProcessedFrameFeed(sourceId: sourceId) }
      catch { result(self.flutterError(error.localizedDescription)); return }
      self.ensureMediaProviderBridge(provider) { error in
        guard self.isCurrentProcessedAttach(provider, generation: generation) else {
          self.releaseProcessedFrameFeed(feed)
          result(self.processedAttachCancelledError())
          return
        }
        guard error == nil, let view = self.webView else {
          self.releaseProcessedFrameFeed(feed)
          result(self.flutterError(error?.localizedDescription ?? "AWS desktop runtime is unavailable."))
          return
        }
        Task { @MainActor in
          do {
            _ = try await view.callAsyncJavaScript(
              "return await AwsDesktopRuntime.attachProcessedVideo(providerId, sessionId, sourceId, generation)",
              arguments: [
                "providerId": provider.rawValue,
                "sessionId": provider.sessionId,
                "sourceId": sourceId,
                "generation": generation,
              ],
              in: nil, contentWorld: .page
            )
            guard self.isCurrentProcessedAttach(provider, generation: generation) else {
              self.releaseProcessedFrameFeed(feed)
              result(self.processedAttachCancelledError())
              return
            }
            if feed.isFailed {
              self.releaseProcessedFrameFeed(feed)
              result(self.flutterError(feed.errorMessage ?? "The native processed video feed failed."))
              return
            }
            self.processedFeeds[provider] = feed
            if let frame = feed.snapshot() {
              self.processedFrameFeedDidProduceFrame(feed, timestampNs: frame.timestampNs)
            }
            result(nil)
          } catch {
            self.releaseProcessedFrameFeed(feed)
            result(self.flutterError(Self.jsError(error, operation: "attach processed video")))
          }
        }
      }
    }
  }

  private func detachProcessedVideo(
    _ provider: AwsDesktopProvider,
    completion: @escaping (String?) -> Void
  ) {
    let generation = nextProcessedAttachGeneration(for: provider)
    detachProcessedVideo(provider, generation: generation, completion: completion)
  }

  private func detachProcessedVideo(
    _ provider: AwsDesktopProvider,
    generation: Int,
    completion: @escaping (String?) -> Void
  ) {
    let feed = processedFeeds.removeValue(forKey: provider)
    guard let view = webView, bridgeReady else {
      if let feed { releaseProcessedFrameFeed(feed) }
      completion(nil)
      return
    }
    Task { @MainActor in
      do {
        _ = try await view.callAsyncJavaScript(
          "return await AwsDesktopRuntime.detachProcessedVideo(providerId, sessionId, sourceId, generation)",
          arguments: [
            "providerId": provider.rawValue,
            "sessionId": provider.sessionId,
            "sourceId": feed.map { $0.sourceId as Any } ?? NSNull(),
            "generation": generation,
          ],
          in: nil, contentWorld: .page
        )
        if let feed { releaseProcessedFrameFeed(feed) }
        completion(nil)
      } catch {
        if let feed { releaseProcessedFrameFeed(feed) }
        completion(Self.jsError(error, operation: "detach processed video"))
      }
    }
  }

  private func nextProcessedAttachGeneration(for provider: AwsDesktopProvider) -> Int {
    let generation = (processedAttachGenerations[provider] ?? 0) + 1
    processedAttachGenerations[provider] = generation
    return generation
  }

  private func isCurrentProcessedAttach(_ provider: AwsDesktopProvider, generation: Int) -> Bool {
    processedAttachGenerations[provider] == generation
  }

  private func processedAttachCancelledError() -> FlutterError {
    FlutterError(
      code: "attach_cancelled",
      message: "Processed video attachment was cancelled by a newer attach or leave operation.",
      details: nil
    )
  }

  private func acquireProcessedFrameFeed(sourceId: String) throws -> AwsProcessedFrameFeed {
    let key = sourceId.lowercased()
    if let feed = processedFeedPool[key] {
      guard !feed.isFailed else {
        throw NSError(
          domain: "flutter_realtime_aws.processed_frame",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: feed.errorMessage ?? "The processed video source has failed."]
        )
      }
      processedFeedReferenceCounts[key, default: 0] += 1
      return feed
    }

    let feed = try AwsProcessedFrameFeed(sourceId: sourceId)
    reportedProcessedFailures.remove(key)
    feed.onError = { [weak self, weak feed] message in
      guard let self, let feed else { return }
      self.processedFrameFeedDidFail(feed, message: message)
    }
    feed.onFrameAvailable = { [weak self, weak feed] timestamp in
      guard let self, let feed else { return }
      self.processedFrameFeedDidProduceFrame(feed, timestampNs: timestamp)
    }
    processedFeedPool[key] = feed
    processedFeedReferenceCounts[key] = 1
    processedFrameHandler.add(feed)
    if feed.isFailed, let message = feed.errorMessage {
      processedFrameFeedDidFail(feed, message: message)
    }
    return feed
  }

  private func releaseProcessedFrameFeed(_ feed: AwsProcessedFrameFeed) {
    let key = feed.sourceId.lowercased()
    guard processedFeedPool[key] === feed else { return }
    let references = max(0, (processedFeedReferenceCounts[key] ?? 1) - 1)
    guard references == 0 else {
      processedFeedReferenceCounts[key] = references
      return
    }
    processedFeedReferenceCounts.removeValue(forKey: key)
    processedFeedPool.removeValue(forKey: key)
    pendingProcessedFrames.removeValue(forKey: key)
    notifyingProcessedFrames.remove(key)
    processedFrameHandler.remove(feed)
    feed.dispose()
  }

  // Keep at most one WebKit notification in flight per shared source. If encoding
  // outpaces WebKit, overwrite the pending timestamp instead of queuing old frames.
  private func processedFrameFeedDidProduceFrame(_ feed: AwsProcessedFrameFeed, timestampNs: Int64) {
    let key = feed.sourceId.lowercased()
    guard processedFeedPool[key] === feed, !feed.isFailed, bridgeReady, let webView else { return }
    pendingProcessedFrames[key] = timestampNs
    guard notifyingProcessedFrames.insert(key).inserted else { return }
    Task { @MainActor in
      while self.processedFeedPool[key] === feed,
            let timestamp = self.pendingProcessedFrames.removeValue(forKey: key) {
        do {
          _ = try await webView.callAsyncJavaScript(
            "AwsDesktopRuntime.notifyProcessedFrame(sourceId, timestampNs)",
            arguments: ["sourceId": feed.sourceId, "timestampNs": String(timestamp)],
            in: nil, contentWorld: .page
          )
        } catch {
          if self.processedFeedPool[key] === feed {
            self.pendingProcessedFrames.removeValue(forKey: key)
            self.reportProcessedVideoSourceError(sourceId: feed.sourceId,
              message: Self.jsError(error, operation: "notify processed video frame"))
          }
          break
        }
      }
      if self.processedFeedPool[key] === feed { self.notifyingProcessedFrames.remove(key) }
    }
  }

  private func processedFrameFeedDidFail(_ feed: AwsProcessedFrameFeed, message: String) {
    guard processedFeedPool[feed.sourceId.lowercased()] === feed else { return }
    reportProcessedVideoSourceError(sourceId: feed.sourceId, message: message)
  }

  private func reportProcessedVideoSourceError(sourceId: String, message: String) {
    let key = sourceId.lowercased()
    guard reportedProcessedFailures.insert(key).inserted else { return }
    let effects = FlutterMethodChannel(
      name: "flutter_realtime_video_effects",
      binaryMessenger: registrar.messenger
    )
    effects.invokeMethod("sourceError", arguments: ["sourceId": sourceId, "message": message])
    for (provider, feed) in processedFeeds where feed.sourceId.lowercased() == key {
      command(provider, name: "setVideoEnabled", args: ["enabled": false]) { _, _ in }
    }
    guard let webView, bridgeReady else { return }
    Task { @MainActor in
      _ = try? await webView.callAsyncJavaScript(
        "AwsDesktopRuntime.failProcessedVideo(sourceId, message)",
        arguments: ["sourceId": sourceId, "message": message],
        in: nil,
        contentWorld: .page
      )
    }
  }

  private func command(
    _ provider: AwsDesktopProvider,
    name: String,
    args: [String: Any],
    completion: @escaping (Any?, String?) -> Void
  ) {
    invoke(
      provider,
      operation: "command",
      payload: ["name": name, "args": args],
      completion: completion
    )
  }

  private func invoke(
    _ provider: AwsDesktopProvider,
    operation: String,
    payload: [String: Any],
    completion: @escaping (Any?, String?) -> Void
  ) {
    ensureMediaProviderBridge(provider) { error in
      if let error {
        completion(nil, error.localizedDescription)
        return
      }
      guard let webView = self.webView else {
        completion(nil, "AWS desktop WebKit runtime is unavailable.")
        return
      }
      Task { @MainActor in
        do {
          let value = try await webView.callAsyncJavaScript(
            "return await AwsDesktopRuntime.invoke(providerId, sessionId, operation, payload)",
            arguments: [
              "providerId": provider.rawValue,
              "sessionId": provider.sessionId,
              "operation": operation,
              "payload": payload,
            ],
            in: nil,
            contentWorld: .page
          )
          completion(value, nil)
        } catch {
          completion(nil, Self.jsError(error, operation: operation))
        }
      }
    }
  }

  private func invokeIvsChat(
    _ operation: String,
    sessionId: String,
    payload: [String: Any],
    completion: @escaping (String?) -> Void
  ) {
    ensureIvsChatBridge { error in
      if let error {
        completion(error.localizedDescription)
        return
      }
      guard let webView = self.webView else {
        completion("AWS desktop WebKit runtime is unavailable.")
        return
      }
      Task { @MainActor in
        do {
          _ = try await webView.callAsyncJavaScript(
            "return await AwsDesktopChatRuntime.invoke(operation, sessionId, payload)",
            arguments: [
              "operation": operation,
              "sessionId": sessionId,
              "payload": payload,
            ],
            in: nil,
            contentWorld: .page
          )
          completion(nil)
        } catch {
          completion(Self.jsError(error, operation: "IVS Chat " + operation))
        }
      }
    }
  }

  private func ensureIvsChatBridge(completion: @escaping (Error?) -> Void) {
    ensurePackageScript(
      "assets/ivs-chat-provider.js",
      fromPackage: "flutter_realtime_provider_ivs_chat",
      expectedGlobal: "IvsChatMessagingBridge",
      completion: completion
    )
  }

  private func ensureMediaProviderBridge(
    _ provider: AwsDesktopProvider,
    completion: @escaping (Error?) -> Void
  ) {
    let vendorAsset: String
    switch provider {
    case .chime:
      vendorAsset = "assets/chime-sdk.js"
    case .ivs:
      vendorAsset = "assets/amazon-ivs-web-broadcast.js"
    }
    ensurePackageScript(vendorAsset, fromPackage: "flutter_realtime_provider_aws") { error in
      if let error {
        completion(error)
        return
      }
      self.ensurePackageScript(
        "assets/media-provider-bridge.js",
        fromPackage: "flutter_realtime_media_web",
        expectedGlobal: "MediaProviderBridge",
        completion: completion
      )
    }
  }

  private func ensurePackageScript(
    _ asset: String,
    fromPackage package: String,
    expectedGlobal: String? = nil,
    completion: @escaping (Error?) -> Void
  ) {
    // Cache by both package and asset: provider packages can contain files
    // with identical relative paths after the SDK was split into modules.
    let scriptKey = "\(package)/\(asset)"
    ensureReady { error in
      if let error {
        completion(error)
        return
      }
      if self.loadedPackageScripts.contains(scriptKey) {
        completion(nil)
        return
      }
      self.packageScriptWaiters[scriptKey, default: []].append(completion)
      guard self.loadingPackageScripts.insert(scriptKey).inserted else { return }

      do {
        let source = try self.packageAssetText(asset, fromPackage: package)
        let encodedSource = Data(source.utf8).base64EncodedString()
        guard let webView = self.webView else {
          self.finishPackageScript(scriptKey, error: AwsDesktopError.runtimeInitialization(
            "AWS desktop WebKit runtime is unavailable while loading \(scriptKey)."
          ))
          return
        }
        Task { @MainActor in
          do {
            let loaded = try await webView.callAsyncJavaScript(
              """
                const binary = atob(encodedSource);
                const bytes = new Uint8Array(binary.length);
                for (let index = 0; index < binary.length; index += 1) {
                  bytes[index] = binary.charCodeAt(index);
                }
                const script = document.createElement('script');
                script.textContent = new TextDecoder().decode(bytes);
                (document.head || document.documentElement).appendChild(script);
                return expectedGlobal === '' ||
                  typeof globalThis[expectedGlobal] !== 'undefined';
                """,
              arguments: [
                "encodedSource": encodedSource,
                "expectedGlobal": expectedGlobal ?? "",
              ],
              in: nil,
              contentWorld: .page
            ) as? Bool ?? false
            self.finishPackageScript(
              scriptKey,
              error: loaded ? nil : AwsDesktopError.runtimeInitialization(
                "The bundled JavaScript bridge did not initialize: \(scriptKey)."
              )
            )
          } catch {
            self.finishPackageScript(scriptKey, error: error)
          }
        }
      } catch {
        self.finishPackageScript(scriptKey, error: error)
      }
    }
  }

  private func finishPackageScript(_ asset: String, error: Error?) {
    loadingPackageScripts.remove(asset)
    if error == nil { loadedPackageScripts.insert(asset) }
    let waiters = packageScriptWaiters.removeValue(forKey: asset) ?? []
    waiters.forEach { $0(error) }
  }

  private func requestIvsChatToken(_ requestId: String) {
    guard let ivsChatChannel else {
      resolveIvsChatToken(
        requestId,
        response: nil,
        errorMessage: "Amazon IVS Chat token refresh channel is unavailable."
      )
      return
    }
    ivsChatChannel.invokeMethod("requestToken", arguments: nil) { response in
      if let error = response as? FlutterError {
        self.resolveIvsChatToken(
          requestId,
          response: nil,
          errorMessage: error.message ?? "Unable to refresh Amazon IVS Chat credentials."
        )
        return
      }
      guard
        let credentials = response as? [String: Any],
        self.nonEmptyString(credentials["token"]) != nil,
        self.positiveInteger(credentials["tokenExpirationTimeMs"]) != nil,
        self.positiveInteger(credentials["sessionExpirationTimeMs"]) != nil
      else {
        self.resolveIvsChatToken(
          requestId,
          response: nil,
          errorMessage: "The IVS Chat token provider returned invalid credentials."
        )
        return
      }
      self.resolveIvsChatToken(requestId, response: credentials, errorMessage: nil)
    }
  }

  private func resolveIvsChatToken(
    _ requestId: String,
    response: [String: Any]?,
    errorMessage: String?
  ) {
    guard let webView else { return }
    Task { @MainActor in
      do {
        _ = try await webView.callAsyncJavaScript(
          "return AwsDesktopChatRuntime.resolveToken(requestId, response, errorMessage)",
          arguments: [
            "requestId": requestId,
            "response": response.map { $0 as Any } ?? NSNull(),
            "errorMessage": errorMessage ?? NSNull(),
          ],
          in: nil,
          contentWorld: .page
        )
      } catch {
        NSLog("Unable to return refreshed IVS Chat credentials to WebKit: %@", error.localizedDescription)
      }
    }
  }

  private func bind(
    provider: AwsDesktopProvider,
    trackId: String,
    viewKey: String
  ) {
    ensureMediaProviderBridge(provider) { _ in
      guard let webView = self.webView else { return }
      Task { @MainActor in
        _ = try? await webView.callAsyncJavaScript(
          "return await AwsDesktopRuntime.bindTrack(providerId, sessionId, trackId, viewKey)",
          arguments: [
            "providerId": provider.rawValue,
            "sessionId": provider.sessionId,
            "trackId": trackId,
            "viewKey": viewKey,
          ],
          in: nil,
          contentWorld: .page
        )
      }
    }
  }

  private func unbind(viewKey: String) {
    guard let webView else { return }
    Task { @MainActor in
      _ = try? await webView.callAsyncJavaScript(
        "AwsDesktopRuntime.unbindTrack(viewKey)",
        arguments: ["viewKey": viewKey],
        in: nil,
        contentWorld: .page
      )
    }
  }

  private func ensureReady(completion: @escaping (Error?) -> Void) {
    if bridgeReady {
      completion(nil)
      return
    }
    readyWaiters.append(completion)
    guard !loadingStarted else { return }
    loadingStarted = true

    do {
      let configuration = WKWebViewConfiguration()
      let controller = WKUserContentController()
      controller.add(WeakScriptMessageHandler(target: self), name: "awsDesktop")
      configuration.userContentController = controller
      configuration.setURLSchemeHandler(processedFrameHandler, forURLScheme: "realtime-video")
      configuration.mediaTypesRequiringUserActionForPlayback = []
      let view = WKWebView(
        frame: NSRect(x: -2, y: -2, width: 1, height: 1),
        configuration: configuration
      )
      view.navigationDelegate = self
      view.uiDelegate = self
      view.alphaValue = 0.01
      registrar.view?.addSubview(view)
      webView = view
      view.loadHTMLString(try runtimeHTML(), baseURL: Bundle.main.bundleURL)
      let timeout = DispatchWorkItem { [weak self] in
        guard let self, !self.bridgeReady else { return }
        self.finishReady(AwsDesktopError.runtimeInitialization(
          "Timed out while loading the AWS desktop JavaScript runtime."
        ))
      }
      readyTimeout = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    } catch {
      finishReady(error)
    }
  }

  private func runtimeHTML() throws -> String {
    let runtime = try ownResourceText("aws_desktop_runtime", extension: "js")
    func dataScript(_ value: String) -> String {
      let encoded = Data(value.utf8).base64EncodedString()
      return "<script src=\"data:text/javascript;base64," + encoded + "\"></script>"
    }
    return """
      <!doctype html><html><head><meta charset="utf-8"></head><body>
      \(dataScript(runtime))
      </body></html>
      """
  }

  private func packageAssetText(_ asset: String, fromPackage package: String) throws -> String {
    let key = registrar.lookupKey(
      forAsset: asset,
      fromPackage: package
    )
    let mainBundleURL = Bundle.main.bundleURL
    let appBundleURL = mainBundleURL.lastPathComponent == "Contents"
      ? mainBundleURL.deletingLastPathComponent()
      : mainBundleURL
    let candidates: [URL?] = [
      // Flutter's macOS lookup key already includes the path to
      // App.framework/Resources/flutter_assets from the .app bundle root.
      URL(fileURLWithPath: key, relativeTo: appBundleURL).standardizedFileURL,
    ]
    guard let url = candidates.compactMap({ $0 }).first(where: {
      FileManager.default.fileExists(atPath: $0.path)
    }) else {
      throw AwsDesktopError.assetMissing("\(package)/\(asset)")
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  private func ownResourceText(_ name: String, extension ext: String) throws -> String {
#if SWIFT_PACKAGE
    guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
      throw AwsDesktopError.assetMissing(name + "." + ext)
    }
    return try String(contentsOf: url, encoding: .utf8)
#else
    guard
      let bundleURL = Bundle.main.url(
        forResource: "flutter_realtime_media_aws_desktop_assets",
        withExtension: "bundle"
      ),
      let bundle = Bundle(url: bundleURL),
      let url = bundle.url(forResource: name, withExtension: ext)
    else {
      throw AwsDesktopError.assetMissing(name + "." + ext)
    }
    return try String(contentsOf: url, encoding: .utf8)
#endif
  }

  private func finishReady(_ error: Error?) {
    readyTimeout?.cancel()
    readyTimeout = nil
    if error == nil {
      bridgeReady = true
    } else {
      bridgeReady = false
      loadingStarted = false
      webView?.removeFromSuperview()
      webView = nil
    }
    let waiters = readyWaiters
    readyWaiters.removeAll()
    waiters.forEach { $0(error) }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    webView.evaluateJavaScript(
      "typeof AwsDesktopRuntime !== 'undefined'"
    ) { value, error in
      if let error {
        self.finishReady(error)
      } else if (value as? Bool) == true {
        self.finishReady(nil)
      } else {
        self.finishReady(AwsDesktopError.runtimeInitialization(
          "AWS desktop JavaScript bridge did not initialize."
        ))
      }
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finishReady(error)
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    finishReady(error)
  }

  @available(macOS 12.0, *)
  func webView(
    _ webView: WKWebView,
    requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo,
    type: WKMediaCaptureType,
    decisionHandler: @escaping (WKPermissionDecision) -> Void
  ) {
    decisionHandler(.grant)
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any],
      let kind = body["kind"] as? String
    else { return }
    switch kind {
    case "ready":
      finishReady(nil)
    case "event":
      guard let sessionId = body["sessionId"] as? String,
        let event = body["event"] as? [String: Any]
      else { return }
      if sessionId == AwsDesktopProvider.chime.sessionId {
        handleChimeEvent(event)
      } else if sessionId == AwsDesktopProvider.ivs.sessionId {
        handleIvsEvent(event)
      }
    case "chatEvent":
      guard let sessionId = body["sessionId"] as? String,
        sessionId == ivsChatSessionId,
        let event = body["event"] as? [String: Any]
      else { return }
      DispatchQueue.main.async { self.ivsChatSink?(event) }
    case "chatTokenRequest":
      guard let requestId = body["requestId"] as? String,
        let sessionId = body["sessionId"] as? String,
        sessionId == ivsChatSessionId
      else { return }
      requestIvsChatToken(requestId)
    case "frame":
      guard let viewKey = body["viewKey"] as? String,
        let encoded = body["data"] as? String
      else { return }
      views.object(forKey: viewKey as NSString)?.updateFrame(encoded)
    case "processedVideoError":
      guard let sourceId = body["sourceId"] as? String else { return }
      let errorMessage = body["message"] as? String ?? "Native processed video input failed."
      reportProcessedVideoSourceError(sourceId: sourceId, message: errorMessage)
    default:
      break
    }
  }

  deinit {
    readyTimeout?.cancel()
    processedFeedPool.values.forEach { $0.dispose() }
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "awsDesktop")
    webView?.removeFromSuperview()
  }

  private func handleChimeEvent(_ event: [String: Any]) {
    switch event["type"] as? String {
    case "state":
      let state = event["state"] as? String ?? ""
      let type: String
      switch state {
      case "connecting": type = "audioSessionConnecting"
      case "connected": type = "audioSessionStarted"
      case "reconnecting": type = "audioSessionDropped"
      case "ended", "disconnected": type = "audioSessionStopped"
      default: return
      }
      chimeChannel?.invokeMethod("meetingEvent", arguments: ["type": type])
      if state == "ended" || state == "disconnected" {
        chimeChannel?.invokeMethod("audioSessionDidStop", arguments: nil)
      }
    case "snapshot":
      translateChimeSnapshot(event)
    case "message":
      if event["throttled"] as? Bool == true { return }
      chimeChannel?.invokeMethod("messageReceived", arguments: [
        "attendeeId": event["participantId"] ?? "",
        "externalUserId": event["displayName"] ?? "",
        "message": event["message"] ?? "",
        "topic": event["topic"] ?? "chat",
        "timestampMs": event["timestampMs"] ?? 0,
        "throttled": false,
      ])
    case "error":
      chimeChannel?.invokeMethod("meetingEvent", arguments: [
        "type": "audioSessionStopped",
        "statusCode": "native_error",
      ])
    default:
      break
    }
  }

  private func translateChimeSnapshot(_ next: [String: Any]) {
    let previous = snapshots[.chime] ?? [:]
    let oldParticipants = indexed(previous["participants"], key: "id")
    let newParticipants = indexed(next["participants"], key: "id")
    for (id, participant) in newParticipants where oldParticipants[id] == nil {
      chimeChannel?.invokeMethod("join", arguments: [
        "attendeeId": id,
        "externalUserId": participant["displayName"] ?? id,
      ])
    }
    for id in oldParticipants.keys where newParticipants[id] == nil {
      chimeChannel?.invokeMethod("leave", arguments: ["attendeeId": id])
    }
    for (id, participant) in newParticipants {
      let oldMuted = oldParticipants[id]?["isMuted"] as? Bool
      let muted = participant["isMuted"] as? Bool ?? false
      if oldMuted != muted {
        chimeChannel?.invokeMethod(
          muted ? "mute" : "unmute",
          arguments: ["attendeeId": id]
        )
      }
    }
    let oldTracks = indexed(previous["tracks"], key: "id")
    let newTracks = indexed(next["tracks"], key: "id")
    for (id, track) in newTracks where oldTracks[id] == nil {
      chimeChannel?.invokeMethod("videoTileAdd", arguments: chimeTile(track, id: id))
    }
    for (id, track) in oldTracks where newTracks[id] == nil {
      chimeChannel?.invokeMethod("videoTileRemove", arguments: chimeTile(track, id: id))
    }
    snapshots[.chime] = next
    refreshViews(.chime, snapshot: next)
  }

  private func chimeTile(_ track: [String: Any], id: String) -> [String: Any] {
    let tileId = Int(id.split(separator: ":").last ?? "0") ?? abs(id.hashValue)
    return [
      "tileId": tileId,
      "attendeeId": track["participantId"] ?? "",
      "videoStreamContentWidth": track["width"] ?? 0,
      "videoStreamContentHeight": track["height"] ?? 0,
      "isLocalTile": track["isLocal"] ?? false,
      "isContent": track["isScreenShare"] ?? false,
    ]
  }

  private func handleIvsEvent(_ event: [String: Any]) {
    switch event["type"] as? String {
    case "state":
      let state = event["state"] as? String ?? ""
      if state == "reconnecting" || state == "connecting" {
        ivsSink?(["type": "reconnecting"])
      } else if state == "connected" {
        ivsSink?(["type": "recovered"])
      }
    case "snapshot":
      translateIvsSnapshot(event)
    case "stats":
      ivsSink?(event)
    case "error":
      ivsSink?([
        "type": "error",
        "code": -1,
        "message": event["message"] ?? "Amazon IVS desktop runtime failed.",
      ])
    default:
      break
    }
  }

  private func translateIvsSnapshot(_ next: [String: Any]) {
    let previous = snapshots[.ivs] ?? [:]
    let oldParticipants = indexed(previous["participants"], key: "id")
    let newParticipants = indexed(next["participants"], key: "id")
    for (id, participant) in newParticipants where oldParticipants[id] == nil {
      ivsSink?([
        "type": "participantJoined",
        "userId": id,
        "displayName": participant["displayName"] ?? id,
      ])
      ivsSink?([
        "type": "audioChanged",
        "userId": id,
        "available": !((participant["isMuted"] as? Bool) ?? false),
      ])
      ivsSink?([
        "type": "videoChanged",
        "userId": id,
        "available": participant["videoTrackId"] != nil,
      ])
    }
    for id in oldParticipants.keys where newParticipants[id] == nil {
      ivsSink?(["type": "participantLeft", "userId": id])
    }
    for (id, participant) in newParticipants {
      guard let old = oldParticipants[id] else { continue }
      let oldVideo = old["videoTrackId"] != nil
      let video = participant["videoTrackId"] != nil
      if oldVideo != video {
        ivsSink?(["type": "videoChanged", "userId": id, "available": video])
      }
      let oldAudio = !((old["isMuted"] as? Bool) ?? false)
      let audio = !((participant["isMuted"] as? Bool) ?? false)
      if oldAudio != audio {
        ivsSink?(["type": "audioChanged", "userId": id, "available": audio])
      }
    }
    snapshots[.ivs] = next
    refreshViews(.ivs, snapshot: next)
  }

  private func indexed(_ raw: Any?, key: String) -> [String: [String: Any]] {
    guard let values = raw as? [[String: Any]] else { return [:] }
    return Dictionary(
      uniqueKeysWithValues: values.compactMap { value in
        guard let id = value[key] as? String, !id.isEmpty else { return nil }
        return (id, value)
      }
    )
  }

  func register(_ view: AwsDesktopVideoView) {
    views.setObject(view, forKey: view.viewKey as NSString)
    refreshView(view)
  }

  func unregister(_ view: AwsDesktopVideoView) {
    unbind(viewKey: view.viewKey)
    views.removeObject(forKey: view.viewKey as NSString)
  }

  private func refreshViews(_ provider: AwsDesktopProvider, snapshot: [String: Any]?) {
    let enumerator = views.objectEnumerator()
    while let view = enumerator?.nextObject() as? AwsDesktopVideoView {
      if view.provider == provider { refreshView(view) }
    }
  }

  private func refreshView(_ view: AwsDesktopVideoView) {
    guard let snapshot = snapshots[view.provider],
      let tracks = snapshot["tracks"] as? [[String: Any]]
    else { return }
    let trackId: String?
    switch view.provider {
    case .chime:
      trackId = view.fixedTrackId
    case .ivs:
      trackId = tracks.first(where: {
        ($0["participantId"] as? String) == view.participantId &&
          (($0["isLocal"] as? Bool) ?? false) == view.isLocal &&
          !(($0["isScreenShare"] as? Bool) ?? false)
      })?["id"] as? String
    }
    guard let trackId,
      tracks.contains(where: { ($0["id"] as? String) == trackId })
    else { return }
    if view.currentTrackId == trackId { return }
    if view.currentTrackId != nil { unbind(viewKey: view.viewKey) }
    view.currentTrackId = trackId
    bind(provider: view.provider, trackId: trackId, viewKey: view.viewKey)
  }

  private func requestPermission(
    _ type: AVMediaType,
    completion: @escaping (Bool) -> Void
  ) {
    switch AVCaptureDevice.authorizationStatus(for: type) {
    case .authorized:
      completion(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: type) { granted in
        DispatchQueue.main.async { completion(granted) }
      }
    default:
      completion(false)
    }
  }

  private func chimeSuccess(_ result: FlutterResult, data: Any? = nil) {
    result([
      "success": true,
      "code": NSNull(),
      "message": NSNull(),
      "data": data ?? NSNull(),
      "details": NSNull(),
    ])
  }

  private func chimeFailure(
    _ result: FlutterResult,
    code: String,
    message: String
  ) {
    result([
      "success": false,
      "code": code,
      "message": message,
      "data": NSNull(),
      "details": NSNull(),
    ])
  }

  private func decodeArray(_ value: Any?) -> [[String: Any]] {
    if let values = value as? [[String: Any]] { return values }
    if let text = value as? String,
      let data = text.data(using: .utf8),
      let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    {
      return values
    }
    return []
  }

  private func flutterError(_ message: String) -> FlutterError {
    FlutterError(code: "native_error", message: message, details: nil)
  }

  private static func jsError(_ error: Error, operation: String) -> String {
    let value = error as NSError
    let message =
      value.userInfo["WKJavaScriptExceptionMessage"] as? String ??
      value.localizedDescription
    return "AWS desktop " + operation + " failed: " + message
  }
}

private final class AwsDesktopVideoView: NSImageView {
  let viewKey: String
  let provider: AwsDesktopProvider
  let participantId: String
  let isLocal: Bool
  let fixedTrackId: String?
  weak var runtime: AwsDesktopRuntime?
  var currentTrackId: String?

  init(
    viewKey: String,
    provider: AwsDesktopProvider,
    participantId: String,
    isLocal: Bool,
    fixedTrackId: String?,
    runtime: AwsDesktopRuntime
  ) {
    self.viewKey = viewKey
    self.provider = provider
    self.participantId = participantId
    self.isLocal = isLocal
    self.fixedTrackId = fixedTrackId
    self.runtime = runtime
    super.init(frame: .zero)
    imageScaling = .scaleProportionallyUpOrDown
    imageAlignment = .alignCenter
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    runtime.register(self)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func updateFrame(_ dataURL: String) {
    guard let comma = dataURL.firstIndex(of: ","),
      let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
      let image = NSImage(data: data)
    else { return }
    DispatchQueue.main.async { self.image = image }
  }

  deinit {
    runtime?.unregister(self)
  }
}

private final class AwsDesktopVideoViewFactory: NSObject, FlutterPlatformViewFactory {
  let runtime: AwsDesktopRuntime
  let provider: AwsDesktopProvider

  init(runtime: AwsDesktopRuntime, provider: AwsDesktopProvider) {
    self.runtime = runtime
    self.provider = provider
  }

  func create(
    withViewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> NSView {
    switch provider {
    case .chime:
      let tileId = (args as? NSNumber)?.intValue ?? 0
      return AwsDesktopVideoView(
        viewKey: "chime-" + String(viewId),
        provider: .chime,
        participantId: "",
        isLocal: false,
        fixedTrackId: "chime:tile:" + String(tileId),
        runtime: runtime
      )
    case .ivs:
      let values = args as? [String: Any] ?? [:]
      return AwsDesktopVideoView(
        viewKey: "ivs-" + String(viewId),
        provider: .ivs,
        participantId: values["userId"] as? String ?? "",
        isLocal: values["isLocal"] as? Bool ?? false,
        fixedTrackId: nil,
        runtime: runtime
      )
    }
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?

  init(target: WKScriptMessageHandler) {
    self.target = target
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    target?.userContentController(userContentController, didReceive: message)
  }
}

private enum AwsDesktopError: LocalizedError {
  case assetMissing(String)
  case runtimeInitialization(String)

  var errorDescription: String? {
    switch self {
    case .assetMissing(let name):
      return "AWS desktop runtime asset is missing: " + name
    case .runtimeInitialization(let message):
      return message
    }
  }
}
