import Cocoa
import FlutterMacOS
import WebKit

public final class AgoraChatMacOSPlugin: NSObject, FlutterPlugin,
  WKScriptMessageHandler, WKNavigationDelegate
{
  private static let channelName = "flutter_realtime_chat_agora/macos"
  private static let scriptHandlerName = "flutterAgoraChat"
  private let channel: FlutterMethodChannel
  private var webView: WKWebView?
  private var bridgeReady = false
  private var didStartLoading = false
  private var readyWaiters: [(Error?) -> Void] = []

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger
    )
    let instance = AgoraChatMacOSPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    guard let sessionId = arguments["sessionId"] as? String,
      !sessionId.isEmpty
    else {
      result(FlutterError(code: "invalid-arguments", message: "Missing sessionId.", details: nil))
      return
    }

    switch call.method {
    case "create":
      guard let joinInfo = arguments["joinInfo"] as? [String: Any] else {
        result(FlutterError(code: "invalid-arguments", message: "Missing joinInfo.", details: nil))
        return
      }
      invokeBridge("create", arguments: [sessionId, joinInfo], result: result)
    case "connect":
      invokeBridge("connect", arguments: [sessionId], result: result)
    case "command":
      guard let command = arguments["command"] as? String,
        let commandArguments = arguments["arguments"] as? String
      else {
        result(FlutterError(code: "invalid-arguments", message: "Missing chat command arguments.", details: nil))
        return
      }
      invokeBridge(
        "command",
        arguments: [sessionId, command, commandArguments],
        result: result
      )
    case "disconnect":
      invokeBridge("disconnect", arguments: [sessionId], result: result)
    case "dispose":
      invokeBridge("dispose", arguments: [sessionId], result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func invokeBridge(
    _ method: String,
    arguments: [Any],
    result: @escaping FlutterResult
  ) {
    ensureBridgeReady { [weak self] error in
      guard let self = self else { return }
      if let error = error {
        result(FlutterError(code: "webview-startup", message: error.localizedDescription, details: nil))
        return
      }
      guard let webView = self.webView else {
        result(FlutterError(code: "webview-unavailable", message: "Agora Chat Web runtime is unavailable.", details: nil))
        return
      }
      Task { @MainActor in
        do {
          let value = try await webView.callAsyncJavaScript(
            "return await guardedInvoke(method, args)",
            arguments: ["method": method, "args": arguments],
            in: nil,
            contentWorld: .page
          )
          if let outcome = value as? [String: Any],
            let message = outcome["__flutterAgoraChatError"] as? String
          {
            result(
              FlutterError(
                code: "agora-chat-js",
                message: "Agora Chat \(method) failed: \(message)",
                details: ["operation": method]
              )
            )
            return
          }
          result(nil)
        } catch {
          result(Self.javaScriptFailure(error, operation: method))
        }
      }
    }
  }

  private static func javaScriptFailure(_ error: Error, operation: String) -> FlutterError {
    let nativeError = error as NSError
    let userInfo = nativeError.userInfo
    let message = userInfo["WKJavaScriptExceptionMessage"] as? String
      ?? userInfo[NSLocalizedFailureReasonErrorKey] as? String
      ?? nativeError.localizedDescription

    var details: [String: Any] = [
      "operation": operation,
      "domain": nativeError.domain,
      "code": nativeError.code,
    ]
    if let line = userInfo["WKJavaScriptExceptionLineNumber"] {
      details["lineNumber"] = line
    }
    if let column = userInfo["WKJavaScriptExceptionColumnNumber"] {
      details["columnNumber"] = column
    }
    if let sourceURL = userInfo["WKJavaScriptExceptionSourceURL"] as? String {
      details["sourceURL"] = sourceURL
    }

    return FlutterError(
      code: "agora-chat-js",
      message: "Agora Chat \(operation) failed: \(message)",
      details: details
    )
  }

  private func ensureBridgeReady(completion: @escaping (Error?) -> Void) {
    if bridgeReady {
      completion(nil)
      return
    }
    readyWaiters.append(completion)
    guard !didStartLoading else { return }
    didStartLoading = true

    let configuration = WKWebViewConfiguration()
    let userContentController = WKUserContentController()
    userContentController.add(
      WeakScriptMessageHandler(target: self),
      name: Self.scriptHandlerName
    )
    configuration.userContentController = userContentController

    let webView = WKWebView(
      frame: NSRect(x: -2, y: -2, width: 1, height: 1),
      configuration: configuration
    )
    webView.navigationDelegate = self
    self.webView = webView
    NSApplication.shared.mainWindow?.contentView?.addSubview(webView)

    do {
      let assets = try Self.assetsBundle()
      guard let htmlURL = assets.url(forResource: "agora_chat_macos", withExtension: "html") else {
        throw RuntimeError.assetMissing("agora_chat_macos.html")
      }
      webView.loadFileURL(htmlURL, allowingReadAccessTo: assets.bundleURL)
    } catch {
      finishReady(with: error)
    }
  }

  private static func assetsBundle() throws -> Bundle {
#if SWIFT_PACKAGE
    return Bundle.module
#else
    guard
      let bundleURL = Bundle.main.url(
        forResource: "flutter_realtime_chat_agora_macos_assets",
        withExtension: "bundle"
      ),
      let bundle = Bundle(url: bundleURL)
    else {
      throw RuntimeError.assetBundleMissing
    }
    return bundle
#endif
  }

  private func finishReady(with error: Error?) {
    if error == nil { bridgeReady = true }
    let waiters = readyWaiters
    readyWaiters.removeAll()
    waiters.forEach { $0(error) }
  }

  public func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any],
      let kind = body["kind"] as? String
    else { return }

    switch kind {
    case "ready":
      finishReady(with: nil)
    case "event":
      channel.invokeMethod("onEvent", arguments: body)
    case "tokenRequest":
      requestToken(for: body)
    default:
      break
    }
  }

  private func requestToken(for body: [String: Any]) {
    guard let requestId = body["requestId"],
      let sessionId = body["sessionId"] as? String
    else { return }

    channel.invokeMethod(
      "requestToken",
      arguments: ["requestId": requestId, "sessionId": sessionId]
    ) { [weak self] response in
      guard let self = self, let webView = self.webView else { return }
      let tokenResponse: [String: Any]
      if let error = response as? FlutterError {
        tokenResponse = ["error": error.message ?? "Unable to refresh Agora Chat token."]
      } else if let value = response as? [String: Any] {
        tokenResponse = value
      } else {
        tokenResponse = ["error": "Agora Chat token refresh returned no token."]
      }
      Task { @MainActor in
        _ = try? await webView.callAsyncJavaScript(
          "window.__flutterAgoraChatResolveToken(requestId, response)",
          arguments: ["requestId": requestId, "response": tokenResponse],
          in: nil,
          contentWorld: .page
        )
      }
    }
  }

  public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finishReady(with: error)
  }

  public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    finishReady(with: error)
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

private enum RuntimeError: LocalizedError {
  case assetBundleMissing
  case assetMissing(String)

  var errorDescription: String? {
    switch self {
    case .assetBundleMissing:
      return "Agora Chat macOS runtime assets are missing. Rebuild the provider bridge and reinstall macOS pods."
    case .assetMissing(let name):
      return "Agora Chat macOS runtime asset \(name) is missing."
    }
  }
}
