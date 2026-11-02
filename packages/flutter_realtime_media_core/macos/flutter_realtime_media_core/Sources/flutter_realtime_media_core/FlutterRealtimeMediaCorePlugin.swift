import AVFoundation
import Cocoa
import FlutterMacOS

/// Shared macOS TCC permission bridge; independent of the selected RTC provider.
public final class FlutterRealtimeMediaCorePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var microphoneEngine: AVAudioEngine?
  private var microphoneSink: FlutterEventSink?
  private var lastMeterUpdate: TimeInterval = 0

  public static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = FlutterRealtimeMediaCorePlugin()
    let channel = FlutterMethodChannel(
      name: "flutter_realtime_media_core/permissions",
      binaryMessenger: registrar.messenger
    )
    registrar.addMethodCallDelegate(plugin, channel: channel)
    let levels = FlutterEventChannel(
      name: "flutter_realtime_media_core/microphone_levels",
      binaryMessenger: registrar.messenger
    )
    levels.setStreamHandler(plugin)
  }

  /// Use the system's real input PCM samples, not an animated substitute or
  /// an RTC-provider-specific visualizer. The tap is installed only while
  /// Pre-Join's enabled microphone meter has an active Dart listener.
  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    stopMicrophoneMeter()
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      return FlutterError(
        code: "microphone_permission_denied",
        message: "Enable microphone access for this app in macOS Privacy settings.",
        details: nil
      )
    }
    do {
      let engine = AVAudioEngine()
      let input = engine.inputNode
      let format = input.inputFormat(forBus: 0)
      guard format.channelCount > 0, format.sampleRate > 0 else {
        return FlutterError(code: "no_microphone_input", message: "No usable microphone input is available.", details: nil)
      }
      microphoneSink = events
      lastMeterUpdate = 0
      microphoneEngine = engine
      input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        guard frames > 0 && count > 0 else { return }
        var sum: Double = 0
        for channel in 0..<count {
          let samples = channels[channel]
          for frame in 0..<frames {
            let sample = Double(samples[frame])
            sum += sample * sample
          }
        }
        let rms = sqrt(sum / Double(frames * count))
        // Use a perceptual gain for normal speech while retaining a quiet
        // noise floor. Values are always derived from the actual PCM buffer.
        let level = min(1.0, max(0.0, rms * 8.0))
        DispatchQueue.main.async { [weak self] in
          guard let self = self, let sink = self.microphoneSink else { return }
          let now = ProcessInfo.processInfo.systemUptime
          guard now - self.lastMeterUpdate >= 0.05 else { return }
          self.lastMeterUpdate = now
          sink(level)
        }
      }
      engine.prepare()
      try engine.start()
      return nil
    } catch {
      stopMicrophoneMeter()
      return FlutterError(
        code: "microphone_meter_failed",
        message: "Unable to read the macOS microphone audio level.",
        details: error.localizedDescription
      )
    }
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stopMicrophoneMeter()
    return nil
  }

  private func stopMicrophoneMeter() {
    microphoneSink = nil
    guard let engine = microphoneEngine else { return }
    microphoneEngine = nil
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "openSettings" {
      guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") else {
        result(false)
        return
      }
      result(NSWorkspace.shared.open(url))
      return
    }

    guard let args = call.arguments as? [String: Any],
          let kind = args["kind"] as? String else {
      result(FlutterError(code: "invalid_arguments", message: "Missing media permission kind", details: nil))
      return
    }

    let mediaType: AVMediaType
    switch kind {
    case "camera": mediaType = .video
    case "microphone": mediaType = .audio
    default:
      result(FlutterError(code: "invalid_arguments", message: "Unknown media permission kind", details: nil))
      return
    }

    switch call.method {
    case "status":
      result(statusName(AVCaptureDevice.authorizationStatus(for: mediaType)))
    case "request":
      if AVCaptureDevice.authorizationStatus(for: mediaType) == .notDetermined {
        AVCaptureDevice.requestAccess(for: mediaType) { _ in
          DispatchQueue.main.async {
            result(self.statusName(AVCaptureDevice.authorizationStatus(for: mediaType)))
          }
        }
      } else {
        result(statusName(AVCaptureDevice.authorizationStatus(for: mediaType)))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func statusName(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "granted"
    case .notDetermined: return "unknown"
    case .denied: return "permanentlyDenied"
    case .restricted: return "restricted"
    @unknown default: return "unknown"
    }
  }
}
