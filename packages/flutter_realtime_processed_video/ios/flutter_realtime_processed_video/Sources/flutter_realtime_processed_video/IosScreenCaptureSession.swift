import CoreMedia
import Flutter
import Foundation

/// Shared session bookkeeping, frame throttling, and dimension clamping for iOS
/// screen capture sources (`ScreenCaptureKit` on iOS 27+ and `ReplayKit` below).
final class IosScreenCaptureSession {
  static let maxDimension: CGFloat = 1280
  static let fallbackWidth = 720
  static let fallbackHeight = 1280
  static let maxFrameRate = 15.0
  private static let minFrameIntervalSeconds = 1.0 / maxFrameRate

  let id = UUID().uuidString
  private let channel: FlutterMethodChannel
  private let lock = NSLock()
  private var completion: FlutterResult?
  private var stopped = false
  private var firstFrameSeen = false
  private var wasActive = false
  private var lastPublishedPtsSeconds: Double = -.infinity

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  static func evenDimension(_ value: CGFloat) -> Int {
    let rounded = Int(value.rounded())
    return max(2, rounded - (rounded % 2))
  }

  static func boundedDimensions(
    width: CGFloat,
    height: CGFloat,
    fallbackWidth: Int = fallbackWidth,
    fallbackHeight: Int = fallbackHeight
  ) -> (Int, Int) {
    guard width > 0, height > 0 else { return (fallbackWidth, fallbackHeight) }
    let maxEdge = max(width, height)
    let ratio = maxEdge > maxDimension ? (maxDimension / maxEdge) : 1.0
    return (evenDimension(width * ratio), evenDimension(height * ratio))
  }

  func beginStart(_ result: @escaping FlutterResult) -> Bool {
    lock.lock()
    let busy = completion != nil || wasActive
    if !busy {
      stopped = false
      firstFrameSeen = false
      wasActive = false
      lastPublishedPtsSeconds = -.infinity
      completion = result
    }
    lock.unlock()
    if busy {
      result(FlutterError(
        code: "screen_capture_busy",
        message: "Screen capture is already active.",
        details: nil
      ))
      return false
    }
    FlutterRealtimeProcessedVideoFrameHub.activate(id)
    return true
  }

  var isStopped: Bool {
    lock.lock(); defer { lock.unlock() }
    return stopped
  }

  var hasPendingStart: Bool {
    lock.lock(); defer { lock.unlock() }
    return completion != nil
  }

  var isActiveAndRunning: Bool {
    lock.lock(); defer { lock.unlock() }
    return wasActive && !stopped
  }

  /// Checks throttle window and records first-frame flag atomically.
  func acceptFrame(ptsSeconds: Double) -> (accepted: Bool, isFirst: Bool) {
    lock.lock()
    defer { lock.unlock() }
    guard !stopped else { return (false, false) }
    if ptsSeconds.isFinite,
       lastPublishedPtsSeconds.isFinite,
       ptsSeconds - lastPublishedPtsSeconds < Self.minFrameIntervalSeconds {
      return (false, false)
    }
    if ptsSeconds.isFinite {
      lastPublishedPtsSeconds = ptsSeconds
    }
    let isFirst = !firstFrameSeen
    if isFirst { firstFrameSeen = true }
    return (true, isFirst)
  }

  func completeFirstFrame(width: Int, height: Int) {
    DispatchQueue.main.async {
      self.lock.lock()
      let result = self.completion
      self.completion = nil
      if result != nil { self.wasActive = true }
      self.lock.unlock()
      result?([
        "id": self.id,
        "platform": "ios",
        "kind": "nativeFrameHub",
        "width": width,
        "height": height,
        "frameRate": Self.maxFrameRate,
      ])
    }
  }

  func fail(
    _ code: String,
    _ reason: String,
    underlying: Error? = nil,
    onStop: @escaping () -> Void
  ) {
    lock.lock()
    let pending = completion
    completion = nil
    lock.unlock()
    guard let pending else { return }
    DispatchQueue.main.async {
      pending(FlutterError(
        code: code,
        message: reason,
        details: underlying?.localizedDescription
      ))
      onStop()
    }
  }

  func emitEnded(message: String) {
    channel.invokeMethod(
      "iosScreenCaptureKitEnded",
      arguments: ["sourceId": id, "message": message]
    )
  }

  /// Marks session stopped and cancels any unresolved start result.
  func markStopped() -> Bool {
    lock.lock()
    let wasAlreadyStopped = stopped
    stopped = true
    let pending = completion
    completion = nil
    lock.unlock()
    if let pending {
      DispatchQueue.main.async {
        pending(FlutterError(
          code: "screen_capture_cancelled",
          message: "Screen capture was cancelled.",
          details: nil
        ))
      }
    }
    return !wasAlreadyStopped
  }

  func clearHub() {
    FlutterRealtimeProcessedVideoFrameHub.clear(id)
  }
}
