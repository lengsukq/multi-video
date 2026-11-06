## 0.1.0-dev.27

- Make the meeting creator or livestream host end the room for everyone when leaving; ordinary participants and viewers leave only themselves, with one confirmation instead of a leave-mode selector.
- Resolve ownership by the logical room owner credential or host role, including meetings where the creator has participant-level media permissions; preserve the room and surface an error if closure fails.
- Detect authoritative remote room closure through backend heartbeat room-not-found events, stop polling, and notify SDK meeting/live pages to exit; shorten high-level media presence polling to five seconds.
- Preserve cloud recording stop-before-close behavior and add regression coverage for owner/participant exit, close capability failures, and remote-close heartbeat handling.
- Include live gift notifications and LiveKit video rendering fixes from the current SDK sources.
- Remote exit is eventually consistent with heartbeat polling where vendor-side room teardown is unavailable; real-device multi-vendor confirmation remains pending.
- iOS Simulator, Windows/Linux and real-device vendor acceptance remain pending or unsupported as documented.
