# flutter_realtime_interaction_core

Pure-Dart, **provider- and UI-independent** contracts for revision-based realtime interactions. Defines typed interaction events and commands that an application can use to build optional features without coupling them to Flutter widgets or a particular RTC/IM vendor.

> **Unpublished development package.** `publish_to: none` is intentionally enabled until [release readiness](https://github.com/lengsukq/multi-video/blob/main/doc/PUB_DEV_RELEASE_GUIDE.zh-CN.md) is approved.

```dart
import 'package:flutter_realtime_interaction_core/flutter_realtime_interaction_core.dart';
```

Only the public `flutter_realtime_interaction_core.dart` entrypoint is part of this package's supported surface. The contracts are **not** a persistent message broker or an authorization service. Domain presets (`flutter_realtime_classroom_preset`, `flutter_realtime_live_preset`) derive user-visible state from a trusted backend; data/IM notifications are revision hints and may be coalesced.

See [interaction architecture](https://github.com/lengsukq/multi-video/blob/main/doc/ARCHITECTURE.md) and [preset integrations](https://github.com/lengsukq/multi-video/blob/main/doc/APP_INTEGRATION_QUICKSTART.zh-CN.md).
