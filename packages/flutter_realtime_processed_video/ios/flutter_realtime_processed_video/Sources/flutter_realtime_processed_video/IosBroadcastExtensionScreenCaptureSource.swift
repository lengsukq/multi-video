import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Flutter
import Foundation
import os
import ReplayKit
import UIKit

struct IosBroadcastExtensionConfiguration {
  let configured: Bool
  let hasAppGroup: Bool
  let hasExtension: Bool
  let appGroup: String
  let extensionId: String
  let socketPath: String
}

/// Cross-application ReplayKit Broadcast Upload Extension receiver for iOS 15–26.
///
/// Consumes HTTP-framed JPEG samples streamed over the shared App Group Unix
/// domain socket (`rtc_SSFD`) by `BroadcastExtensionTemplate/SampleHandler.swift`
/// and publishes BGRA `CVPixelBuffer` frames into `FlutterRealtimeProcessedVideoFrameHub`
/// so Chime, IVS, Agora, TRTC, and ARTC can share other iOS apps without
/// duplicating vendor-specific extension targets.
final class IosBroadcastExtensionScreenCaptureSource: NSObject {
  private static let logger = Logger(
    subsystem: "com.oneplusdream.multi_video",
    category: "BroadcastExtensionScreenCapture"
  )
  private static let startedNotification = "iOS_BroadcastStarted" as CFString
  private static let stoppedNotification = "iOS_BroadcastStopped" as CFString
  private static let headerTerminator = Data([13, 10, 13, 10])
  private static let maxHeaderBytes = 4096
  private static let maxFrameBytes = 8 * 1024 * 1024

  private let session: IosScreenCaptureSession
  private let configuration: IosBroadcastExtensionConfiguration
  private let onInvalidated: ((IosBroadcastExtensionScreenCaptureSource) -> Void)?
  private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
  private let socketQueue = DispatchQueue(
    label: "com.oneplusdream.multi_video.broadcast_socket",
    qos: .userInitiated
  )
  private let stateLock = NSLock()

  private var listenFd: Int32 = -1
  private var clientFd: Int32 = -1
  private var broadcastActive = false
  private var observingNotifications = false
  private var pixelBufferPool: CVPixelBufferPool?
  private var poolWidth = 0
  private var poolHeight = 0
  private weak var pickerView: UIView?

  init(
    channel: FlutterMethodChannel,
    configuration: IosBroadcastExtensionConfiguration,
    onInvalidated: ((IosBroadcastExtensionScreenCaptureSource) -> Void)? = nil
  ) {
    self.session = IosScreenCaptureSession(channel: channel)
    self.configuration = configuration
    self.onInvalidated = onInvalidated
    super.init()
  }

  static func hostConfiguration(bundle: Bundle = .main) -> IosBroadcastExtensionConfiguration {
    let customGroup = (bundle.object(forInfoDictionaryKey: "FRSDKAppGroupIdentifier") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let rtcGroup = (bundle.object(forInfoDictionaryKey: "RTCAppGroupIdentifier") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let appGroup = customGroup.isEmpty ? rtcGroup : customGroup

    let customExt = (bundle.object(forInfoDictionaryKey: "FRSDKScreenSharingExtension") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let rtcExt = (bundle.object(forInfoDictionaryKey: "RTCScreenSharingExtension") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let extensionId = customExt.isEmpty ? rtcExt : customExt

    let container = appGroup.isEmpty
      ? nil
      : FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    let socketPath = container?.appendingPathComponent("rtc_SSFD").path ?? ""
    let maxSunPath = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    let validSocketPath = !socketPath.isEmpty && socketPath.utf8.count < maxSunPath

    var installed = false
    if !extensionId.isEmpty, let pluginsURL = bundle.builtInPlugInsURL {
      let entries = (try? FileManager.default.contentsOfDirectory(
        at: pluginsURL,
        includingPropertiesForKeys: nil,
        options: []
      )) ?? []
      for entry in entries {
        if Bundle(url: entry)?.bundleIdentifier == extensionId {
          installed = true
          break
        }
      }
    }

    return IosBroadcastExtensionConfiguration(
      configured: validSocketPath && installed,
      hasAppGroup: container != nil && validSocketPath,
      hasExtension: installed,
      appGroup: appGroup,
      extensionId: extensionId,
      socketPath: socketPath
    )
  }

  func start(_ result: @escaping FlutterResult) {
    guard configuration.configured else {
      result(FlutterError(
        code: "screen_capture_unavailable",
        message: "ReplayKit Broadcast Upload Extension or App Group is not configured.",
        details: nil
      ))
      return
    }
    guard session.beginStart(result) else { return }

    do {
      try openListeningSocket()
    } catch {
      session.fail(
        "screen_capture_failed",
        "Failed to open App Group broadcast socket.",
        underlying: error
      ) {
        self.stop()
      }
      return
    }

    registerDarwinNotifications()
    acceptConnections()

    DispatchQueue.main.async {
      guard !self.session.isStopped else { return }
      if !self.presentSystemBroadcastPicker() {
        self.session.fail(
          "screen_capture_failed",
          "Unable to present the iOS system broadcast picker without an active window."
        ) {
          self.stop()
        }
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
        guard let self else { return }
        self.session.fail(
          "screen_capture_cancelled",
          "Screen broadcast was not started in the iOS picker within 60 seconds."
        ) {
          self.stop()
        }
      }
    }
  }

  func stop(completion done: (() -> Void)? = nil) {
    let loggedStop = session.markStopped()
    if loggedStop {
      Self.logger.info(
        "Stopping Broadcast Extension capture sourceId=\(self.session.id, privacy: .public)"
      )
    }
    unregisterDarwinNotifications()
    closeSockets()
    DispatchQueue.main.async {
      self.pickerView?.removeFromSuperview()
      self.pickerView = nil
      self.session.clearHub()
      self.onInvalidated?(self)
      done?()
    }
  }

  private func openListeningSocket() throws {
    let path = configuration.socketPath
    _ = Darwin.unlink(path)
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    var noSigPipe: Int32 = 1
    _ = Darwin.setsockopt(
      fd,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &noSigPipe,
      socklen_t(MemoryLayout<Int32>.size)
    )

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    let maxBytes = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count <= maxBytes else {
      _ = Darwin.close(fd)
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { sunPtr in
      let rawPtr = UnsafeMutableRawPointer(sunPtr).assumingMemoryBound(to: CChar.self)
      pathBytes.withUnsafeBufferPointer { src in
        if let base = src.baseAddress {
          _ = memcpy(rawPtr, base, src.count)
        }
      }
    }

    let bindStatus = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindStatus == 0, Darwin.listen(fd, 2) == 0 else {
      let code = Int(errno)
      _ = Darwin.close(fd)
      _ = Darwin.unlink(path)
      throw NSError(domain: NSPOSIXErrorDomain, code: code)
    }

    stateLock.lock()
    listenFd = fd
    stateLock.unlock()
  }

  private func closeSockets() {
    stateLock.lock()
    let activeClient = clientFd
    let activeListen = listenFd
    clientFd = -1
    listenFd = -1
    stateLock.unlock()

    if activeClient >= 0 {
      _ = Darwin.shutdown(activeClient, SHUT_RDWR)
      _ = Darwin.close(activeClient)
    }
    if activeListen >= 0 {
      _ = Darwin.shutdown(activeListen, SHUT_RDWR)
      _ = Darwin.close(activeListen)
    }
    if !configuration.socketPath.isEmpty {
      _ = Darwin.unlink(configuration.socketPath)
    }
  }

  private func acceptConnections() {
    socketQueue.async { [weak self] in
      guard let self else { return }
      while !self.session.isStopped {
        self.stateLock.lock()
        let serverFd = self.listenFd
        self.stateLock.unlock()
        guard serverFd >= 0 else { break }

        let accepted = Darwin.accept(serverFd, nil, nil)
        if accepted < 0 {
          if errno == EINTR { continue }
          break
        }
        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(
          accepted,
          SOL_SOCKET,
          SO_NOSIGPIPE,
          &noSigPipe,
          socklen_t(MemoryLayout<Int32>.size)
        )
        self.stateLock.lock()
        let previousClient = self.clientFd
        self.clientFd = accepted
        self.broadcastActive = true
        self.stateLock.unlock()
        if previousClient >= 0 {
          _ = Darwin.shutdown(previousClient, SHUT_RDWR)
          _ = Darwin.close(previousClient)
        }
        self.readClientStream(accepted)
      }
    }
  }

  private func readClientStream(_ fd: Int32) {
    var buffer = Data()
    var scratch = [UInt8](repeating: 0, count: 32768)

    while !session.isStopped {
      let count = scratch.withUnsafeMutableBytes { rawPtr -> Int in
        guard let base = rawPtr.baseAddress else { return -1 }
        return Darwin.read(fd, base, rawPtr.count)
      }
      if count <= 0 {
        break
      }
      buffer.append(scratch, count: count)
      if buffer.count > Self.maxFrameBytes + Self.maxHeaderBytes {
        Self.logger.warning("Dropping oversized broadcast socket buffer")
        buffer.removeAll(keepingCapacity: true)
        continue
      }
      consumeFrames(from: &buffer)
    }

    stateLock.lock()
    if clientFd == fd {
      clientFd = -1
    }
    let wasActive = broadcastActive
    stateLock.unlock()
    _ = Darwin.close(fd)

    if !session.isStopped && wasActive {
      handleRemoteBroadcastStopped()
    }
  }

  private func consumeFrames(from buffer: inout Data) {
    while true {
      guard let headerRange = buffer.range(of: Self.headerTerminator) else {
        if buffer.count > Self.maxHeaderBytes {
          buffer.removeAll(keepingCapacity: true)
        }
        return
      }
      let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
      guard let headerText = String(data: headerData, encoding: .utf8) else {
        buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
        continue
      }

      var contentLength: Int?
      var orientation: UInt32 = 0
      for line in headerText.split(whereSeparator: \.isNewline) {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if key == "content-length" {
          contentLength = Int(value)
        } else if key == "buffer-orientation", let parsed = UInt32(value) {
          orientation = parsed
        }
      }

      guard let bodyLength = contentLength,
            bodyLength > 0,
            bodyLength <= Self.maxFrameBytes else {
        buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
        continue
      }
      let messageEnd = headerRange.upperBound + bodyLength
      guard buffer.count >= messageEnd else {
        return
      }
      let jpegData = buffer.subdata(in: headerRange.upperBound..<messageEnd)
      buffer.removeSubrange(buffer.startIndex..<messageEnd)
      publishEncodedFrame(jpegData, orientation: orientation)
    }
  }

  private func publishEncodedFrame(_ jpegData: Data, orientation: UInt32) {
    let ptsSeconds = ProcessInfo.processInfo.systemUptime
    let decision = session.acceptFrame(ptsSeconds: ptsSeconds)
    guard decision.accepted else { return }

    guard var image = CIImage(data: jpegData) else { return }
    if orientation >= 1 && orientation <= 8 {
      image = image.oriented(forExifOrientation: Int32(orientation))
    }
    let extent = image.extent
    if extent.origin.x != 0 || extent.origin.y != 0 {
      image = image.transformed(
        by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
      )
    }
    let rawW = image.extent.width
    let rawH = image.extent.height
    let (targetW, targetH) = IosScreenCaptureSession.boundedDimensions(
      width: rawW,
      height: rawH
    )
    if rawW > 0, rawH > 0, (Int(rawW.rounded()) != targetW || Int(rawH.rounded()) != targetH) {
      image = image.transformed(
        by: CGAffineTransform(
          scaleX: CGFloat(targetW) / rawW,
          y: CGFloat(targetH) / rawH
        )
      )
    }
    guard let pool = ensurePixelBufferPool(width: targetW, height: targetH) else { return }
    var output: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
          let destination = output else {
      return
    }
    ciContext.render(
      image,
      to: destination,
      bounds: CGRect(x: 0, y: 0, width: targetW, height: targetH),
      colorSpace: CGColorSpaceCreateDeviceRGB()
    )

    let timestamp = CMTime(seconds: ptsSeconds, preferredTimescale: 1_000_000_000)
    FlutterRealtimeProcessedVideoFrameHub.publish(
      FlutterRealtimeProcessedVideoFrame(
        sourceId: session.id,
        pixelBuffer: destination,
        timestamp: timestamp
      )
    )
    if decision.isFirst {
      Self.logger.info(
        "First Broadcast Extension screen frame \(targetW)x\(targetH)"
      )
      session.completeFirstFrame(width: targetW, height: targetH)
    }
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

  private func presentSystemBroadcastPicker() -> Bool {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
      ?? scenes.flatMap(\.windows).first
    guard let hostWindow = window else { return false }

    let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    picker.preferredExtension = configuration.extensionId
    picker.showsMicrophoneButton = false
    picker.alpha = 0.01
    picker.isUserInteractionEnabled = false
    hostWindow.addSubview(picker)
    pickerView = picker

    var triggered = false
    for subview in picker.subviews {
      if let button = subview as? UIButton {
        button.sendActions(for: .allTouchEvents)
        triggered = true
      }
    }
    if !triggered {
      for subview in picker.subviews {
        for nested in subview.subviews {
          if let button = nested as? UIButton {
            button.sendActions(for: .allTouchEvents)
            triggered = true
          }
        }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak picker] in
      picker?.removeFromSuperview()
    }
    return triggered
  }

  private func registerDarwinNotifications() {
    stateLock.lock()
    guard !observingNotifications else {
      stateLock.unlock()
      return
    }
    observingNotifications = true
    stateLock.unlock()

    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let observer = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterAddObserver(
      center,
      observer,
      { _, observer, _, _, _ in
        guard let observer else { return }
        let instance = Unmanaged<IosBroadcastExtensionScreenCaptureSource>
          .fromOpaque(observer)
          .takeUnretainedValue()
        instance.handleRemoteBroadcastStarted()
      },
      Self.startedNotification,
      nil,
      .deliverImmediately
    )
    CFNotificationCenterAddObserver(
      center,
      observer,
      { _, observer, _, _, _ in
        guard let observer else { return }
        let instance = Unmanaged<IosBroadcastExtensionScreenCaptureSource>
          .fromOpaque(observer)
          .takeUnretainedValue()
        instance.handleRemoteBroadcastStopped()
      },
      Self.stoppedNotification,
      nil,
      .deliverImmediately
    )
  }

  private func unregisterDarwinNotifications() {
    stateLock.lock()
    let wasObserving = observingNotifications
    observingNotifications = false
    stateLock.unlock()
    guard wasObserving else { return }

    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let observer = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(Self.startedNotification), nil)
    CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(Self.stoppedNotification), nil)
  }

  private func handleRemoteBroadcastStarted() {
    stateLock.lock()
    broadcastActive = true
    stateLock.unlock()
  }

  private func handleRemoteBroadcastStopped() {
    guard !session.isStopped else { return }
    if session.hasPendingStart {
      session.fail(
        "screen_capture_cancelled",
        "Screen broadcast stopped before its first frame."
      ) {
        self.stop()
      }
    } else if session.isActiveAndRunning {
      DispatchQueue.main.async {
        self.session.emitEnded(message: "Screen broadcast was stopped by the system.")
        self.stop()
      }
    }
  }
}
