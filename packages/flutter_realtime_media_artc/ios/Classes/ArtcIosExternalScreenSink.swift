import Foundation
import CoreVideo
import CoreMedia
import AliVCSDK_ARTC

/// The ARTC screen stream consumes the same native CVPixelBuffers as other
/// providers. This sink does not own screen capture or request a ReplayKit
/// Broadcast Upload Extension; iOS 27 ScreenCaptureKit owns the source.
final class ArtcIosExternalScreenSink: NSObject {
  private let sourceId: String
  private weak var engine: AliRtcEngine?
  private var active = false

  init(sourceId: String, engine: AliRtcEngine) {
    self.sourceId = sourceId
    self.engine = engine
  }

  func start() throws {
    guard let engine else { throw NSError(domain: "artc.screen", code: -1) }
    let sourceCode = engine.setExternalVideoSource(
      true, sourceType: .videosourceScreenShareType, renderMode: .auto)
    guard sourceCode == 0 else {
      throw NSError(domain: "artc.screen.source", code: Int(sourceCode))
    }
    let publishing = engine.startScreenShare()
    guard publishing == 0 else {
      _ = engine.setExternalVideoSource(
        false, sourceType: .videosourceScreenShareType, renderMode: .auto)
      throw NSError(domain: "artc.screen.publish", code: Int(publishing))
    }
    guard let hub = NSClassFromString("FlutterRealtimeProcessedVideoFrameHub") as? NSObject.Type,
          hub.responds(to: NSSelectorFromString("containsSourceId:")) else {
      _ = engine.stopScreenShare()
      _ = engine.setExternalVideoSource(
        false, sourceType: .videosourceScreenShareType, renderMode: .auto)
      throw NSError(domain: "artc.screen.hub", code: -1)
    }
    hub.perform(NSSelectorFromString("registerWithSourceId:sink:"),
                with: sourceId, with: self)
    active = true
  }

  @objc(onProcessedVideoFrame:)
  func onProcessedVideoFrame(_ received: NSObject) {
    guard active, let engine,
          let rawBuffer = received.value(forKey: "pixelBuffer")
    else { return }
    // FrameHub owns this CoreVideo buffer. KVC exposes it as Any, which
    // cannot be conditionally downcast to a CoreFoundation buffer in Swift.
    let frameBuffer = rawBuffer as! CVPixelBuffer
    let sample = AliRtcVideoDataSample()
    sample.format = .cvPixelBuffer
    sample.type = .cvPixelBuffer
    sample.pixelBuffer = frameBuffer
    sample.width = Int32(CVPixelBufferGetWidth(frameBuffer))
    sample.height = Int32(CVPixelBufferGetHeight(frameBuffer))
    sample.rotation = 0
    if let nanos = received.value(forKey: "timestampNs") as? NSNumber {
      sample.timeStamp = nanos.int64Value / 1_000_000
    }
    let code = engine.pushExternalVideoFrame(sample, sourceType: .videosourceScreenShareType)
    if code != 0 {
      // A full buffer queue is a recoverable frame drop, not a capture stop.
      // The provider will continue consuming the next video frame.
      return
    }
  }

  func stop() {
    guard active else { return }
    active = false
    if let hub = NSClassFromString("FlutterRealtimeProcessedVideoFrameHub") as? NSObject.Type {
      hub.perform(NSSelectorFromString("unregisterWithSourceId:sink:"),
                  with: sourceId, with: self)
    }
    if let engine {
      _ = engine.stopScreenShare()
      _ = engine.setExternalVideoSource(
        false, sourceType: .videosourceScreenShareType, renderMode: .auto)
    }
  }

  deinit { stop() }
}
