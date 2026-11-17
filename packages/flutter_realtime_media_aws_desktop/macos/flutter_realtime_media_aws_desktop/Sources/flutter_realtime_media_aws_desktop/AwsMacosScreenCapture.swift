import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit

enum AwsMacosScreenCaptureError: LocalizedError {
  case unsupportedMacOS
  case permissionDenied
  case sourceNotFound
  case captureStartFailed(String)

  var code: String {
    switch self {
    case .unsupportedMacOS: return "unsupported_feature"
    case .permissionDenied: return "permission_denied"
    case .sourceNotFound: return "invalid_argument"
    case .captureStartFailed: return "native_error"
    }
  }

  var errorDescription: String? {
    switch self {
    case .unsupportedMacOS:
      return "macOS screen capture requires macOS 12.3 or later."
    case .permissionDenied:
      return "Screen Recording permission is required. Enable access in System Settings > Privacy & Security > Screen & System Audio Recording."
    case .sourceNotFound:
      return "The selected display or window is no longer available."
    case .captureStartFailed(let message):
      return message
    }
  }
}

@available(macOS 12.3, *)
final class AwsMacosScreenCaptureSession: NSObject, AwsFrameSource, SCStreamOutput, SCStreamDelegate {
  let sourceId: String
  private let lock = NSLock()
  private let sampleQueue = DispatchQueue(
    label: "flutter_realtime_aws.screen_capture.samples",
    qos: .userInteractive
  )
  private let encodeQueue = DispatchQueue(
    label: "flutter_realtime_aws.screen_capture.encode",
    qos: .userInteractive
  )
  private static let jpegOptions: [CIImageRepresentationOption: Any] = [
    CIImageRepresentationOption(
      rawValue: kCGImageDestinationLossyCompressionQuality as String
    ): 0.72
  ]

  private var stream: SCStream?
  private var pendingBuffer: CVImageBuffer?
  private var pendingTimestampNs: Int64 = 0
  private var encoding = false
  private var disposed = false
  private var latest: (data: Data, timestampNs: Int64)?
  private(set) var isFailed = false
  private(set) var errorMessage: String?

  var onFrameAvailable: ((Int64) -> Void)?
  var onStopped: ((String?) -> Void)?

  init(sourceId: String) {
    self.sourceId = sourceId
    super.init()
  }

  static func listSources() async throws -> [[String: String]] {
    if !CGPreflightScreenCaptureAccess() {
      _ = CGRequestScreenCaptureAccess()
      if !CGPreflightScreenCaptureAccess() {
        throw AwsMacosScreenCaptureError.permissionDenied
      }
    }
    let content: SCShareableContent
    do {
      content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
      )
    } catch {
      if !CGPreflightScreenCaptureAccess() {
        throw AwsMacosScreenCaptureError.permissionDenied
      }
      throw AwsMacosScreenCaptureError.captureStartFailed(error.localizedDescription)
    }

    var results: [[String: String]] = []
    for (index, display) in content.displays.enumerated() {
      let label = content.displays.count == 1
        ? "Main Display (\(display.width)x\(display.height))"
        : "Display \(index + 1) (\(display.width)x\(display.height))"
      results.append([
        "id": "display:\(display.displayID)",
        "name": label,
        "kind": "display",
      ])
    }
    let currentPid = ProcessInfo.processInfo.processIdentifier
    for window in content.windows {
      guard window.isOnScreen,
            window.windowLayer == 0,
            window.frame.width >= 64,
            window.frame.height >= 64,
            window.owningApplication?.processID != currentPid else {
        continue
      }
      let appName = window.owningApplication?.applicationName.trimmingCharacters(
        in: .whitespacesAndNewlines
      ) ?? ""
      let rawTitle = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let label: String
      if !rawTitle.isEmpty && !appName.isEmpty && rawTitle != appName {
        label = "\(appName) - \(rawTitle)"
      } else if !rawTitle.isEmpty {
        label = rawTitle
      } else if !appName.isEmpty {
        label = appName
      } else {
        continue
      }
      results.append([
        "id": "window:\(window.windowID)",
        "name": label,
        "kind": "window",
      ])
    }
    return results
  }

  func start(selectedSourceId: String?) async throws {
    if !CGPreflightScreenCaptureAccess() {
      _ = CGRequestScreenCaptureAccess()
      if !CGPreflightScreenCaptureAccess() {
        throw AwsMacosScreenCaptureError.permissionDenied
      }
    }
    let content: SCShareableContent
    do {
      content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
      )
    } catch {
      if !CGPreflightScreenCaptureAccess() {
        throw AwsMacosScreenCaptureError.permissionDenied
      }
      throw AwsMacosScreenCaptureError.captureStartFailed(error.localizedDescription)
    }

    let filter: SCContentFilter
    let rawWidth: Int
    let rawHeight: Int
    if let selected = selectedSourceId, selected.hasPrefix("window:"),
       let rawId = UInt32(selected.dropFirst("window:".count)) {
      guard let window = content.windows.first(where: { $0.windowID == rawId }) else {
        throw AwsMacosScreenCaptureError.sourceNotFound
      }
      filter = SCContentFilter(desktopIndependentWindow: window)
      rawWidth = max(2, Int(window.frame.width.rounded()))
      rawHeight = max(2, Int(window.frame.height.rounded()))
    } else if let selected = selectedSourceId, selected.hasPrefix("display:"),
              let rawId = UInt32(selected.dropFirst("display:".count)) {
      guard let display = content.displays.first(where: { $0.displayID == rawId }) else {
        throw AwsMacosScreenCaptureError.sourceNotFound
      }
      filter = SCContentFilter(display: display, excludingWindows: [])
      rawWidth = max(2, display.width)
      rawHeight = max(2, display.height)
    } else if let display = content.displays.first {
      filter = SCContentFilter(display: display, excludingWindows: [])
      rawWidth = max(2, display.width)
      rawHeight = max(2, display.height)
    } else {
      throw AwsMacosScreenCaptureError.sourceNotFound
    }

    let scale = min(1.0, 1280.0 / Double(max(rawWidth, rawHeight)))
    let targetWidth = max(2, (Int((Double(rawWidth) * scale).rounded()) / 2) * 2)
    let targetHeight = max(2, (Int((Double(rawHeight) * scale).rounded()) / 2) * 2)

    let config = SCStreamConfiguration()
    config.width = targetWidth
    config.height = targetHeight
    config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = true
    config.queueDepth = 3

    let captureStream = SCStream(filter: filter, configuration: config, delegate: self)
    try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
    try await captureStream.startCapture()

    if !attachStartedStream(captureStream) {
      try? await captureStream.stopCapture()
      return
    }
  }

  private func attachStartedStream(_ captureStream: SCStream) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if disposed { return false }
    stream = captureStream
    return true
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, sampleBuffer.isValid else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: false
    ) as? [[SCStreamFrameInfo: Any]],
       let statusValue = attachments.first?[.status] as? Int,
       let status = SCFrameStatus(rawValue: statusValue),
       status != .complete {
      return
    }
    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let timestampNs = Int64(max(0, pts.seconds * 1_000_000_000))

    lock.lock()
    guard !disposed, !isFailed else {
      lock.unlock()
      return
    }
    pendingBuffer = imageBuffer
    pendingTimestampNs = timestampNs
    if encoding {
      lock.unlock()
      return
    }
    encoding = true
    lock.unlock()
    encodeQueue.async { [weak self] in self?.encodePendingFrames() }
  }

  private func encodePendingFrames() {
    while true {
      lock.lock()
      guard !disposed, let buffer = pendingBuffer else {
        encoding = false
        lock.unlock()
        return
      }
      let timestampNs = pendingTimestampNs
      pendingBuffer = nil
      lock.unlock()

      autoreleasepool {
        let image = CIImage(cvImageBuffer: buffer)
        guard let data = AwsProcessedFrameFeed.sharedCIContext.jpegRepresentation(
          of: image,
          colorSpace: AwsProcessedFrameFeed.sharedColorSpace,
          options: Self.jpegOptions
        ) else {
          return
        }
        lock.lock()
        guard !disposed else {
          lock.unlock()
          return
        }
        latest = (data, timestampNs)
        let callback = onFrameAvailable
        lock.unlock()
        callback?(timestampNs)
      }
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    lock.lock()
    if disposed {
      lock.unlock()
      return
    }
    disposed = true
    isFailed = true
    errorMessage = error.localizedDescription
    self.stream = nil
    pendingBuffer = nil
    let stopCallback = onStopped
    onStopped = nil
    onFrameAvailable = nil
    lock.unlock()
    stopCallback?(error.localizedDescription)
  }

  func snapshot() -> (data: Data, timestampNs: Int64)? {
    lock.lock()
    defer { lock.unlock() }
    return latest
  }

  func stop() {
    lock.lock()
    let wasDisposed = disposed
    disposed = true
    let activeStream = stream
    stream = nil
    pendingBuffer = nil
    latest = nil
    onFrameAvailable = nil
    onStopped = nil
    lock.unlock()
    guard !wasDisposed, let activeStream else { return }
    Task {
      try? await activeStream.stopCapture()
    }
  }

  deinit {
    stop()
  }
}
