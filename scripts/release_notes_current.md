## 0.1.0-dev.29

- Merge Windows provider integrations and their native/desktop packaging into the macOS-maintained SDK release sources; reconcile adapter, UI, test and capability-matrix changes without rewriting history.
- Correct Agora Android screen sharing: start and stop the screen-source preview with capture, and use Flutter Texture rendering on Android to avoid black local frames. Add regression coverage.
- Preserve Windows Agora screen-share signaling, screen-source rendering selection and orientation regression tests after merging Windows changes.
- Include the Windows Chime WebView2 bridge and experimental Amazon IVS Real-Time WebView2 Stage bridge with isolated provider RPC, diagnostics, pre-join probes and provisional JPEG frame rendering.
- Retain native Android/iOS AWS Chime and IVS integrations, macOS WebKit bridge, and browser JavaScript SDK support from the unified source tree.
- AWS IVS in embedded WebViews is not officially supported; Windows AWS media and all-provider bidirectional real-device acceptance remain unverified.
- Keep this as a preview release: vendor-binary redistribution/licensing review and full native cross-platform acceptance remain pending.
