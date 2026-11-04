import AVFoundation
import UIKit
import Flutter

public final class FlutterRealtimeProcessedVideoPlugin: NSObject, FlutterPlugin {
  private var captureChannel: FlutterMethodChannel?
  private var screenCapture: AnyObject?
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_realtime_processed_video/sources", binaryMessenger: registrar.messenger())
    let capture = FlutterMethodChannel(name: "flutter_realtime_processed_video/ios_system_screen_capture", binaryMessenger: registrar.messenger())
    let plugin = FlutterRealtimeProcessedVideoPlugin()
    plugin.captureChannel = capture
    registrar.addMethodCallDelegate(plugin, channel: channel)
    registrar.addMethodCallDelegate(plugin, channel: capture)
  }
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let id = args["sourceId"] as? String ?? ""
    do {
      switch call.method {
      case "iosScreenCaptureKitAvailable":
        if #available(iOS 27.0, *) {
          result(IosSystemScreenCaptureKitSource.available)
        } else {
          result(false)
        }
      case "iosScreenCaptureKitStart":
        if #available(iOS 27.0, *) {
          if screenCapture != nil {
            result(FlutterError(code: "screen_capture_busy", message: "A screen capture is already active.", details: nil))
          } else {
            let capture = IosSystemScreenCaptureKitSource(channel: captureChannel!)
            screenCapture = capture
            capture.start(result)
          }
        } else {
          result(FlutterError(code: "screen_capture_unsupported", message: "Requires iOS 27+.", details: nil))
        }
      case "iosScreenCaptureKitStop":
        if #available(iOS 27.0, *), let capture = screenCapture as? IosSystemScreenCaptureKitSource {
          capture.stop { result(nil) }
        } else {
          result(nil)
        }
        screenCapture = nil
      case "setEnabled": try FlutterRealtimeProcessedVideoFrameHub.setEnabled(id, args["enabled"] as? Bool ?? false); result(nil)
      case "selectCamera": try FlutterRealtimeProcessedVideoFrameHub.selectCamera(id, args["deviceId"] as? String); result(nil)
      case "listCameras": result(AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTrueDepthCamera], mediaType: .video, position: .unspecified).devices.map { ["id": $0.uniqueID, "label": $0.localizedName, "isFrontFacing": $0.position == .front] })
      default: result(FlutterMethodNotImplemented)
      }
    } catch { result(FlutterError(code: "processed_source_failed", message: "processed.source.\(call.method)", details: nil)) }
  }
}
