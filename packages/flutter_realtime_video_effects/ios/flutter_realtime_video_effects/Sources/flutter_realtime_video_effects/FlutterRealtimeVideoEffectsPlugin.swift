import AVFoundation
import UIKit
import CoreImage
import CoreVideo
import Flutter
import Vision
import flutter_realtime_processed_video

private final class IOSVideoEffectsSource: NSObject,
  AVCaptureVideoDataOutputSampleBufferDelegate,
  FlutterTexture
{
  let sourceId: String
  let requestedWidth: Int
  let requestedHeight: Int
  let frameRate: Int
  let textureRegistry: FlutterTextureRegistry
  var textureId: Int64 = 0

  private let session = AVCaptureSession()
  private let captureQueue = DispatchQueue(
    label: "flutter_realtime_video_effects.capture"
  )
  private let frameLock = NSLock()
  private let ciContext = CIContext(options: [.cacheIntermediates: false])
  private let sequenceHandler = VNSequenceRequestHandler()
  private let segmentationRequest: VNGeneratePersonSegmentationRequest = {
    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .balanced
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    return request
  }()

  private var currentPixelBuffer: CVPixelBuffer?
  private var outputPixelBufferPool: CVPixelBufferPool?
  private var outputPoolSize = CGSize.zero
  private var currentInput: AVCaptureDeviceInput?
  private var videoOutput: AVCaptureVideoDataOutput?
  private var cameraDeviceId: String?
  private var effectType: String
  private var blurStrength: String
  private var replacementImage: CIImage?
  private var enabled = true
  private var processingFailed = false
  private var disposed = false
  var onFailure: ((Error) -> Void)?

  init(
    sourceId: String,
    width: Int,
    height: Int,
    frameRate: Int,
    cameraDeviceId: String?,
    effectType: String,
    blurStrength: String,
    backgroundImageData: Data?,
    textureRegistry: FlutterTextureRegistry
  ) throws {
    self.sourceId = sourceId
    requestedWidth = width
    requestedHeight = height
    self.frameRate = frameRate
    self.cameraDeviceId = cameraDeviceId
    self.effectType = "none"
    self.blurStrength = "medium"
    replacementImage = nil
    self.textureRegistry = textureRegistry
    super.init()
    try setEffect(
      type: effectType,
      strength: blurStrength,
      imageData: backgroundImageData
    )
  }

  private func configureVideoOrientation() {
    // Changing front/back inputs may replace the AVCaptureConnection. Keep
    // the frame orientation matching the portrait texture dimensions exposed
    // by createSource, otherwise the iOS preview becomes squashed.
    guard let connection = videoOutput?.connection(with: .video) else { return }
    if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
    if connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = false
    }
  }

  func start(completion: @escaping (Error?) -> Void) {
    let beginCapture = { [weak self] in
      guard let self else { return }
      captureQueue.async {
        do {
          guard !self.disposed else { throw VideoEffectsError.sourceDisposed }
          try self.configureCapture()
          self.session.startRunning()
          DispatchQueue.main.async { completion(nil) }
        } catch {
          DispatchQueue.main.async { completion(error) }
        }
      }
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      beginCapture()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        if granted {
          beginCapture()
        } else {
          DispatchQueue.main.async { completion(VideoEffectsError.cameraPermissionDenied) }
        }
      }
    default:
      completion(VideoEffectsError.cameraPermissionDenied)
    }
  }

  func setEffect(
    type: String,
    strength: String,
    imageData: Data? = nil
  ) throws {
    guard type == "none" || type == "blur" || type == "replaceImage" else {
      throw VideoEffectsError.unsupportedEffect(type)
    }
    let wasEnabled = captureQueue.sync { () -> Bool in
      let previous = enabled
      if type != "none" { enabled = false }
      return previous
    }
    let nextImage: CIImage?
    if type == "replaceImage" {
      guard
        let imageData,
        let image = Self.decodeBackgroundImage(imageData)
      else {
        captureQueue.sync { processingFailed = true }
        clearPreviewFrame()
        throw VideoEffectsError.invalidBackgroundImage
      }
      nextImage = image
    } else {
      nextImage = nil
    }
    captureQueue.sync {
      replacementImage = nextImage
      effectType = type
      blurStrength = strength
      processingFailed = false
      enabled = wasEnabled
    }
  }

  func setEnabled(_ enabled: Bool) throws {
    try captureQueue.sync {
      if enabled && processingFailed { throw VideoEffectsError.processingFailed }
      self.enabled = enabled
      if enabled, videoOutput != nil, !session.isRunning { session.startRunning() }
      if !enabled, session.isRunning { session.stopRunning() }
    }
    if !enabled { clearPreviewFrame() }
  }

  func selectCamera(_ deviceId: String?) throws {
    try captureQueue.sync {
      let previousId = cameraDeviceId
      cameraDeviceId = deviceId
      do { try replaceCameraInput() } catch {
        cameraDeviceId = previousId
        throw error
      }
    }
  }

  private func configureCapture() throws {
    session.beginConfiguration()
    defer {
      session.commitConfiguration()
      configureVideoOrientation()
      configureFrameRate()
    }
    session.sessionPreset = requestedWidth >= 1280 ? .hd1280x720 : .vga640x480
    try addCameraInput()
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String:
        kCVPixelFormatType_32BGRA
    ]
    output.setSampleBufferDelegate(self, queue: captureQueue)
    guard session.canAddOutput(output) else {
      throw VideoEffectsError.captureConfigurationFailed
    }
    session.addOutput(output)
    videoOutput = output
  }

  private func replaceCameraInput() throws {
    session.beginConfiguration()
    defer {
      session.commitConfiguration()
      configureVideoOrientation()
      configureFrameRate()
    }
    let previous = currentInput
    if let previous { session.removeInput(previous) }
    currentInput = nil
    do { try addCameraInput() } catch {
      if let previous, session.canAddInput(previous) { session.addInput(previous); currentInput = previous }
      throw error
    }
  }

  private func addCameraInput() throws {
    let device = selectedCamera()
    guard let device else { throw VideoEffectsError.cameraUnavailable }
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
      throw VideoEffectsError.captureConfigurationFailed
    }
    session.addInput(input)
    currentInput = input
  }

  private func configureFrameRate() {
    // Session presets/input changes can reset the duration. Tune the format
    // that is actually active after committing the capture configuration.
    guard let device = currentInput?.device else { return }
    do {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      let duration = CMTime(
        value: 1,
        timescale: CMTimeScale(max(1, frameRate))
      )
      if device.activeFormat.videoSupportedFrameRateRanges.contains(
        where: {
          Double(frameRate) >= $0.minFrameRate &&
            Double(frameRate) <= $0.maxFrameRate
        }
      ) {
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
      }
    } catch {
      // Frame-rate tuning is best effort.
    }
  }

  private func selectedCamera() -> AVCaptureDevice? {
    let devices = FlutterRealtimeVideoEffectsPlugin.availableCameras()
    if cameraDeviceId == "front" {
      return devices.first(where: { $0.position == .front })
    }
    if cameraDeviceId == "back" {
      return devices.first(where: { $0.position == .back })
    }
    if let cameraDeviceId {
      return devices.first(where: { $0.uniqueID == cameraDeviceId })
    }
    return devices.first(where: { $0.position == .front }) ?? devices.first
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard enabled,
          !disposed,
          let inputBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
    else { return }

    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if effectType == "none" {
      // Flutter and provider sinks retain the camera buffer for their lifetime.
      // Raw preview needs no Core Image render or second pixel-buffer allocation.
      publishFrame(inputBuffer, timestamp: timestamp)
      return
    }
    let original = CIImage(cvPixelBuffer: inputBuffer)
    let processed: CIImage

    if effectType == "blur" || effectType == "replaceImage" {
      let background: CIImage
      if effectType == "replaceImage",
         let image = replacementImage
      {
        background = fitBackground(image, to: original.extent)
      } else {
        background = original
        .clampedToExtent()
        .applyingFilter(
          "CIGaussianBlur",
          parameters: [kCIInputRadiusKey: blurRadius()]
        )
        .cropped(to: original.extent)
      }
      do {
        try sequenceHandler.perform([segmentationRequest], on: inputBuffer)
        if let observation =
          segmentationRequest.results?.first as? VNPixelBufferObservation
        {
          let rawMask = CIImage(cvPixelBuffer: observation.pixelBuffer)
          let scaleX = original.extent.width / rawMask.extent.width
          let scaleY = original.extent.height / rawMask.extent.height
          let scaledMask = rawMask.transformed(
            by: CGAffineTransform(scaleX: scaleX, y: scaleY)
          )
          let mask = refineForegroundMask(scaledMask, to: original.extent)
          processed = original.applyingFilter(
            "CIBlendWithMask",
            parameters: [
              kCIInputBackgroundImageKey: background,
              kCIInputMaskImageKey: mask,
            ]
          )
        } else {
          // A missing segmentation mask is a processing failure. Do not send
          // an unsegmented or all-background frame to a remote publisher.
          enabled = false
          processingFailed = true
          clearPreviewFrame()
          captureQueue.async { [weak self] in self?.session.stopRunning() }
          onFailure?(VideoEffectsError.processingFailed)
          return
        }
      } catch {
        enabled = false
        processingFailed = true
        clearPreviewFrame()
        captureQueue.async { [weak self] in self?.session.stopRunning() }
        onFailure?(error)
        return
      }
    } else {
      processed = original
    }

    guard let outputBuffer = makeOutputPixelBuffer(
      width: CVPixelBufferGetWidth(inputBuffer),
      height: CVPixelBufferGetHeight(inputBuffer)
    ) else {
      enabled = false; processingFailed = true; clearPreviewFrame()
      captureQueue.async { [weak self] in self?.session.stopRunning() }
      onFailure?(VideoEffectsError.outputAllocationFailed)
      return
    }
    ciContext.render(processed, to: outputBuffer)
    publishFrame(outputBuffer, timestamp: timestamp)
  }

  private func publishFrame(_ buffer: CVPixelBuffer, timestamp: CMTime) {
    frameLock.lock()
    currentPixelBuffer = buffer
    frameLock.unlock()

    if textureId != 0 {
      let id = textureId
      DispatchQueue.main.async { [textureRegistry] in textureRegistry.textureFrameAvailable(id) }
    }
    FlutterRealtimeProcessedVideoFrameHub.publish(
      FlutterRealtimeProcessedVideoFrame(
        sourceId: sourceId,
        pixelBuffer: buffer,
        timestamp: timestamp
      )
    )
  }

  private func blurRadius() -> Double {
    switch blurStrength {
    case "low": return 8
    case "high": return 24
    default: return 16
    }
  }

  private func refineForegroundMask(_ mask: CIImage, to extent: CGRect) -> CIImage {
    // Give uncertain hair/shoulder pixels more foreground weight. A small
    // expansion protects the subject from the background blur; the final
    // subpixel feather prevents a visible hard silhouette.
    let low = 0.06
    let scale = 1.0 / (0.74 - low)
    return mask
      .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 2.0])
      .applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: scale, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: scale, y: 0, z: 0, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: -low * scale, y: -low * scale, z: -low * scale, w: 0)
      ])
      .applyingFilter("CIColorClamp", parameters: [
        "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
      ])
      .clampedToExtent()
      .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.8])
      .cropped(to: extent)
  }

  private func fitBackground(
    _ image: CIImage,
    to target: CGRect
  ) -> CIImage {
    let source = image.extent
    guard source.width > 0, source.height > 0 else {
      return CIImage(color: .black).cropped(to: target)
    }
    let scale = max(
      target.width / source.width,
      target.height / source.height
    )
    let scaled = image.transformed(
      by: CGAffineTransform(scaleX: scale, y: scale)
    )
    let translated = scaled.transformed(
      by: CGAffineTransform(
        translationX: target.midX - scaled.extent.midX,
        y: target.midY - scaled.extent.midY
      )
    )
    return translated.cropped(to: target)
  }

  private static func decodeBackgroundImage(_ data: Data) -> CIImage? {
    guard data.count <= 16 * 1024 * 1024, let image = UIImage(data: data) else { return nil }
    guard let cgImage = image.cgImage,
      cgImage.width > 0, cgImage.height > 0,
       cgImage.width <= 4096, cgImage.height <= 4096 else { return nil }
    return CIImage(cgImage: cgImage)
  }

  private func makeOutputPixelBuffer(
    width: Int,
    height: Int
  ) -> CVPixelBuffer? {
    let size = CGSize(width: width, height: height)
    if outputPixelBufferPool == nil || outputPoolSize != size {
      let attributes: [CFString: Any] = [
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:],
      ]
      var pool: CVPixelBufferPool?
      guard CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
        attributes as CFDictionary,
        &pool
      ) == kCVReturnSuccess else { return nil }
      outputPixelBufferPool = pool
      outputPoolSize = size
    }
    guard let pool = outputPixelBufferPool else { return nil }
    var buffer: CVPixelBuffer?
    // Buffers return to the pool after Flutter and all provider sinks release
    // them; never overwrite a buffer that is still being displayed or encoded.
    let status = CVPixelBufferPoolCreatePixelBuffer(
      kCFAllocatorDefault,
      pool,
      &buffer
    )
    return status == kCVReturnSuccess ? buffer : nil
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    frameLock.lock()
    defer { frameLock.unlock() }
    guard let currentPixelBuffer else { return nil }
    return Unmanaged.passRetained(currentPixelBuffer)
  }

  private func clearPreviewFrame() {
    frameLock.lock(); currentPixelBuffer = nil; frameLock.unlock()
    if textureId != 0 {
      let id = textureId
      DispatchQueue.main.async { [textureRegistry] in textureRegistry.textureFrameAvailable(id) }
    }
  }

  func dispose() {
    guard !disposed else { return }
    captureQueue.sync {
      disposed = true
      replacementImage = nil
      outputPixelBufferPool = nil
      FlutterRealtimeProcessedVideoFrameHub.clear(sourceId)
      videoOutput?.setSampleBufferDelegate(nil, queue: nil)
      if session.isRunning { session.stopRunning() }
      session.inputs.forEach(session.removeInput)
      session.outputs.forEach(session.removeOutput)
    }
    frameLock.lock()
    currentPixelBuffer = nil
    frameLock.unlock()
    if textureId != 0 {
      let id = textureId
      textureId = 0
      DispatchQueue.main.async { [textureRegistry] in
        textureRegistry.unregisterTexture(id)
      }
    }
  }
}

private enum VideoEffectsError: LocalizedError {
  case cameraPermissionDenied
  case cameraUnavailable
  case captureConfigurationFailed
  case invalidBackgroundImage
  case processingFailed
  case sourceDisposed
  case outputAllocationFailed
  case unsupportedEffect(String)

  var errorDescription: String? {
    switch self {
    case .cameraPermissionDenied:
      return "Camera permission was denied."
    case .cameraUnavailable:
      return "No camera is available."
    case .captureConfigurationFailed:
      return "Unable to configure the camera capture session."
    case .invalidBackgroundImage:
      return "The selected background image could not be decoded."
    case .processingFailed:
      return "Background processing failed. Configure the effect again before enabling the camera."
    case .sourceDisposed:
      return "The camera source was disposed before capture could start."
    case .outputAllocationFailed:
      return "The processed video frame could not be allocated."
    case .unsupportedEffect(let effect):
      return "Unsupported background effect: \(effect)"
    }
  }
}

public class FlutterRealtimeVideoEffectsPlugin: NSObject, FlutterPlugin {
  private let textureRegistry: FlutterTextureRegistry
  private var methodChannel: FlutterMethodChannel?
  private var sources: [String: IOSVideoEffectsSource] = [:]

  private init(textureRegistry: FlutterTextureRegistry) {
    self.textureRegistry = textureRegistry
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "flutter_realtime_video_effects",
      binaryMessenger: registrar.messenger()
    )
    let instance = FlutterRealtimeVideoEffectsPlugin(
      textureRegistry: registrar.textures()
    )
    instance.methodChannel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "isSupported":
      result(!Self.availableCameras().isEmpty)
    case "createSource":
      createSource(call, result: result)
    case "setEffect":
      withSource(call, result: result) { source, args in
        let effect = args["effect"] as? [String: Any] ?? [:]
        try source.setEffect(
          type: effect["type"] as? String ?? "none",
          strength: effect["blurStrength"] as? String ?? "medium",
          imageData: Self.effectImageData(effect["imageBytes"])
        )
      }
    case "setEnabled":
      withSource(call, result: result) { source, args in
        try source.setEnabled(args["enabled"] as? Bool ?? false)
      }
    case "selectCamera":
      withSource(call, result: result) { source, args in
        try source.selectCamera(args["deviceId"] as? String)
      }
    case "listCameras":
      result(
        Self.availableCameras().map { device in
          [
            "id": device.uniqueID,
            "label": device.localizedName,
            "isFrontFacing": device.position == .front,
          ] as [String: Any]
        }
      )
    case "disposeSource":
      let args = call.arguments as? [String: Any] ?? [:]
      let sourceId = args["sourceId"] as? String ?? ""
      sources.removeValue(forKey: sourceId)?.dispose()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func createSource(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    let args = call.arguments as? [String: Any] ?? [:]
    let effect = args["effect"] as? [String: Any] ?? [:]
    let sourceId = UUID().uuidString
    let width = args["width"] as? Int ?? 1280
    let height = args["height"] as? Int ?? 720
    let frameRate = args["frameRate"] as? Int ?? 24
    guard (1...4096).contains(width), (1...4096).contains(height), (1...60).contains(frameRate) else {
      result(FlutterError(code: "invalid_argument", message: "Video size or frame rate is invalid.", details: nil))
      return
    }
    let source: IOSVideoEffectsSource
    do {
      source = try IOSVideoEffectsSource(
        sourceId: sourceId,
        width: args["width"] as? Int ?? 1280,
        height: args["height"] as? Int ?? 720,
        frameRate: args["frameRate"] as? Int ?? 24,
        cameraDeviceId: args["cameraDeviceId"] as? String,
        effectType: effect["type"] as? String ?? "none",
        blurStrength: effect["blurStrength"] as? String ?? "medium",
        backgroundImageData: Self.effectImageData(effect["imageBytes"]),
        textureRegistry: textureRegistry
      )
    } catch {
      result(
        FlutterError(
          code: "invalid_effect",
          message: error.localizedDescription,
          details: nil
        )
      )
      return
    }
    source.onFailure = { [weak self] error in
      DispatchQueue.main.async {
        self?.methodChannel?.invokeMethod("sourceError", arguments: ["sourceId": sourceId, "message": error.localizedDescription])
      }
    }
    let textureId = textureRegistry.register(source)
    source.textureId = textureId
    sources[sourceId] = source
    FlutterRealtimeProcessedVideoFrameHub.activate(sourceId)
    FlutterRealtimeProcessedVideoFrameHub.registerControl(sourceId,
      enable: { [weak source] enabled in try source?.setEnabled(enabled) },
      camera: { [weak source] id in try source?.selectCamera(id) },
      failure: { [weak source] message in
        DispatchQueue.main.async { try? source?.setEnabled(false); source?.onFailure?(NSError(domain: "processed.source", code: -1, userInfo: [NSLocalizedDescriptionKey: message])) }
      })
    source.start { [weak self] error in
      if let error {
        self?.sources.removeValue(forKey: sourceId)
        source.dispose()
        result(
          FlutterError(
            code: "create_source_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
        return
      }
      result([
        "id": sourceId,
        "platform": "ios",
        "kind": "nativeFrameHub",
        // The iOS capture connection emits portrait buffers. Expose the
        // preview dimensions in the same orientation as the actual pixels.
        "width": args["height"] as? Int ?? 720,
        "height": args["width"] as? Int ?? 1280,
        "frameRate": args["frameRate"] as? Int ?? 24,
        "previewTextureId": textureId,
      ])
    }
  }

  private func withSource(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult,
    operation: (
      IOSVideoEffectsSource,
      [String: Any]
    ) throws -> Void
  ) {
    let args = call.arguments as? [String: Any] ?? [:]
    let sourceId = args["sourceId"] as? String ?? ""
    guard let source = sources[sourceId] else {
      result(
        FlutterError(
          code: "source_not_found",
          message: "Unknown video source: \(sourceId)",
          details: nil
        )
      )
      return
    }
    do {
      try operation(source, args)
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "source_operation_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  deinit {
    sources.values.forEach { $0.dispose() }
  }

  static func availableCameras() -> [AVCaptureDevice] {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [
        .builtInWideAngleCamera,
        .builtInDualCamera,
        .builtInTrueDepthCamera,
      ],
      mediaType: .video,
      position: .unspecified
    )
    return discovery.devices
  }

  private static func effectImageData(_ value: Any?) -> Data? {
    if let typed = value as? FlutterStandardTypedData {
      return typed.data
    }
    if let numbers = value as? [NSNumber] {
      return Data(numbers.map { UInt8(clamping: $0.intValue) })
    }
    if let ints = value as? [Int] {
      return Data(ints.map { UInt8(clamping: $0) })
    }
    return nil
  }
}
