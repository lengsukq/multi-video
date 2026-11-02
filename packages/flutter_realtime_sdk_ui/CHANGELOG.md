## Unreleased (source only; maintainer publishes the single SDK manually)

- Fix meeting RTC-data and recording sidebar error paths that looked up room UI
  Scope from a BuildContext above the scope.
- Add public `showRealtimeRoomUiDialog` and
  `showRealtimeRoomUiBottomSheet` helpers, preserving a borrowed controller
  across Navigator overlay routes.
- Reuse the existing room UI controller in meeting/live mobile drawers;
  avoid independent per-overlay subscriptions.
- Prevent a delayed leave confirmation from closing a borrowed room after
  its button is unmounted.
- Preserve the horizontal dock Scrollable element when overflow arrows
  appear/disappear, so enlarged text does not strand off-screen host tools.
- Coalesce concurrent UI commands using a shared in-flight Future: duplicate
  callers now await the actual provider result and receive its failure rather
  than falsely reporting success before the operation has completed.
- Reject commands issued against a closed room UI controller with a typed
  `invalidState` error instead of reporting success without doing anything.
- Align the third-party integration guides, ownership/leave semantics and
  future single-package README templates with the new public APIs.

## 0.1.0

- Initial development release of optional composable room UI.
- Meeting/Live/Chat/Classroom controls, independent room scope and responsive presentation widgets.
- Separate UI lifetime from SDK-owned room lifetime.

> Not published to pub.dev yet; real-device UI acceptance must be completed before release.
