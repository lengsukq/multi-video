import AmazonChimeSDK
import CoreVideo
import Foundation

/// Publishes iOS 27 ScreenCaptureKit frames as Chime's separate content stream.
/// Capture ownership remains in flutter_realtime_processed_video's FrameHub;
/// no CVPixelBuffer bytes travel through Flutter method channels.
final class ChimeIosSystemScreenSource: NSObject, VideoSource {
    var videoContentHint: VideoContentHint = .text

    private let sourceId: String
    private let lock = NSLock()
    private var sinks: [VideoSink] = []
    private var active = false

    init(sourceId: String) {
        self.sourceId = sourceId
        super.init()
    }

    func start() throws {
        guard let hub = NSClassFromString("FlutterRealtimeProcessedVideoFrameHub") as? NSObject.Type,
              hub.responds(to: NSSelectorFromString("containsSourceId:")),
              hub.responds(to: NSSelectorFromString("registerWithSourceId:sink:"))
        else {
            throw NSError(domain: "chime.screen.frame_hub", code: -1)
        }
        lock.lock()
        active = true
        lock.unlock()
        hub.perform(NSSelectorFromString("registerWithSourceId:sink:"),
                    with: sourceId, with: self)
    }

    func addVideoSink(sink: VideoSink) {
        lock.lock()
        defer { lock.unlock() }
        if !sinks.contains(where: { $0 === sink }) { sinks.append(sink) }
    }

    func removeVideoSink(sink: VideoSink) {
        lock.lock()
        defer { lock.unlock() }
        sinks.removeAll(where: { $0 === sink })
    }

    @objc(onProcessedVideoFrame:)
    func onProcessedVideoFrame(_ received: NSObject) {
        lock.lock()
        let targets = active ? sinks : []
        lock.unlock()
        guard !targets.isEmpty,
              let rawBuffer = received.value(forKey: "pixelBuffer") else { return }
        let pixelBuffer = rawBuffer as! CVPixelBuffer
        let timestamp = (received.value(forKey: "timestampNs") as? NSNumber)?.int64Value ?? 0
        let frame = VideoFrame(
            timestampNs: timestamp,
            rotation: .rotation0,
            buffer: VideoFramePixelBuffer(pixelBuffer: pixelBuffer)
        )
        targets.forEach { $0.onVideoFrameReceived(frame: frame) }
    }

    func stop() {
        lock.lock()
        let needsDetach = active
        active = false
        sinks.removeAll()
        lock.unlock()
        if needsDetach,
           let hub = NSClassFromString("FlutterRealtimeProcessedVideoFrameHub") as? NSObject.Type {
            hub.perform(NSSelectorFromString("unregisterWithSourceId:sink:"),
                        with: sourceId, with: self)
        }
    }

    deinit { stop() }
}
