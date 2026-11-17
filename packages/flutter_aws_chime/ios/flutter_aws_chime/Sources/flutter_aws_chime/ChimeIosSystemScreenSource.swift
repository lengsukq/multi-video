import AmazonChimeSDK
import CoreVideo
import Foundation
import os

/// Publishes FrameHub CVPixelBuffers (screen share or processed camera) into Chime.
/// Capture ownership remains in flutter_realtime_processed_video's FrameHub;
/// no CVPixelBuffer bytes travel through Flutter method channels.
final class ChimeIosSystemScreenSource: NSObject, VideoSource {
    private static let logger = Logger(subsystem: "com.oneplusdream.aws.chime",
                                       category: "ChimeIosSystemScreenSource")

    var videoContentHint: VideoContentHint

    private let sourceId: String
    private let dispatchQueue = DispatchQueue(label: "com.oneplusdream.aws.chime.screen",
                                              qos: .userInitiated)
    private let lock = NSLock()
    private var sinks: [VideoSink] = []
    private var active = false
    private var pendingFrame: (pixelBuffer: CVPixelBuffer, timestampNs: Int64)?
    private var isDispatchScheduled = false
    private var firstFrameLogged = false

    init(sourceId: String, videoContentHint: VideoContentHint = .text) {
        self.sourceId = sourceId
        self.videoContentHint = videoContentHint
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
        pendingFrame = nil
        isDispatchScheduled = false
        firstFrameLogged = false
        lock.unlock()
        Self.logger.info("Registering Chime screen sink for sourceId=\(self.sourceId, privacy: .public)")
        hub.perform(NSSelectorFromString("registerWithSourceId:sink:"),
                    with: sourceId, with: self)
    }

    func addVideoSink(sink: VideoSink) {
        lock.lock()
        if !sinks.contains(where: { $0 === sink }) { sinks.append(sink) }
        let count = sinks.count
        lock.unlock()
        Self.logger.info("Chime added content video sink count=\(count)")
    }

    func removeVideoSink(sink: VideoSink) {
        lock.lock()
        sinks.removeAll(where: { $0 === sink })
        let count = sinks.count
        lock.unlock()
        Self.logger.info("Chime removed content video sink count=\(count)")
    }

    @objc(onProcessedVideoFrame:)
    func onProcessedVideoFrame(_ received: NSObject) {
        guard let rawBuffer = received.value(forKey: "pixelBuffer") else { return }
        let pixelBuffer = rawBuffer as! CVPixelBuffer
        let timestamp = (received.value(forKey: "timestampNs") as? NSNumber)?.int64Value ?? 0

        lock.lock()
        let shouldSchedule = active && !sinks.isEmpty
        if shouldSchedule {
            pendingFrame = (pixelBuffer, timestamp)
            if !isDispatchScheduled {
                isDispatchScheduled = true
                lock.unlock()
                dispatchQueue.async { [weak self] in
                    self?.drainPendingFrame()
                }
                return
            }
        }
        lock.unlock()
    }

    private func drainPendingFrame() {
        while true {
            lock.lock()
            guard active, let next = pendingFrame else {
                isDispatchScheduled = false
                lock.unlock()
                return
            }
            pendingFrame = nil
            let targets = sinks
            let logFirst = !firstFrameLogged && !targets.isEmpty
            if logFirst { firstFrameLogged = true }
            lock.unlock()

            guard !targets.isEmpty else { continue }
            if logFirst {
                let width = CVPixelBufferGetWidth(next.pixelBuffer)
                let height = CVPixelBufferGetHeight(next.pixelBuffer)
                let format = CVPixelBufferGetPixelFormatType(next.pixelBuffer)
                Self.logger.info("Forwarding first Chime content frame \(width)x\(height) format=\(format) sinks=\(targets.count)")
            }
            let frame = VideoFrame(
                timestampNs: next.timestampNs,
                rotation: .rotation0,
                buffer: VideoFramePixelBuffer(pixelBuffer: next.pixelBuffer)
            )
            targets.forEach { $0.onVideoFrameReceived(frame: frame) }
        }
    }

    func stop() {
        lock.lock()
        let needsDetach = active
        active = false
        pendingFrame = nil
        sinks.removeAll()
        lock.unlock()
        if needsDetach,
           let hub = NSClassFromString("FlutterRealtimeProcessedVideoFrameHub") as? NSObject.Type {
            Self.logger.info("Unregistering Chime screen sink for sourceId=\(self.sourceId, privacy: .public)")
            hub.perform(NSSelectorFromString("unregisterWithSourceId:sink:"),
                        with: sourceId, with: self)
        }
    }

    deinit { stop() }
}
