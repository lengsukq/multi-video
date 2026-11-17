import AVFoundation
import UIKit
import Flutter

public final class FlutterRealtimeProcessedVideoPlugin: NSObject, FlutterPlugin {
  private var captureChannel: FlutterMethodChannel?
  private var screenCapture: AnyObject?
  private var screenProtection: IosScreenCaptureProtection?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_realtime_processed_video/sources", binaryMessenger: registrar.messenger())
    let capture = FlutterMethodChannel(name: "flutter_realtime_processed_video/ios_system_screen_capture", binaryMessenger: registrar.messenger())
    let protectionChannel = FlutterMethodChannel(name: "flutter_realtime_processed_video/screen_capture_protection", binaryMessenger: registrar.messenger())
    let plugin = FlutterRealtimeProcessedVideoPlugin()
    plugin.captureChannel = capture
    let protection = IosScreenCaptureProtection(channel: protectionChannel) { [weak plugin] in
      plugin?.screenCapture != nil
    }
    plugin.screenProtection = protection
    registrar.addMethodCallDelegate(plugin, channel: channel)
    registrar.addMethodCallDelegate(plugin, channel: capture)
    protectionChannel.setMethodCallHandler { [weak protection] call, result in
      protection?.handle(call, result: result)
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let id = args["sourceId"] as? String ?? ""
    do {
      switch call.method {
      case "iosScreenCaptureConfiguration":
        let ext = IosBroadcastExtensionScreenCaptureSource.hostConfiguration()
        let backend: String
        if #available(iOS 27.0, *), IosSystemScreenCaptureKitSource.available {
          backend = "screenCaptureKit"
        } else if ext.configured {
          backend = "broadcastExtension"
        } else if IosReplayKitScreenCaptureSource.available {
          backend = "inAppReplayKit"
        } else {
          backend = "unavailable"
        }
        result([
          "captureBackend": backend,
          "crossAppSupported": backend == "screenCaptureKit" || backend == "broadcastExtension",
          "configured": ext.configured,
          "hasAppGroup": ext.hasAppGroup,
          "hasExtension": ext.hasExtension,
          "appGroup": ext.appGroup,
          "extensionId": ext.extensionId,
        ])
      case "iosScreenCaptureKitAvailable":
        if #available(iOS 27.0, *) {
          result(IosSystemScreenCaptureKitSource.available)
        } else {
          let ext = IosBroadcastExtensionScreenCaptureSource.hostConfiguration()
          result(ext.configured || IosReplayKitScreenCaptureSource.available)
        }
      case "iosScreenCaptureKitStart":
        let preferInApp = (args["preferInApp"] as? Bool) == true
        if screenCapture != nil {
          result(FlutterError(code: "screen_capture_busy", message: "A screen capture is already active.", details: nil))
        } else if #available(iOS 27.0, *), !preferInApp {
          let capture = IosSystemScreenCaptureKitSource(channel: captureChannel!) { [weak self] source in
            DispatchQueue.main.async {
              if (self?.screenCapture as? IosSystemScreenCaptureKitSource) === source {
                self?.screenCapture = nil
                self?.screenProtection?.notifyOwnCaptureChanged()
              }
            }
          }
          screenCapture = capture
          screenProtection?.notifyOwnCaptureChanged()
          capture.start(result)
        } else {
          let ext = IosBroadcastExtensionScreenCaptureSource.hostConfiguration()
          if !preferInApp && ext.configured {
            let capture = IosBroadcastExtensionScreenCaptureSource(
              channel: captureChannel!,
              configuration: ext
            ) { [weak self] source in
              DispatchQueue.main.async {
                if (self?.screenCapture as? IosBroadcastExtensionScreenCaptureSource) === source {
                  self?.screenCapture = nil
                  self?.screenProtection?.notifyOwnCaptureChanged()
                }
              }
            }
            screenCapture = capture
            screenProtection?.notifyOwnCaptureChanged()
            capture.start(result)
          } else {
            let capture = IosReplayKitScreenCaptureSource(channel: captureChannel!) { [weak self] source in
              DispatchQueue.main.async {
                if (self?.screenCapture as? IosReplayKitScreenCaptureSource) === source {
                  self?.screenCapture = nil
                  self?.screenProtection?.notifyOwnCaptureChanged()
                }
              }
            }
            screenCapture = capture
            screenProtection?.notifyOwnCaptureChanged()
            capture.start(result)
          }
        }
      case "iosScreenCaptureKitStop":
        if #available(iOS 27.0, *), let capture = screenCapture as? IosSystemScreenCaptureKitSource {
          capture.stop { [weak self] in
            self?.screenProtection?.notifyOwnCaptureChanged()
            result(nil)
          }
        } else if let capture = screenCapture as? IosBroadcastExtensionScreenCaptureSource {
          capture.stop { [weak self] in
            self?.screenProtection?.notifyOwnCaptureChanged()
            result(nil)
          }
        } else if let capture = screenCapture as? IosReplayKitScreenCaptureSource {
          capture.stop { [weak self] in
            self?.screenProtection?.notifyOwnCaptureChanged()
            result(nil)
          }
        } else {
          result(nil)
        }
        screenCapture = nil
        screenProtection?.notifyOwnCaptureChanged()
      case "setEnabled": try FlutterRealtimeProcessedVideoFrameHub.setEnabled(id, args["enabled"] as? Bool ?? false); result(nil)
      case "selectCamera": try FlutterRealtimeProcessedVideoFrameHub.selectCamera(id, args["deviceId"] as? String); result(nil)
      case "listCameras": result(AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTrueDepthCamera], mediaType: .video, position: .unspecified).devices.map { ["id": $0.uniqueID, "label": $0.localizedName, "isFrontFacing": $0.position == .front] })
      default: result(FlutterMethodNotImplemented)
      }
    } catch { result(FlutterError(code: "processed_source_failed", message: "processed.source.\(call.method)", details: nil)) }
  }
}
