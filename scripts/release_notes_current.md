## 0.1.0-dev.30

- Fix AWS Chime and IVS on macOS when consumed from the hosted one-package SDK: resolve the WebKit runtime JavaScript from the SDK's owning Flutter framework, with standalone CocoaPods and Swift Package Manager fallbacks.
- Resolve bundled AWS vendor and media-provider JavaScript through the public SDK's `assets/bundled` layout instead of relying only on the original private package names.
- Load a minimal browser `global` compatibility shim before AWS scripts on Web, macOS WebKit and Windows WebView2; this removes a Chime WebKit initialization failure.
- Add an actual macOS Chime meeting integration test to the SDK's own Demo, with a separate backend, real AWS meeting/attendee creation, SDK connection and guaranteed cleanup. Validate both the development source and the assembled one-package SDK.
- Strengthen the published-package asset checks for Web, Windows and macOS AWS runtime resources, bundled path rewrites and load order.
- Android and iOS continue to use their native AWS SDKs. This is a preview release; real-device iOS/Android acceptance, Windows AWS media acceptance, and browser cross-device tests are separate from the passing macOS Chime E2E.
- Amazon IVS Real-Time remains an experimental desktop WebView implementation; AWS does not officially support IVS in embedded WebViews. Vendor-binary license and redistribution review remains pending.
