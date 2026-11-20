import Foundation
import CoreVideo
import CoreMedia
import AliVCSDK_ARTC

/// Consumes processed camera CVPixelBuffers from FlutterRealtimeProcessedVideoFrameHub
/// and feeds them into Alibaba ARTC's external camera video source on iOS.
final class ArtcIosExternalCameraSink: NSObject {
  private let sourceId: String
  private weak var engine: AliRtcEngine?
  private var active = false

  init(sourceId: String, engine: AliRtcEngine) {
    self.sourceId = sourceId
    self.engine = engine
  }

  func start() throws {
    guard let engine else {
      throw NSError(domain: "artc.processed", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "ARTC engine is unavailable."])
    }
    let sourceCode = engine.setExternalVideoSource(
      true, sourceType: .videosourceCameraType, renderMode: .auto)
    guard sourceCode == 0 else {
      throw NSError(domain: "artc.processed.source", code: Int(sourceCode),
                    userInfo: [NSLocalizedDescriptionKey: "ARTC rejected external camera source (\(sourceCode))."])
    }
    guard let hub = NSClassFromString("FlutterRealtimeProcessedVideoFrameHub") as? NSObject.Type,
          hub.responds(to: NSSelectorFromString("containsSourceId:")) else {
      _ = engine.setExternalVideoSource(
        false, sourceType: .videosourceCameraType, renderMode: .auto)
      throw NSError(domain: "artc.processed.hub", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Processed video frame hub is unavailable."])
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
    let code = engine.pushExternalVideoFrame(sample, sourceType: .videosourceCameraType)
    if code != 0 {
      // A full buffer queue is a recoverable frame drop, not a capture stop.
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
      _ = engine.publishLocalVideoStream(false)
      _ = engine.setExternalVideoSource(
        false, sourceType: .videosourceCameraType, renderMode: .auto)
    }
  }

  deinit { stop() }
}
