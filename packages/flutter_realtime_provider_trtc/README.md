# flutter_realtime_provider_trtc

Optional Tencent TRTC media Provider bundle for the [Flutter Realtime SDK](https://github.com/lengsukq/multi-video). It does not implicitly install Tencent Cloud Chat or the SDK's optional UI.

> **Development only, not yet on pub.dev.** `publish_to: none` and local dependencies will be migrated only on the reviewed release branch.

```dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';
import 'package:flutter_realtime_provider_trtc/flutter_realtime_provider_trtc.dart';

final realtime = Realtime(
  backendUrl: 'https://your-backend.example',
  providers: [createTrtcProvider()],
);
```

Add the facade and this bundle to your host manifest. Configure TRTC SDKAppID / short-lived UserSig **through your trusted backend**; never sign UserSig with an embedded secret. Add `flutter_realtime_provider_tencent_chat` separately for product IM.

Platform drivers and actual features are described in the [capability matrix](https://github.com/lengsukq/multi-video/blob/main/doc/SDK_CAPABILITY_MATRIX.zh-CN.md); [TRTC E2E](https://github.com/lengsukq/multi-video/blob/main/doc/ACCEPTANCE.md) covers device acceptance. Native plugin integration, screen sharing and cloud recording still require actual device/vendor validation.
