# Unified real-call acceptance

The new `example/integration_test/realtime_acceptance_test.dart` is opt-in.
Ordinary CI does not join providers. Defaults: 20 complete join/leave cycles followed by a separate endurance join and a 30-minute final session.
Use existing configured test projects and physical devices; no credentials are
discovered or downloaded by this test.

## Running a configured room

Provision a test room and keep the remote peer(s) connected throughout the run.
Run from `example/`:

```sh
flutter test integration_test/realtime_acceptance_test.dart -d <device-id> \
  --dart-define=ACCEPTANCE_BACKEND_URL=http://<test-backend>:3000 \
  --dart-define=ACCEPTANCE_ROOM_CODE=<room-code> \
  --dart-define=ACCEPTANCE_PROVIDER=livekit \
  --dart-define=ACCEPTANCE_DEVICE=<device-model-and-os> \
  --dart-define=ACCEPTANCE_VENDOR_SDK_VERSION=<locked-vendor-version>
```

For live, add `ACCEPTANCE_LIVE=true`; the publisher must observe two viewers
(`ACCEPTANCE_REMOTE_COUNT=2`). A viewer adds `ACCEPTANCE_VIEWER=true`.
Repeat publisher tests with `ACCEPTANCE_EFFECT=blur` and `replaceImage`.
Camera switching is explicit via `ACCEPTANCE_SWITCH_CAMERA=true` and requires
front/back cameras. Providers without the requested capability must report
unsupported; do not mark that scenario passed.

During the endurance session, manually interrupt and restore the network; add
`ACCEPTANCE_EXPECT_RECOVERY=true` to require a recovered event. Token renewal
must additionally run the existing provider-specific short-TTL tests documented
in ACCEPTANCE.md, ACCEPTANCE.md, ACCEPTANCE.md and ACCEPTANCE.md. The generic endurance
test does not claim to prove renewal just because a session remains connected.

`ACCEPTANCE_CYCLES` and `ACCEPTANCE_HOLD_SECONDS` can shorten debugging runs;
only record the default 20/1800 run as full lifecycle/endurance acceptance.

## Remote visual review

Remote observers record screenshots/video evidence for blur and image replacement:
portrait/landscape, front/back camera, geometry/aspect ratio, cheek/temple edges,
none/effect transitions and restoration after reconnect. A remote participant or
published-track event proves presence, not correct pixels. The automated record
always leaves `remoteFrameReview` pending until a human attaches this evidence.

## Result and cleanup

Copy the sanitized `ACCEPTANCE {...}` JSON lines into a local report using
`doc/acceptance-record.example.json`. Record platform, actual device/OS, provider,
engine and locked vendor version. Keep separate `implemented`, `build`, `realCall`
and `remoteVisual` fields. Missing credentials/devices and unsupported combinations
remain `pending` or `unsupported`, never `passed`.

The test releases its own connection in `finally`. Room owners must delete rooms
and verify deletion separately. `ACCEPTANCE_CLOSE_ROOM=true` is only for an
explicitly authorized owner connection and still requires control-plane proof.
AWS runs use `chime-demo`, Chime control plane `us-east-1`; delete each probe meeting
and confirm `get-meeting` returns `NotFoundException`. Local leave alone is not
provider resource cleanup.


---

## Chime iOS/Android 真实设备用例

### Before running

1. Start or deploy a backend that implements `MEDIA_BACKEND_CONTRACT.md`. The bundled
   `demo-server` is sufficient for local testing.
2. Connect a physical Android or iOS device.
3. Ensure the device can reach the backend URL.
4. Grant microphone and camera permission when prompted. For repeatable CI-lab
   devices, pre-grant those permissions before starting the test.

### Create a room and run the lifecycle test

From `example/`:

```bash
flutter test integration_test/chime_device_e2e_test.dart \
  -d <device-id> \
  --dart-define=CHIME_E2E_BACKEND_URL=http://192.168.1.10:3000 \
  --dart-define=CHIME_E2E_NICKNAME=device-a
```

If the backend requires application authentication, add:

```bash
--dart-define=CHIME_E2E_TOKEN=<short-lived-app-token>
```

The positive-path test verifies:

- backend create/join and Chime media connection;
- microphone unmute/mute;
- audio-device enumeration and selection when devices are exposed;
- local video start/stop;
- front/back camera switching;
- data-message send path;
- leave and idempotent disposal.

Use `--dart-define=CHIME_E2E_SKIP_CAMERA_SWITCH=true` only for hardware that
does not have both front and back cameras.

### Two-device attendee check

Choose a fixed room code. Start the host and keep it connected long enough for
the guest to join:

```bash
flutter test integration_test/chime_device_e2e_test.dart \
  -d <host-device-id> \
  --dart-define=CHIME_E2E_BACKEND_URL=http://192.168.1.10:3000 \
  --dart-define=CHIME_E2E_ROOM_CODE=482913 \
  --dart-define=CHIME_E2E_CREATE_ROOM=true \
  --dart-define=CHIME_E2E_HOLD_SECONDS=60 \
  --dart-define=CHIME_E2E_EXPECT_REMOTE_ATTENDEE=true \
  --dart-define=CHIME_E2E_NICKNAME=host
```

Then run on the guest device:

```bash
flutter test integration_test/chime_device_e2e_test.dart \
  -d <guest-device-id> \
  --dart-define=CHIME_E2E_BACKEND_URL=http://192.168.1.10:3000 \
  --dart-define=CHIME_E2E_ROOM_CODE=482913 \
  --dart-define=CHIME_E2E_CREATE_ROOM=false \
  --dart-define=CHIME_E2E_NICKNAME=guest
```

### Failure-path checks

Some failure modes require OS or network control and are intentionally not
faked inside the package test:

- **Permission denied:** revoke microphone/camera permission in system settings,
  rerun the test, and verify a typed `permissionDenied` media error.
- **Invalid/expired app token:** run with an invalid `CHIME_E2E_TOKEN` and
  verify the backend returns a typed authentication/backend error.
- **Network interruption/reconnect:** while connected, disable network access,
  restore it, and verify reconnect state/events before continuing media calls.
- **Backend unavailable:** stop the backend before create/join and verify a
  typed network/backend error rather than an untyped crash.

These scenarios are suitable for a device lab where permissions and network
can be controlled externally. They are not run in the ordinary GitHub Actions
workflow because that workflow has no real Chime credentials or physical
devices.


---

## Agora 双设备和角色验收

### Prerequisites

Create an Agora project and keep both values on the backend only:

- `AGORA_APP_ID`
- `AGORA_APP_CERTIFICATE`

If production security depends on a modified viewer client being unable to
publish, enable Agora's project-side co-host authentication capability and
verify that policy with this E2E. The reference backend already issues viewer
AccessToken2 credentials with audio/video/data publish privileges set to zero,
but project-side enforcement is an Agora account configuration boundary.

Start the existing single demo backend:

```bash
cd demo-server
AGORA_APP_ID=... AGORA_APP_CERTIFICATE=... npm start
```

Then open `http://127.0.0.1:3000/` and select **Agora RTC** for newly-created
rooms. Flutter never sends a provider selector.

For a physical phone, use the Mac/server LAN address instead of
`127.0.0.1`.

### Single-device lifecycle

This checks join/leave, microphone, and camera. On Android/iOS it also checks
front/back camera switching. On macOS the adapter intentionally reports
`canSwitchCamera=false` because Agora exposes `switchCamera` only on mobile.

```bash
cd example
flutter test integration_test/agora_device_e2e_test.dart -d <device-id> \
  --dart-define=AGORA_E2E_BACKEND_URL=http://192.168.31.2:3000 \
  --dart-define=AGORA_E2E_ROLE=host \
  --dart-define=AGORA_E2E_DEVICE_MEDIA=true
```

Without `AGORA_E2E_BACKEND_URL`, the integration test skips safely.

The same test can run with `-d macos`. When the backend is on the same Mac,
use `http://127.0.0.1:3000` for `AGORA_E2E_BACKEND_URL`.

### Two-device host + viewer

Use a fixed room code so both devices join the same room. Start the host first:

```bash
flutter test integration_test/agora_device_e2e_test.dart -d <host-device> \
  --dart-define=AGORA_E2E_BACKEND_URL=http://192.168.31.2:3000 \
  --dart-define=AGORA_E2E_ROOM_CODE=482913 \
  --dart-define=AGORA_E2E_ROLE=host \
  --dart-define=AGORA_E2E_DEVICE_MEDIA=true \
  --dart-define=AGORA_E2E_EXPECT_REMOTE_PARTICIPANT=true \
  --dart-define=AGORA_E2E_HOLD_SECONDS=30
```

Then start the viewer:

```bash
flutter test integration_test/agora_device_e2e_test.dart -d <viewer-device> \
  --dart-define=AGORA_E2E_BACKEND_URL=http://192.168.31.2:3000 \
  --dart-define=AGORA_E2E_ROOM_CODE=482913 \
  --dart-define=AGORA_E2E_ROLE=viewer \
  --dart-define=AGORA_E2E_CREATE_ROOM=false \
  --dart-define=AGORA_E2E_EXPECT_REMOTE_PARTICIPANT=true \
  --dart-define=AGORA_E2E_EXPECT_REMOTE_MESSAGE=true
```

The host waits for the viewer before sending the `e2e` RTC data message, so
the viewer can assert receipt. The viewer adapter never exposes interactive
media publishing methods.

### Two interactive participants

For bidirectional RTC data verification, run both devices as
`participant` with the same room code, set
`AGORA_E2E_EXPECT_REMOTE_PARTICIPANT=true` and
`AGORA_E2E_EXPECT_REMOTE_MESSAGE=true` on both, and set
`AGORA_E2E_CREATE_ROOM=false` only on the second device.

No Agora App Certificate or other long-lived secret is passed through
`--dart-define`.


---

## ARTC 设备和连麦验收

### Configure the backend

Set `ARTC_APP_ID` and `ARTC_APP_KEY` on the server, select Alibaba Cloud ARTC in
the dashboard, then create a room as a `participant` or `host`. The server
keeps the AppKey and signs the short-lived join credentials. Keep the host's
room code for the viewer devices.

### Run a participant call

Run two devices with the same room code and `ARTC_E2E_ROLE=participant`; the
first device can create the room and the second joins the existing code. This
uses ARTC communication mode.

### Run a host with two viewers

Run one device as `host` with `ARTC_E2E_CREATE_ROOM=true`, then run two other
devices as `viewer` with `ARTC_E2E_CREATE_ROOM=false` and the host's room code.
On each viewer, set `ARTC_E2E_EXPECT_REMOTE_PARTICIPANTS=1` to confirm the host
is visible; optionally set `ARTC_E2E_RENDER_REMOTE_VIDEO=true` to attach the
native renderer. Keep both viewers connected during the run to confirm that
multiple viewers can watch the same host. The test does not require the host to
receive viewer participant events.

Each viewer session has a subscribe-only Core API and joins the native SDK as a
viewer. ARTC's signed auth token does not encode an enforced publish grant, so
this client role is not a security boundary against modified clients.

### Run the integration test

From `example/`, add the values as Dart defines to `flutter test` on a connected
Android or iOS device. For example:

```bash
flutter test integration_test/artc_device_e2e_test.dart \
  -d <device-id> \
  --dart-define=ARTC_E2E_BACKEND_URL=http://<server-lan-ip>:3000 \
  --dart-define=ARTC_E2E_ROLE=host \
  --dart-define=ARTC_E2E_CREATE_ROOM=true \
  --dart-define=ARTC_E2E_DEVICE_MEDIA=true \
  --dart-define=ARTC_E2E_HOLD_SECONDS=120
```

For viewers, pass `ARTC_E2E_ROLE=viewer`, `ARTC_E2E_CREATE_ROOM=false`, and the
room code. `ARTC_E2E_EXPECT_REMOTE_MESSAGE=true` checks a host message on a
viewer. The data channel requires an active publisher audio or video stream.

The 7.11.0 iOS CocoaPod contains a device framework and cannot link an iOS
Simulator build. Use a physical iPhone/iPad for this test.


---

## TRTC RTC 与 Token 续期验收

### Configure the reference backend

Create a Tencent RTC application and keep the signing secret on the backend.
Enable **Advanced Permission Control** so the room-scoped PrivateMapKey rights
issued by the server are enforced. Configure the ignored `demo-server/.env`
file or the server process with:

```text
TRTC_SDK_APP_ID=<Tencent SDKAppID>
TRTC_SDK_SECRET_KEY=<server-only secret>
TRTC_TOKEN_TTL_SECONDS=600
```

Start the demo backend and select **Tencent TRTC** in its dashboard for new
rooms. For a physical device, pass a backend URL reachable from that device,
such as the development machine's LAN address. Do not put the TRTC secret in
Flutter defines or app configuration.

### One-device host lifecycle and rendering

This checks TRTC join/leave, microphone, camera, camera switching, and local
video rendering:

```bash
cd example
flutter test integration_test/trtc_device_e2e_test.dart -d <device-id> \
  --dart-define=TRTC_E2E_BACKEND_URL=http://192.168.31.2:3000 \
  --dart-define=TRTC_E2E_ROLE=host \
  --dart-define=TRTC_E2E_DEVICE_MEDIA=true
```

Without `TRTC_E2E_BACKEND_URL`, the test skips. The test registers only
`TrtcSessionFactory`, which also demonstrates that the app can include TRTC
without registering any other adapter.

### Host and two viewers

Choose a room code. Start the host first; it enables its camera and waits until
both viewers join before sending a message:

```bash
flutter test integration_test/trtc_device_e2e_test.dart -d <host-device> \
  --dart-define=TRTC_E2E_BACKEND_URL=http://192.168.31.2:3000 \
  --dart-define=TRTC_E2E_ROOM_CODE=482913 \
  --dart-define=TRTC_E2E_ROLE=host \
  --dart-define=TRTC_E2E_DEVICE_MEDIA=true \
  --dart-define=TRTC_E2E_EXPECT_REMOTE_PARTICIPANTS=2 \
  --dart-define=TRTC_E2E_HOLD_SECONDS=60
```

Start each viewer on a separate device, using the same room code:

```bash
flutter test integration_test/trtc_device_e2e_test.dart -d <viewer-device-1> \
  --dart-define=TRTC_E2E_BACKEND_URL=http://192.168.31.2:3000 \
  --dart-define=TRTC_E2E_ROOM_CODE=482913 \
  --dart-define=TRTC_E2E_ROLE=viewer \
  --dart-define=TRTC_E2E_CREATE_ROOM=false \
  --dart-define=TRTC_E2E_EXPECT_REMOTE_PARTICIPANTS=1 \
  --dart-define=TRTC_E2E_EXPECT_REMOTE_MESSAGE=true \
  --dart-define=TRTC_E2E_RENDER_REMOTE_VIDEO=true
```

Repeat the viewer command with the second device. Each viewer asserts that its
session has no publish or message-send surface, receives the host's custom
message, and creates the remote video view. The service-side PrivateMapKey is
the enforcement boundary for clients that bypass the Flutter API.

### Credential renewal

Set `TRTC_TOKEN_TTL_SECONDS=60` on the backend and run a single device with:

```bash
flutter test integration_test/trtc_device_e2e_test.dart -d <device-id> \
  --dart-define=TRTC_E2E_BACKEND_URL=http://192.168.31.2:3000 \
  --dart-define=TRTC_E2E_ROLE=host \
  --dart-define=TRTC_E2E_EXPECT_RENEWAL=true \
  --dart-define=TRTC_E2E_RENEWAL_TIMEOUT_SECONDS=75
```

The test waits for the adapter's reconnecting transition and confirms it returns
to connected after refreshing the same participant's credentials. The reference
backend caps only the credential lifetime; it does not expose server secrets in
the join or refresh response.


---

## 互动行为必须保留的验收边界

### Remaining implementation and coverage gaps

| Gap | Current boundary | Follow-up |
| --- | --- | --- |
| Material upload | Existing links and host uploader interface only | File selection, actual upload integration and optional embedded preview; storage remains host-owned |
| Recording/replay | Deferred; neither implemented | Separate future recording and replay scope |
| Forced speaking permissions | LiveKit control-plane implementation only; real media pending | Enforce other vendors through their actual permission APIs before claiming forced mute |
| Native teacher screen sharing | LiveKit is the first path; TRTC Android/iOS calls exist; others have gaps | Extend the missing adapter/platform paths and validate devices |
| iOS cross-app capture | LiveKit explicitly uses in-app capture without Broadcast Extension | Implement/configure the whole-screen path if required; validate TRTC's complete iOS flow |
| System annotation layer | SDK system-window adapters now exist for Android/macOS/Windows/X11; builds and native acceptance differ | See CLASSROOM_SDK.md for platform evidence and remaining real-device/remote-pixel checks |
| Roster media flags | Unknown when vendor telemetry is absent | Improve applicable adapter telemetry without inventing enabled/disabled states |
| Windows | Some media/Chat drivers registered, but this run has no native build evidence | Use a Windows runner for builds and new interaction acceptance |
| Real vendor/platform combinations | Mock protocol tests and builds only for this delivery | Complete the multi-device checklist below, including remote pixels and cleanup |

Homework submission/grading, formal absence rules, server-wide chat analytics
and cross-course history are future extensions, not promised completions of
this room-lifecycle SDK prototype. New tool/gift state remains transient;
legacy optional classroom persistence must not be described as new tool storage.

### Real-device checks still required

Run each configured provider with one teacher and two students, or one host and
two viewers, across Web, Android/iOS and macOS:

1. Send product Chat in both directions as a viewer. Change dashboard providers
   and confirm existing rooms stay bound to their original media/Chat pair.
2. Publish announcement, focus reminder, homework and material link; verify the
   two students receive the same state, and a late joiner receives it too.
3. Submit and change Quiz/Poll answers on both students. Confirm hidden answers,
   teacher counts, close behavior and post-close results.
4. Join/leave/rejoin and interrupt the network; verify roster, attendance and
   deadlines restore without duplicate events or treating unknown media flags
   as enabled. Compare clocks if synchronized timer displays differ.
5. Gift from both viewers. Retry one timed-out submission with the same event
   ID; verify shared totals and no duplicate animation/count. Disconnect host
   and confirm submission errors remain visible.
6. Share on an adapter/platform that advertises sharing. Draw all tools, undo
   and clear. Compare remote coordinates on phone/tablet/desktop, portrait and
   landscape, letterboxes and changing share sources. Verify an in-progress
   stroke syncs, stale-canvas writes fail, and reconnect restores marks.
7. For LiveKit, verify actual audio publishing is denied before approval,
   enabled after teacher grant, and removed after revoke/reconnection. Other
   adapters remain advisory unless separately implemented and validated.

Unsupported combinations stay `unsupported`; device/provider checks that have
not been run stay `pending`. Follow [real-call acceptance](ACCEPTANCE.md) for
sanitized evidence and provider resource cleanup. Local leave does not prove
cloud-room deletion.


---

## Windows 原生构建与实机验收

### 四、Windows 验收操作

Windows 10/11 x64、Visual Studio 2022（Desktop C++ + Windows SDK）、Flutter >=3.47、真实摄像头和两台终端。先执行：

```powershell
flutter pub get
flutter build windows --release
```

在 SDK 示例应用 `example/` 目录执行上述命令。调试 Windows 原生插件时使用 `example/build/windows/x64/runner/Release`，核对 `onnxruntime.dll`、`data/flutter_assets/packages/flutter_realtime_video_effects/assets/windows/pphumanseg.onnx`、媒体厂商 DLL。离线构建可使用 `REALTIME_ONNXRUNTIME_ROOT` 指向官方 ONNX Runtime x64 完整头文件、导入库及 DLL；不能跳过 SHA 校验或静默降级为无分割模型。

测试矩阵：**LiveKit / Agora / TRTC** 各做 Meeting 主持人和普通参会者、Live 主播和观众；每组测试摄像头与麦克风启停、屏幕共享（含多屏幕）、None/Blur/ReplaceImage、预览和另一台设备的实际像素、房间结束后的远端退出、断线重连、摄像头拔插、未找到 ONNX 模型后的不泄露原背景、两小时的内存和帧率稳定性。录制开始/停止/MP4 回看仍需服务端对应凭据。

**验收红线：**虚拟背景启用时若分割、模型、Provider Sink 或采集失败，必须拒绝处理后视频发布或停止发布，不允许偷偷退回未处理摄像头；设备关闭和应用退出必须停止采集并释放轨道。此要求需要从远端实际看到的帧、日志与进程资源联合确认。
