# flutter_realtime_provider_agora

Optional **Agora RTC media** provider bundle for the [Flutter Realtime SDK](https://github.com/lengsukq/multi-video). It selects the registered platform driver at runtime and loads pinned local Web assets when necessary. It is **not** the separate `flutter_realtime_provider_agora_chat` IM package.

> **Not yet on pub.dev.** The package currently uses `publish_to: none` and monorepo `path:` dependencies. See [release readiness](https://github.com/lengsukq/multi-video/blob/main/doc/PUB_DEV_RELEASE_GUIDE.zh-CN.md).

```dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';
import 'package:flutter_realtime_provider_agora/flutter_realtime_provider_agora.dart';

final realtime = Realtime(
  backendUrl: 'https://your-backend.example',
  providers: [createAgoraProvider()],
);
```

The host must add both `flutter_realtime_sdk` and this bundle as explicit dependencies. For development, use `path: ../multi-video/packages/flutter_realtime_provider_agora` when the app and SDK checkout are sibling directories.

Agora App Certificate, RTC token generation, Cloud Recording Customer Secret and S3 access keys belong in a trusted backend. The app receives only short-lived room credentials. The app must check supported media capabilities for its platform and role; cloud recording requires a separate backend and is **not** automatically enabled by installing the provider.

See [Agora E2E notes](https://github.com/lengsukq/multi-video/blob/main/doc/ACCEPTANCE.md), [platform support](https://github.com/lengsukq/multi-video/blob/main/doc/SDK_CAPABILITY_MATRIX.zh-CN.md) and [cloud recording](https://github.com/lengsukq/multi-video/blob/main/doc/CLOUD_RECORDING.md). Driver registration and local mock tests are not real-device E2E certification.
