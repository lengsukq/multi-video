import CoreImage
import CoreMedia
import CoreVideo
import Flutter
import Foundation
import os
import ReplayKit

/// ReplayKit in-app screen capture fallback for iOS versions below iOS 27.
///
/// Publishes BGRA CVPixelBuffers into `FlutterRealtimeProcessedVideoFrameHub`
/// using the same source metadata contract as `IosSystemScreenCaptureKitSource`.
final class IosReplayKitScreenCaptureSource: NSObject, RPScreenRecorderDelegate {
  private static let logger = Logger(
    subsystem: "com.oneplusdream.multi_video",
    category: "ReplayKitScreenCapture"
  )

  private let session: IosScreenCaptureSession
  private let onInvalidated: ((IosReplayKitScreenCaptureSource) -> Void)?
  private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
  private var pixelBufferPool: CVPixelBufferPool?
  private var poolWidth = 0
  private var poolHeight = 0
  private var capturing = false

  init(
    channel: FlutterMethodChannel,
    onInvalidated: ((IosReplayKitScreenCaptureSource) -> Void)? = nil
  ) {
    self.session = IosScreenCaptureSession(channel: channel)
    self.onInvalidated = onInvalidated
    super.init()
  }

  static var available: Bool { RPScreenRecorder.shared().isAvailable }

  func start(_ result: @escaping FlutterResult) {
    guard Self.available else {
      result(FlutterError(
        code: "screen_capture_unavailable",
        message: "ReplayKit screen capture is unavailable on this device.",
        details: nil
      ))
      return
    }
    guard session.beginStart(result) else { return }

    DispatchQueue.main.async {
      guard !self.session.isStopped else { return }
      let recorder = RPScreenRecorder.shared()
      recorder.isMicrophoneEnabled = false
      recorder.isCameraEnabled = false
      recorder.delegate = self
      self.capturing = true
      Self.logger.info("Starting ReplayKit screen capture sourceId=\(self.session.id, privacy: .public)")

      recorder.startCapture(
        handler: { [weak self] sampleBuffer, sampleType, error in
          self?.handleSampleBuffer(sampleBuffer, sampleType: sampleType, error: error)
        },
        completionHandler: { [weak self] error in
          guard let self else { return }
          if let error {
            let nsError = error as NSError
            let code = (nsError.domain == RPRecordingErrorDomain &&
              nsError.code == RPRecordingErrorCode.userDeclined.rawValue)
              ? "screen_capture_cancelled"
              : "screen_capture_failed"
            let message = code == "screen_capture_cancelled"
              ? "Screen capture permission was declined."
              : "ReplayKit screen capture could not start."
            self.session.fail(code, message, underlying: error) {
              self.stop()
            }
          }
        }
      )

      DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
        guard let self else { return }
        self.session.fail(
          "screen_capture_timeout",
          "No ReplayKit screen frames arrived in 60 seconds."
        ) {
          self.stop()
        }
      }
    }
  }

  func stop(completion done: (() -> Void)? = nil) {
    let loggedStop = session.markStopped()
    if loggedStop {
      Self.logger.info("Stopping ReplayKit capture sourceId=\(self.session.id, privacy: .public)")
    }
    let finish = {
      self.session.clearHub()
      self.onInvalidated?(self)
      done?()
    }
    DispatchQueue.main.async {
      let recorder = RPScreenRecorder.shared()
      if recorder.delegate === self {
        recorder.delegate = nil
      }
      let wasCapturing = self.capturing
      self.capturing = false
      if wasCapturing && recorder.isRecording {
        recorder.stopCapture { error in
          if let error {
            Self.logger.warning("ReplayKit stopCapture error: \(error.localizedDescription, privacy: .public)")
          }
          finish()
        }
      } else {
        finish()
      }
    }
  }

  func screenRecorder(
    _ screenRecorder: RPScreenRecorder,
    didStopRecordingWith previewViewController: RPPreviewViewController?,
    error: Error?
  ) {
    if session.hasPendingStart {
      session.fail(
        "screen_capture_failed",
        "ReplayKit screen capture stopped before its first frame.",
        underlying: error
      ) {
        self.stop()
      }
    } else if session.isActiveAndRunning {
      DispatchQueue.main.async {
        self.session.emitEnded(
          message: error?.localizedDescription ?? "Screen sharing was stopped by the system."
        )
        self.stop()
      }
    }
  }

  private func handleSampleBuffer(
    _ sampleBuffer: CMSampleBuffer,
    sampleType: RPSampleBufferType,
    error: Error?
  ) {
    if let error {
      Self.logger.warning("ReplayKit sample error: \(error.localizedDescription, privacy: .public)")
      return
    }
    guard sampleType == .video,
          CMSampleBufferIsValid(sampleBuffer),
          let rawBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let ptsSeconds = timestamp.isValid && timestamp.isNumeric ? timestamp.seconds : .nan
    let decision = session.acceptFrame(ptsSeconds: ptsSeconds)
    guard decision.accepted else { return }

    guard let bgraBuffer = convertToBgraIfNeeded(rawBuffer) else { return }
    FlutterRealtimeProcessedVideoFrameHub.publish(
      FlutterRealtimeProcessedVideoFrame(
        sourceId: session.id,
        pixelBuffer: bgraBuffer,
        timestamp: timestamp
      )
    )
    if decision.isFirst {
      let width = CVPixelBufferGetWidth(bgraBuffer)
      let height = CVPixelBufferGetHeight(bgraBuffer)
      Self.logger.info("First ReplayKit screen frame \(width)x\(height)")
      session.completeFirstFrame(width: width, height: height)
    }
  }

  private func convertToBgraIfNeeded(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
    let (targetW, targetH) = IosScreenCaptureSession.boundedDimensions(
      width: CGFloat(width),
      height: CGFloat(height)
    )
    if format == kCVPixelFormatType_32BGRA && targetW == width && targetH == height {
      return pixelBuffer
    }
    guard let pool = ensurePixelBufferPool(width: targetW, height: targetH) else {
      return nil
    }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var output: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
          let destination = output else {
      return nil
    }
    var image = CIImage(cvPixelBuffer: pixelBuffer)
    if targetW != width || targetH != height {
      let scaleX = CGFloat(targetW) / CGFloat(width)
      let scaleY = CGFloat(targetH) / CGFloat(height)
      image = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }
    ciContext.render(
      image,
      to: destination,
      bounds: CGRect(x: 0, y: 0, width: targetW, height: targetH),
      colorSpace: colorSpace
    )
    return destination
  }

  private func ensurePixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
    if let pool = pixelBufferPool, poolWidth == width, poolHeight == height {
      return pool
    }
    var created: CVPixelBufferPool?
    let attrs: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    guard CVPixelBufferPoolCreate(
      kCFAllocatorDefault,
      nil,
      attrs as CFDictionary,
      &created
    ) == kCVReturnSuccess else {
      return nil
    }
    pixelBufferPool = created
    poolWidth = width
    poolHeight = height
    return created
  }
}
