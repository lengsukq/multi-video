import CoreImage
import Foundation
import ImageIO
import ObjectiveC
import WebKit

/// The CocoaPods transport discovers the effects plugin supplied by SwiftPM.
/// Pixel buffers stay native; WebKit receives only a local encoded input.
@objc(FlutterRealtimeAwsProcessedFrameFeed)
final class AwsProcessedFrameFeed: NSObject {
  let sourceId: String
  private let lock = NSLock()
  private let encodeQueue = DispatchQueue(label: "flutter_realtime_aws.processed_frame")
  private let context = CIContext(options: [.cacheIntermediates: false])
  private var pendingFrame: NSObject?
  private var encoding = false
  private var disposed = false
  private var latest: (data: Data, timestampNs: Int64)?
  private var failed = false
  private var failureMessage: String?
  private var notificationScheduled = false
  var onFrameAvailable: ((Int64) -> Void)?
  var onError: ((String) -> Void)?

  init(sourceId: String) throws {
    self.sourceId = sourceId
    super.init()
    guard let hub = NSClassFromString("FlutterRealtimeProcessedVideoFrameHub"),
      let contains = class_getClassMethod(hub, NSSelectorFromString("containsSourceId:")),
      let register = class_getClassMethod(hub, NSSelectorFromString("registerWithSourceId:sink:")),
      let sinkProtocol = NSProtocolFromString("FlutterRealtimeProcessedVideoFrameSink")
    else { throw FeedError.unavailable }
    let hasSource = unsafeBitCast(method_getImplementation(contains),
      to: (@convention(c) (AnyClass, Selector, NSString) -> Bool).self)
    guard hasSource(hub, NSSelectorFromString("containsSourceId:"), sourceId as NSString)
    else { throw FeedError.unknownSource }
    class_addProtocol(AwsProcessedFrameFeed.self, sinkProtocol)
    let add = unsafeBitCast(method_getImplementation(register),
      to: (@convention(c) (AnyClass, Selector, NSString, NSObject) -> Void).self)
    add(hub, NSSelectorFromString("registerWithSourceId:sink:"), sourceId as NSString, self)
  }

  @objc(onProcessedVideoFrame:)
  func onProcessedVideoFrame(_ frame: NSObject) {
    lock.lock()
    guard !disposed, !failed else { lock.unlock(); return }
    pendingFrame = frame
    if encoding { lock.unlock(); return }
    encoding = true
    lock.unlock()
    encodeQueue.async { [weak self] in self?.encodePendingFrames() }
  }

  private func encodePendingFrames() {
    while true {
      lock.lock()
      guard !disposed, let frame = pendingFrame else {
        encoding = false
        lock.unlock()
        return
      }
      pendingFrame = nil
      lock.unlock()
      autoreleasepool {
        // CVPixelBufferRef is a Core Foundation pointer, which KVC cannot box.
        // Invoke the public Objective-C getters with their actual return types.
        let frameClass: AnyClass = type(of: frame)
        let bufferSelector = NSSelectorFromString("pixelBuffer")
        let timestampSelector = NSSelectorFromString("timestampNs")
        guard let bufferMethod = class_getInstanceMethod(frameClass, bufferSelector),
              let timestampMethod = class_getInstanceMethod(frameClass, timestampSelector) else {
          reportFailure("Native processed video frame had no pixel buffer or timestamp getter.")
          return
        }
        let getBuffer = unsafeBitCast(method_getImplementation(bufferMethod),
          to: (@convention(c) (NSObject, Selector) -> UnsafeRawPointer?).self)
        let getTimestamp = unsafeBitCast(method_getImplementation(timestampMethod),
          to: (@convention(c) (NSObject, Selector) -> Int64).self)
        guard let pointer = getBuffer(frame, bufferSelector) else {
          reportFailure("Native processed video frame had no pixel buffer.")
          return
        }
        let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(pointer).takeUnretainedValue()
        let timestamp = getTimestamp(frame, timestampSelector)
        let image = CIImage(cvPixelBuffer: buffer)
        let options: [CIImageRepresentationOption: Any] = [
          CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9
        ]
        guard let data = context.jpegRepresentation(of: image,
          colorSpace: CGColorSpaceCreateDeviceRGB(), options: options) else {
          reportFailure("Could not encode a native processed video frame as JPEG.")
          return
        }
        lock.lock()
        if !disposed, !failed { latest = (data, timestamp) }
        let notify = !disposed && !failed && !notificationScheduled
        if notify { notificationScheduled = true }
        lock.unlock()
        if notify {
          DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.notificationScheduled = false
            let timestamp = self.disposed || self.failed ? nil : self.latest?.timestampNs
            self.lock.unlock()
            if let timestamp { self.onFrameAvailable?(timestamp) }
          }
        }
      }
    }
  }

  private func reportFailure(_ message: String) {
    lock.lock()
    guard !disposed, !failed else { lock.unlock(); return }
    failed = true
    failureMessage = message
    pendingFrame = nil
    let handler = onError
    lock.unlock()
    unregisterFromHub()
    DispatchQueue.main.async { handler?(message) }
  }

  func snapshot() -> (data: Data, timestampNs: Int64)? {
    lock.lock(); defer { lock.unlock() }
    return disposed || failed ? nil : latest
  }

  var isFailed: Bool {
    lock.lock(); defer { lock.unlock() }
    return failed
  }

  var errorMessage: String? {
    lock.lock(); defer { lock.unlock() }
    return failureMessage
  }

  func dispose() {
    lock.lock()
    if disposed { lock.unlock(); return }
    disposed = true
    pendingFrame = nil
    latest = nil
    lock.unlock()
    unregisterFromHub()
  }

  private func unregisterFromHub() {
    if let hub = NSClassFromString("FlutterRealtimeProcessedVideoFrameHub"),
       let method = class_getClassMethod(hub, NSSelectorFromString("unregisterWithSourceId:sink:")) {
      let remove = unsafeBitCast(method_getImplementation(method),
        to: (@convention(c) (AnyClass, Selector, NSString, NSObject) -> Void).self)
      remove(hub, NSSelectorFromString("unregisterWithSourceId:sink:"), sourceId as NSString, self)
    }
  }

  deinit { dispose() }

  enum FeedError: LocalizedError {
    case unavailable, unknownSource
    var errorDescription: String? {
      switch self {
      case .unavailable: return "The native processed video frame bridge is unavailable."
      case .unknownSource: return "The processed video source does not exist."
      }
    }
  }
}

/// Local scheme requests avoid Flutter channels and external HTTP servers.
final class AwsProcessedFrameSchemeHandler: NSObject, WKURLSchemeHandler {
  private let lock = NSLock()
  private var feeds: [String: AwsProcessedFrameFeed] = [:]
  private static let probeImage: Data? = CIContext().pngRepresentation(
    of: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)),
    format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
  )
  private static let emptyFrame: Data? = CIContext().jpegRepresentation(
    of: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720)),
    colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]
  )

  func add(_ feed: AwsProcessedFrameFeed) {
    lock.lock(); defer { lock.unlock() }; feeds[feed.sourceId.lowercased()] = feed
  }
  func remove(_ feed: AwsProcessedFrameFeed) {
    lock.lock(); defer { lock.unlock() }
    let key = feed.sourceId.lowercased()
    if feeds[key] === feed { feeds.removeValue(forKey: key) }
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url, let sourceId = url.host,
          url.path == "/frame" else {
      urlSchemeTask.didFailWithError(URLError(.badURL)); return
    }
    lock.lock(); let feed = feeds[sourceId.lowercased()]; lock.unlock()
    if let feed, feed.isFailed {
      urlSchemeTask.didFailWithError(NSError(
        domain: "flutter_realtime_aws.processed_frame",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: feed.errorMessage ?? "Native processed video frame encoding failed."]
      ))
      return
    }
    let frame = feed?.snapshot()
    let isProbe = sourceId == "probe"
    let data = isProbe ? Self.probeImage : (frame?.data ?? Self.emptyFrame)
    let headers = [
      "Content-Type": isProbe ? "image/png" : "image/jpeg",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Expose-Headers": "X-Frame-Timestamp-Ns",
      "Cache-Control": "no-store",
      "X-Frame-Timestamp-Ns": String(frame?.timestampNs ?? 0)
    ]
    guard let response = HTTPURLResponse(url: url, statusCode: data == nil ? 500 : 200,
      httpVersion: "HTTP/1.1", headerFields: headers) else {
      urlSchemeTask.didFailWithError(URLError(.badServerResponse)); return
    }
    urlSchemeTask.didReceive(response)
    guard let data else {
      urlSchemeTask.didFailWithError(URLError(.cannotDecodeContentData))
      return
    }
    urlSchemeTask.didReceive(data)
    urlSchemeTask.didFinish()
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    // Requests complete synchronously and do not retain the WebKit task.
  }
}
