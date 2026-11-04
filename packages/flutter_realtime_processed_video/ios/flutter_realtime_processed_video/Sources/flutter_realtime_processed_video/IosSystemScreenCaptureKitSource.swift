import CoreMedia
import Flutter
import Foundation
import ScreenCaptureKit

/// iOS 27+ screen capture shared by all native RTC providers. Screen frames
/// remain CVPixelBuffers and are dispatched through the existing native
/// frame hub; no video pixels are encoded into Flutter MethodChannel values.
@available(iOS 27.0, *)
final class IosSystemScreenCaptureKitSource: NSObject, SCContentSharingPickerObserver,
                                              SCStreamOutput, SCStreamDelegate {
  private let id = UUID().uuidString
  private let channel: FlutterMethodChannel
  private let sampleQueue = DispatchQueue(label: "realtime.screencapturekit.frames",
                                          qos: .userInteractive)
  private let lock = NSLock()
  private var stream: SCStream?
  private var completion: FlutterResult?
  private var stopped = false
  private var firstFrameSeen = false
  private var wasActive = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  static var available: Bool { SCContentSharingPicker.shared.isAvailable }

  func start(_ result: @escaping FlutterResult) {
    guard Self.available else {
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
      completion = result
    }
    lock.unlock()
    if alreadyStarted {
      result(FlutterError(code: "screen_capture_busy",
                          message: "ScreenCaptureKit is already capturing.",
                          details: nil))
      return
    }
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
    let picker = SCContentSharingPicker.shared
    picker.remove(self)
    lock.lock()
    stopped = true
    let running = stream
    stream = nil
    let pending = completion
    completion = nil
    lock.unlock()
    if let pending {
      DispatchQueue.main.async {
        pending(FlutterError(code: "screen_capture_cancelled",
                             message: "Screen capture was cancelled.", details: nil))
      }
    }
    let finish = {
      FlutterRealtimeProcessedVideoFrameHub.clear(self.id)
      done?()
    }
    if let running {
      running.stopCapture { _ in finish() }
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
    DispatchQueue.main.async {
      pending(FlutterError(code: code, message: reason,
                           details: underlying?.localizedDescription))
      self.stop()
    }
  }

  func contentSharingPicker(_ picker: SCContentSharingPicker,
                            didUpdateWith filter: SCContentFilter,
                            for changedStream: SCStream?) {
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
    let next = SCStream(filter: filter, configuration: SCStreamConfiguration(),
                        delegate: self)
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
      }
    }
  }

  func contentSharingPicker(_ picker: SCContentSharingPicker,
                            didCancelFor cancelledStream: SCStream?) {
    fail("screen_capture_cancelled", "Screen selection was cancelled.")
  }

  func contentSharingPickerStartDidFailWithError(_ error: Error) {
    fail("screen_capture_failed", "The system screen picker could not open.",
         underlying: error)
  }

  func stream(_ activeStream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
              of type: SCStreamOutputType) {
    guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
          let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    lock.lock()
    let canPublish = !stopped && stream === activeStream
    let first = canPublish && !firstFrameSeen
    if first { firstFrameSeen = true }
    lock.unlock()
    guard canPublish else { return }
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    FlutterRealtimeProcessedVideoFrameHub.publish(
      FlutterRealtimeProcessedVideoFrame(sourceId: id, pixelBuffer: image,
                                         timestamp: timestamp))
    if first {
      let width = CVPixelBufferGetWidth(image)
      let height = CVPixelBufferGetHeight(image)
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
          "frameRate": 30.0,
        ])
      }
    }
  }

  func stream(_ activeStream: SCStream, didStopWithError error: Error) {
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
