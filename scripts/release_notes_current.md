## 0.1.0-dev.28

- Synchronize the Windows native LiveKit processed video track bridge with Flutter WebRTC's required stream descriptor fields, including ownerTag, and validate descriptors before publication.
- Add a D3D11 GPU compositor for Windows virtual backgrounds, with low/medium/high separable multi-pass blur, native person mask composition, replacement images, and dynamic CPU fallback.
- Add optional SHA-256-pinned ONNX Runtime DirectML acceleration and preserve its runtime/provider DLLs in the bundled Windows SDK.
- Improve Windows camera capture and processed frame pooling to reduce callback contention and allocations, with native smoke tests and a real-camera performance probe.
- Prevent duplicate video-effects initialization during room entry, improve effect operation diagnostics, and avoid reporting an already-closed room as active when local teardown fails.
- Add backend room-closure diagnostics and retry/ownership regression tests (backend implementation is separately deployed; this SDK package does not contain the demo server).
- Update the one-package Windows assembler to link D3D11/D3DCompiler/DXGI, include the optional DirectML provider and DLL, and retain Windows Debug/native compiler settings.
- Windows functional end-to-end tests, other platform real-device regressions, and vendor binary redistribution/license review remain pending; do not treat source and synthetic tests as cross-vendor certification.

- Make the meeting creator or livestream host end the room for everyone when leaving; ordinary participants and viewers leave only themselves, with one confirmation instead of a leave-mode selector.
- Resolve ownership by the logical room owner credential or host role, including meetings where the creator has participant-level media permissions; preserve the room and surface an error if closure fails.
- Detect authoritative remote room closure through backend heartbeat room-not-found events, stop polling, and notify SDK meeting/live pages to exit; shorten high-level media presence polling to five seconds.
- Preserve cloud recording stop-before-close behavior and add regression coverage for owner/participant exit, close capability failures, and remote-close heartbeat handling.
- Include live gift notifications and LiveKit video rendering fixes from the current SDK sources.
- Remote exit is eventually consistent with heartbeat polling where vendor-side room teardown is unavailable; real-device multi-vendor confirmation remains pending.
- iOS Simulator, Windows/Linux and real-device vendor acceptance remain pending or unsupported as documented.
