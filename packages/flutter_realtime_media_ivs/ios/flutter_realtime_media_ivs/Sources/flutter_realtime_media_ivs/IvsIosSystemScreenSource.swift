import AmazonIVSBroadcast
import CoreMedia
import CoreVideo
import Foundation

/// Feeds the Stage's custom image source from the common ScreenCaptureKit
/// FrameHub. The frame is repackaged as CMSampleBuffer without encoding or
/// copying pixel bytes to Dart.
final class IvsIosSystemScreenSource: NSObject {
    private let sourceId: String
    private let output: IVSCustomImageSource
    private let lock = NSLock()
    private var active = false

    init(sourceId: String, output: IVSCustomImageSource) {
        self.sourceId = sourceId
        self.output = output
        super.init()
    }

    func start() throws {
        guard let hub = NSClassFromString("FlutterRealtimeProcessedVideoFrameHub") as? NSObject.Type,
              hub.responds(to: NSSelectorFromString("containsSourceId:")),
              hub.responds(to: NSSelectorFromString("registerWithSourceId:sink:"))
        else { throw NSError(domain: "ivs.screen.frame_hub", code: -1) }
        lock.lock()
        active = true
        lock.unlock()
        hub.perform(NSSelectorFromString("registerWithSourceId:sink:"),
                    with: sourceId, with: self)
    }

    @objc(onProcessedVideoFrame:)
    func onProcessedVideoFrame(_ received: NSObject) {
        lock.lock()
        let enabled = active
        lock.unlock()
        guard enabled, let value = received.value(forKey: "pixelBuffer") else { return }
        let pixelBuffer = value as! CVPixelBuffer
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format) == noErr,
            let format else { return }
        let ns = (received.value(forKey: "timestampNs") as? NSNumber)?.int64Value ?? 0
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: ns, timescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample) == noErr,
            let sample else { return }
        output.onSampleBuffer(sample)
    }

    func stop() {
        lock.lock()
        let attached = active
        active = false
        lock.unlock()
        if attached,
           let hub = NSClassFromString("FlutterRealtimeProcessedVideoFrameHub") as? NSObject.Type {
            hub.perform(NSSelectorFromString("unregisterWithSourceId:sink:"),
                        with: sourceId, with: self)
        }
    }

    deinit { stop() }
}
