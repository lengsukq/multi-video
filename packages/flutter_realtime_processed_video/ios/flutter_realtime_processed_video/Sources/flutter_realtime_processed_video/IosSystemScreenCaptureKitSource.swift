import CoreMedia
import Flutter
import Foundation
import os
import ScreenCaptureKit

/// iOS 27+ screen capture shared by all native RTC providers. Screen frames
/// remain CVPixelBuffers and are dispatched through the existing native
/// frame hub; no video pixels are encoded into Flutter MethodChannel values.
@available(iOS 27.0, *)
final class IosSystemScreenCaptureKitSource: NSObject, SCContentSharingPickerObserver,
                                              SCStreamOutput, SCStreamDelegate {
  private static let maxDimension: CGFloat = 1280
  private static let fallbackWidth = 720
  private static let fallbackHeight = 1280
  private static let maxFrameRate = 15.0
  private static let minFrameIntervalSeconds = 1.0 / maxFrameRate
  private static let logger = Logger(subsystem: "com.oneplusdream.multi_video",
                                     category: "ScreenCaptureKit")

  private let id = UUID().uuidString
  private let channel: FlutterMethodChannel
  private let onInvalidated: ((IosSystemScreenCaptureKitSource) -> Void)?
  private let sampleQueue = DispatchQueue(label: "realtime.screencapturekit.frames",
                                          qos: .userInteractive)
  private let lock = NSLock()
  private var stream: SCStream?
  private var completion: FlutterResult?
  private var stopped = false
  private var firstFrameSeen = false
  private var wasActive = false
  private var lastPublishedPtsSeconds: Double = -.infinity

  init(channel: FlutterMethodChannel,
       onInvalidated: ((IosSystemScreenCaptureKitSource) -> Void)? = nil) {
    self.channel = channel
    self.onInvalidated = onInvalidated
    super.init()
  }

  static var available: Bool { SCContentSharingPicker.shared.isAvailable }

  func start(_ result: @escaping FlutterResult) {
    guard Self.available else {
      Self.logger.warning("ScreenCaptureKit picker unavailable on this device")
      result(FlutterError(code: "screen_capture_unavailable",
                          message: "ScreenCaptureKit is unavailable on this iPhone.",
                          details: nil))
      return
    }
    lock.lock()
    let alreadyStarted = completion != nil || stream != nil || wasActive
    if !alreadyStarted {
      stopped = false
      firstFrameSeen = false
      lastPublishedPtsSeconds = -.infinity
      completion = result
    }
    lock.unlock()
    if alreadyStarted {
      result(FlutterError(code: "screen_capture_busy",
                          message: "ScreenCaptureKit is already capturing.",
                          details: nil))
      return
    }
    Self.logger.info("Starting ScreenCaptureKit picker sourceId=\(self.id, privacy: .public)")
    FlutterRealtimeProcessedVideoFrameHub.activate(id)
    let picker = SCContentSharingPicker.shared
    var configuration = SCContentSharingPickerConfiguration()
    configuration.showsMicrophoneControl = false
    picker.defaultConfiguration = configuration
    picker.add(self)
    picker.isActive = true
    picker.present()

    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
      guard let self else { return }
      self.fail("screen_capture_timeout",
                "No content was selected or no frames arrived in 60 seconds.")
    }
  }

  func stop(completion done: (() -> Void)? = nil) {
    let deactivatePicker = {
      let picker = SCContentSharingPicker.shared
      picker.remove(self)
      picker.isActive = false
    }
    if Thread.isMainThread {
      deactivatePicker()
    } else {
      DispatchQueue.main.async(execute: deactivatePicker)
    }

    lock.lock()
    let wasAlreadyStopped = stopped
    stopped = true
    let running = stream
    stream = nil
    let pending = completion
    completion = nil
    lock.unlock()

    if !wasAlreadyStopped {
      Self.logger.info("Stopping ScreenCaptureKit sourceId=\(self.id, privacy: .public)")
    }
    if let pending {
      DispatchQueue.main.async {
        pending(FlutterError(code: "screen_capture_cancelled",
                             message: "Screen capture was cancelled.", details: nil))
      }
    }
    let finish = {
      FlutterRealtimeProcessedVideoFrameHub.clear(self.id)
      self.onInvalidated?(self)
      done?()
    }
    if let running {
      running.stopCapture { error in
        if let error {
          Self.logger.warning("SCStream stopCapture error: \(error.localizedDescription, privacy: .public)")
        }
        finish()
      }
    } else {
      finish()
    }
  }

  private func fail(_ code: String, _ reason: String, underlying: Error? = nil) {
    lock.lock()
    let pending = completion
    completion = nil
    lock.unlock()
    guard let pending else { return }
    Self.logger.error("ScreenCaptureKit failed code=\(code, privacy: .public) reason=\(reason, privacy: .public) err=\(underlying?.localizedDescription ?? "none", privacy: .public)")
    DispatchQueue.main.async {
      pending(FlutterError(code: code, message: reason,
                           details: underlying?.localizedDescription))
      self.stop()
    }
  }

  private func makeStreamConfiguration(for filter: SCContentFilter) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.captureDynamicRange = .SDR
    let scale = CGFloat(max(filter.pointPixelScale, 1.0))
    let rawWidth = filter.contentRect.width * scale
    let rawHeight = filter.contentRect.height * scale
    if rawWidth > 0 && rawHeight > 0 {
      let maxEdge = max(rawWidth, rawHeight)
      let ratio = maxEdge > Self.maxDimension ? (Self.maxDimension / maxEdge) : 1.0
      configuration.width = Self.evenDimension(rawWidth * ratio)
      configuration.height = Self.evenDimension(rawHeight * ratio)
    } else {
      configuration.width = Self.fallbackWidth
      configuration.height = Self.fallbackHeight
    }
    return configuration
  }

  private static func evenDimension(_ value: CGFloat) -> Int {
    let rounded = Int(value.rounded())
    return max(2, rounded - (rounded % 2))
  }

  func contentSharingPicker(_ picker: SCContentSharingPicker,
                            didUpdateWith filter: SCContentFilter,
                            for changedStream: SCStream?) {
    Self.logger.info("Picker didUpdateWith rect=\(String(describing: filter.contentRect), privacy: .public) scale=\(filter.pointPixelScale, privacy: .public)")
    DispatchQueue.main.async {
      self.lock.lock()
      let shouldStop = self.stopped
      let previous = self.stream
      self.stream = nil
      self.lock.unlock()
      guard !shouldStop else { return }
      if let previous {
        // updateContentFilter is unavailable on iOS. Keep the original frame
        // hub subscription and restart only the system capture stream.
        previous.stopCapture { _ in
          DispatchQueue.main.async { self.openStream(filter) }
        }
      } else {
        self.openStream(filter)
      }
    }
  }

  private func openStream(_ filter: SCContentFilter) {
    lock.lock()
    let inactive = stopped
    lock.unlock()
    guard !inactive else { return }
    let configuration = makeStreamConfiguration(for: filter)
    Self.logger.info("Opening SCStream \(configuration.width)x\(configuration.height) sdr")
    let next = SCStream(filter: filter, configuration: configuration, delegate: self)
    lock.lock()
    stream = next
    lock.unlock()
    do {
      try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
    } catch {
      fail("screen_capture_failed", "Could not attach the screen frame output.",
           underlying: error)
      return
    }
    next.startCapture { error in
      if let error {
        self.fail("screen_capture_failed", "Screen capture could not start.",
                  underlying: error)
      } else {
        Self.logger.info("SCStream startCapture succeeded")
      }
    }
  }

  func contentSharingPicker(_ picker: SCContentSharingPicker,
                            didCancelFor cancelledStream: SCStream?) {
    Self.logger.info("Picker didCancelFor invoked")
    lock.lock()
    let hasPendingStart = completion != nil
    let hadPublished = wasActive && !stopped
    lock.unlock()
    if hasPendingStart {
      fail("screen_capture_cancelled", "Screen selection was cancelled.")
    } else if hadPublished {
      DispatchQueue.main.async {
        self.channel.invokeMethod("iosScreenCaptureKitEnded",
                                  arguments: ["sourceId": self.id,
                                              "message": "Screen sharing was stopped by the system."])
        self.stop()
      }
    }
  }

  func contentSharingPickerStartDidFailWithError(_ error: Error) {
    fail("screen_capture_failed", "The system screen picker could not open.",
         underlying: error)
  }

  func stream(_ activeStream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
              of type: SCStreamOutputType) {
    guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
       let rawStatus = attachments.first?[.status] as? Int,
       let status = SCFrameStatus(rawValue: rawStatus),
       status != .complete {
      return
    }
    guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let ptsSeconds = timestamp.isValid && timestamp.isNumeric ? timestamp.seconds : .nan

    lock.lock()
    var canPublish = !stopped && stream === activeStream
    if canPublish, ptsSeconds.isFinite,
       lastPublishedPtsSeconds.isFinite,
       ptsSeconds - lastPublishedPtsSeconds < Self.minFrameIntervalSeconds {
      canPublish = false
    }
    var first = false
    if canPublish {
      if ptsSeconds.isFinite {
        lastPublishedPtsSeconds = ptsSeconds
      }
      first = !firstFrameSeen
      if first { firstFrameSeen = true }
    }
    lock.unlock()
    guard canPublish else { return }

    FlutterRealtimeProcessedVideoFrameHub.publish(
      FlutterRealtimeProcessedVideoFrame(sourceId: id, pixelBuffer: image,
                                         timestamp: timestamp))
    if first {
      let width = CVPixelBufferGetWidth(image)
      let height = CVPixelBufferGetHeight(image)
      let format = CVPixelBufferGetPixelFormatType(image)
      Self.logger.info("First screen frame \(width)x\(height) pixelFormat=\(format)")
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
  }

  func stream(_ activeStream: SCStream, didStopWithError error: Error) {
    Self.logger.error("SCStream didStopWithError: \(error.localizedDescription, privacy: .public)")
    lock.lock()
    let expected = stream === activeStream && !stopped
    let hadPublished = wasActive
    lock.unlock()
    guard expected else { return }
    if !hadPublished {
      fail("screen_capture_failed", "Screen capture stopped before its first frame.",
           underlying: error)
    } else {
      DispatchQueue.main.async {
        self.channel.invokeMethod("iosScreenCaptureKitEnded",
                                  arguments: ["sourceId": self.id,
                                              "message": error.localizedDescription])
        self.stop()
      }
    }
  }
}
