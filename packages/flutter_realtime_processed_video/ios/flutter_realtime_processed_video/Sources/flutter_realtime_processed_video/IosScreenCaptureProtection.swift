import Flutter
import Foundation
import UIKit

/// Observes system screen recording, AirPlay mirroring, QuickTime capture, and
/// scene capture state while excluding in-app room screen-sharing sessions.
final class IosScreenCaptureProtection: NSObject {
  private let channel: FlutterMethodChannel
  private let isOwnCaptureActive: () -> Bool
  private var enabled = false
  private var lastReportedCaptured = false
  private var notificationTokens: [NSObjectProtocol] = []
  private var traitRegistrations: [Any] = []

  init(
    channel: FlutterMethodChannel,
    isOwnCaptureActive: @escaping () -> Bool
  ) {
    self.channel = channel
    self.isOwnCaptureActive = isOwnCaptureActive
    super.init()
  }

  deinit {
    let tokens = notificationTokens
    let registrations = traitRegistrations
    let center = NotificationCenter.default
    for token in tokens {
      center.removeObserver(token)
    }
    if #available(iOS 17.0, *), !registrations.isEmpty {
      let releaseTraits = {
        MainActor.assumeIsolated {
          Self.unregister(traitRegistrations: registrations)
        }
      }
      if Thread.isMainThread {
        releaseTraits()
      } else {
        DispatchQueue.main.async(execute: releaseTraits)
      }
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "setProtectionEnabled":
      let nextEnabled = args["enabled"] as? Bool ?? false
      onMain {
        self.setEnabled(nextEnabled)
        result(self.lastReportedCaptured)
      }
    case "isExternalScreenCaptured":
      onMain {
        result(self.computeExternalCaptured())
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func notifyOwnCaptureChanged() {
    onMain {
      guard self.enabled else { return }
      self.evaluateAndEmitIfNeeded()
    }
  }

  private func setEnabled(_ nextEnabled: Bool) {
    if nextEnabled == enabled {
      if enabled {
        evaluateAndEmitIfNeeded()
      }
      return
    }
    enabled = nextEnabled
    if nextEnabled {
      startObserving()
      let current = computeExternalCaptured()
      lastReportedCaptured = current
      if current {
        emit(current)
      }
    } else {
      stopObserving()
      lastReportedCaptured = false
    }
  }

  private func startObserving() {
    stopObserving()
    let center = NotificationCenter.default
    let names: [Notification.Name] = [
      UIScreen.capturedDidChangeNotification,
      UIApplication.didBecomeActiveNotification,
      UIScene.didActivateNotification,
      UIScene.willEnterForegroundNotification,
      UIWindow.didBecomeVisibleNotification,
    ]
    for name in names {
      let token = center.addObserver(
        forName: name,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        guard let self, self.enabled else { return }
        if name == UIWindow.didBecomeVisibleNotification ||
          name == UIScene.didActivateNotification {
          self.registerSceneTraitObserversIfAvailable()
        }
        self.evaluateAndEmitIfNeeded()
      }
      notificationTokens.append(token)
    }
    registerSceneTraitObserversIfAvailable()
  }

  private func registerSceneTraitObserversIfAvailable() {
    if #available(iOS 17.0, *) {
      MainActor.assumeIsolated {
        unregisterSceneTraitObservers()
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
          for window in scene.windows {
            let registration = window.registerForTraitChanges(
              [UITraitSceneCaptureState.self]
            ) { [weak self] (_: UIWindow, _: UITraitCollection) in
              guard let self, self.enabled else { return }
              self.evaluateAndEmitIfNeeded()
            }
            traitRegistrations.append((window, registration))
          }
        }
      }
    }
  }

  private func unregisterSceneTraitObservers() {
    if #available(iOS 17.0, *) {
      let registrations = traitRegistrations
      MainActor.assumeIsolated {
        Self.unregister(traitRegistrations: registrations)
      }
    }
    traitRegistrations.removeAll()
  }

  @available(iOS 17.0, *)
  @MainActor
  private static func unregister(traitRegistrations: [Any]) {
    for entry in traitRegistrations {
      if let (window, registration) = entry as? (UIWindow, UITraitChangeRegistration) {
        window.unregisterForTraitChanges(registration)
      }
    }
  }

  private func stopObserving() {
    let center = NotificationCenter.default
    for token in notificationTokens {
      center.removeObserver(token)
    }
    notificationTokens.removeAll()
    unregisterSceneTraitObservers()
  }

  private func evaluateAndEmitIfNeeded() {
    let current = computeExternalCaptured()
    guard current != lastReportedCaptured else { return }
    lastReportedCaptured = current
    emit(current)
  }

  private func emit(_ captured: Bool) {
    channel.invokeMethod(
      "screenCaptureStateChanged",
      arguments: ["captured": captured]
    )
  }

  private func computeExternalCaptured() -> Bool {
    if isOwnCaptureActive() {
      return false
    }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    if #available(iOS 17.0, *) {
      if scenes.contains(where: { scene in
        scene.traitCollection.sceneCaptureState == .active ||
          scene.windows.contains(where: { $0.traitCollection.sceneCaptureState == .active })
      }) {
        return true
      }
      if scenes.contains(where: {
        $0.session.role == .windowExternalDisplayNonInteractive ||
          $0.session.role == .windowExternalDisplay
      }) {
        return true
      }
    }
    if #available(iOS 18.0, *) {
      return false
    } else {
      if scenes.contains(where: { $0.screen.isCaptured }) {
        return true
      }
      return UIScreen.main.isCaptured
    }
  }

  private func onMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async(execute: block)
    }
  }
}
