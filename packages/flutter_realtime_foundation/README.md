# flutter_realtime_foundation

Shared **pure-Dart** infrastructure contracts used by Flutter Realtime SDK: typed `RealtimeException` and error codes, bounded cleanup, HTTP execution, JSON readers and validated avatar URLs. This package **does not import Flutter, UI widgets or an RTC provider**.

> **Not on pub.dev yet.** Development-only `publish_to: none` remains enabled. See [release checklist](https://github.com/lengsukq/multi-video/blob/main/doc/PUB_DEV_RELEASE_GUIDE.zh-CN.md).

```dart
import 'package:flutter_realtime_foundation/flutter_realtime_foundation.dart';

try {
  // Call a trusted application/backend API here.
} on RealtimeException catch (error) {
  // Map the typed error to application UI and diagnostics.
  print(error);
}
```

The public library exports error, cleanup, transport and validation utilities. Applications using `flutter_realtime_sdk` already receive foundation transitively; import this package directly only if you are implementing custom adapters or a non-Flutter backend/client.

See [architecture](https://github.com/lengsukq/multi-video/blob/main/doc/ARCHITECTURE.md) and [public facade](https://github.com/lengsukq/multi-video/tree/main/packages/flutter_realtime_sdk). Never log tokens or service secrets in exception telemetry.
