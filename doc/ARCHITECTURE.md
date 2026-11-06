# SDK 架构与维护规范

> 最后整合：2026-11-06。仅解释当前源码和明确的依赖边界；旧 P1 重构进度以 Git 历史为准。

项目采用模块化开发、单包发布。对外只依赖 `flutter_realtime_sdk`，运行时显式注册 Provider；RTC 媒体与产品级 Chat 独立，授权操作始终由服务端确认。


---

## 内部 44 包与职责

### 当前源码开发期的入口（不代表未来 44 个独立发布）

| 包名 | 作用 | 何时依赖 |
| --- | --- | --- |
| `flutter_realtime_sdk` | 最薄的统一门面 `Realtime`，创建/加入 Meeting、Live、独立 Chat | **推荐必选**；本身不打包所有供应商 |
| `flutter_realtime_sdk_runtime` | 不带 UI/Provider 默认目录的会话生命周期、成员管理、事件、Feature 注册 | 高级自定义，通常通过主 SDK 间接依赖 |
| `flutter_realtime_provider_livekit` | LiveKit 音视频 Driver bundle | 选择 LiveKit 时注册 `createLivekitProvider()` |
| `flutter_realtime_provider_agora` | Agora RTC Driver bundle | 使用 Agora RTC |
| `flutter_realtime_provider_trtc` | 腾讯 TRTC RTC Driver bundle | 使用腾讯 RTC |
| `flutter_realtime_provider_artc` | 阿里 ARTC RTC Driver bundle | 使用阿里 RTC |
| `flutter_realtime_provider_aws` | AWS Meeting Chime / Live IVS 的统一 Provider | 使用 AWS 时 |
| `flutter_realtime_provider_agora_chat` | 独立 Agora Chat bundle | 需要 Agora 产品 IM |
| `flutter_realtime_provider_tencent_chat` | 腾讯云 Chat bundle | 需要 Tencent 产品 IM |
| `flutter_realtime_provider_ivs_chat` | AWS IVS Chat bundle | 需要 IVS 产品 IM |
| `flutter_realtime_sdk_ui` | 可选可组合的 Meeting/Live/Chat/课堂/白板聚合 UI | 需要内置组件或完整模板 |
| `flutter_realtime_design_ui` | 独立视觉设计系统、卡片、Glass、Dock 等，不依赖供应商 | 只需设计风格或自定义页面 |
| `flutter_realtime_chat_ui` | 只需要聊天组件时的轻量 UI | 独立聊天应用可不引入视频 UI |
| `flutter_realtime_classroom_preset` | 可选课堂业务：举手、发言授权、Q&A、公告、工具协调 | 自己注册 `ClassroomPreset()` |
| `flutter_realtime_live_preset` | 可选直播业务：点赞、礼物、互动记录 | 自己注册 `LivePreset()` |

**重要：** `flutter_realtime_sdk_ui` 是较重的 UI 聚合包；
只想调用功能时不要依赖它。预装业务不是自动启用；宿主仍需在
`Realtime(featurePlugins: [...])` 显式注册。Provider 的核心功能以
[能力矩阵](SDK_CAPABILITY_MATRIX.zh-CN.md) 为准，注册不等于已通过真实设备 E2E。

### 领域 Core：通常只作为传递依赖

| 包名 | 定位 |
| --- | --- |
| `flutter_realtime_foundation` | 错误模型、HTTP 工具、清理与公共基础能力 |
| `flutter_realtime_interaction_core` | 通用互动消息、版本通知、权威控制面合同 |
| `flutter_realtime_media_core` | 媒体 Session、角色、轨道、能力、录制蓝图 |
| `flutter_realtime_chat_core` | Chat Session、Token/成员、会话能力与管理模型 |
| `flutter_realtime_classroom_core` | Classroom 领域模型、事件与会话 |
| `flutter_realtime_live_core` | Live 互动 Session、点赞与礼物模型 |
| `flutter_realtime_whiteboard_core` | 白板与标注相关的领域合同 |

### 底层 Provider / Platform Adapter（一般不直接选用）

| 包名 | 定位 |
| --- | --- |
| `flutter_realtime_media_livekit` | LiveKit Media Adapter |
| `flutter_realtime_media_agora` | Agora RTC Media Adapter |
| `flutter_realtime_media_trtc` | Tencent TRTC Media Adapter |
| `flutter_realtime_media_artc` | Alibaba ARTC Media Adapter |
| `flutter_realtime_media_chime` | AWS Chime Media Adapter |
| `flutter_realtime_media_ivs` | AWS IVS Real-Time Media Adapter |
| `flutter_realtime_media_aws_desktop` | AWS Desktop 平台桥接 |
| `flutter_realtime_media_web` | Web 平台驱动与浏览器轨道 |
| `flutter_realtime_chat_agora` | Agora Chat Adapter |
| `flutter_realtime_chat_tencent` | Tencent Cloud Chat Adapter |
| `flutter_realtime_chat_ivs` | AWS IVS Chat Adapter |
| `flutter_realtime_chat_rtc` | 使用双向 RTC Data 的**非产品 IM** 会话内 Chat fallback |
| `flutter_realtime_video_effects` | 虚拟背景/模糊/替换等视频效果服务与平台 Bridge |
| `flutter_realtime_processed_video` | Processed video 数据管线 |
| `flutter_realtime_screen_annotation` | 系统级共享屏幕标注插件 |
| `flutter_aws_chime` | 仓库维护的 Chime Flutter 原生桥，需单独审查发布许可 |

### 独立 UI 和其他可选 Preset

| 包名 | 定位 |
| --- | --- |
| `flutter_realtime_media_ui` | Media 组件及旧的完整房间模板 |
| `flutter_realtime_room_ui` | 房间组合状态/控制层 |
| `flutter_realtime_classroom_ui` | 独立课堂 UI |
| `flutter_realtime_live_ui` | 独立直播互动 UI |
| `flutter_realtime_whiteboard_ui` | 独立白板 UI |
| `flutter_realtime_shared_content_preset` | 共享内容/白板与课堂功能预装组合 |

**发布边界：** 以上 44 个均为内部开发模块，其中一些仍缺独立 README /
CHANGELOG / repository 元数据。它们**不计划各自上架 pub.dev**。
真正需要审计的是聚合后的一个 `flutter_realtime_sdk` 发布包。
本文只覆盖**内部功能定位与组合关系**，不能代替单包的
许可证审计、完整 API 参考和真实设备验收。当前单包审计命令：

```sh
python3 scripts/audit_single_pub_package.py --strict
```

单包发行阻断请优先运行：
`python3 scripts/audit_single_pub_package.py --strict`。

继续阅读：[主 SDK 包说明](../packages/flutter_realtime_sdk/README.md)、
[运行时 SDK API](APP_INTEGRATION_QUICKSTART.zh-CN.md)、
[可组合 UI](REALTIME_DESIGN_SYSTEM.md)、
[角色语义](REALTIME_DESIGN_SYSTEM.md)、
[云录制](CLOUD_RECORDING.md)、
[pub.dev 发布准备](PUB_DEV_RELEASE_GUIDE.zh-CN.md)。


---

## Provider Adapter 扩展规范

### Explicit lightweight composition

Applications should use `Realtime(providers: …)` from
`flutter_realtime_sdk_runtime` with optional provider bundles. Driver registration
and platform selection stay inside each bundle; Web resources are local to the
selected package. Custom adapters can expose `RealtimeProviderBundle` without
depending on an all-provider SDK. See the lightweight integration guide and
unified acceptance checklist in `doc/` (or the current documentation directory).

轻量接入保留统一请求、事件和房间类型；平台路由在注册包内部完成。
产品聊天缓存可配置，跨供应商服务端历史分页与真实连麦另行推进。

### Quality contracts

Use the public runtime library to register a bundle. Media and product Chat are independent. Add an optional `RealtimeProviderPlugin.effectsProbe` callback for processed-video capability; platform channels and input probes belong to the provider. An unregistered probe grants no additional effect capability. Failed probes are retryable and diagnostic.

Translate failures to the shared `RealtimeException`/`RealtimeErrorCode` contract. Keep third-party implementation imports in the documented native bridge boundary. Inject provider SDK construction for lifecycle fault tests. Disposal shares one future, attempts all resource stages and retains primary join failure plus rollback failures.


---

## 可信互动事件与依赖原则

### Contract boundaries

1. **Transient event:** transport delivers a versioned, room-scoped envelope;
   the sender field in its JSON is *not* a trusted identity. Transport adapters
   validate the authenticated sender when the provider exposes one. Delivery
   is best-effort and does not establish authoritative shared state.
2. **Command:** application-specific actions requiring permission, billing or
   durability go through an injected trusted control plane. RTC Data / IM
   messages can notify clients to fetch the updated snapshot, but cannot
   authorize a teacher grant or debit currency.
3. **Snapshot:** late join and reconnection require a trusted state fetch and
   monotonically increasing revision. Countdown uses a server `endsAt`, not
   local timers as the source of truth.
4. **Plugin:** core exposes feature registration, lifecycle and capabilities
   without importing classroom, gift, HTTP or UI types. Prebuilt modules supply
   their existing repository and business behavior; consumers may register
   their own features.

### Opt-in prebuilt features (Classroom and Live)

The existing business functionality is **not moved to the Demo or reimplemented**.
Classroom and Live are separate **optional SDK packages**, rather than
dependencies of the generic SDK runtime:

- `flutter_realtime_classroom_preset` provides `ClassroomPreset`, typed
  `RealtimeRoomClassroomExtension`, the existing classroom business session,
  whiteboard, content share and annotation adapters.
- `flutter_realtime_live_preset` provides `LivePreset`, typed
  `RealtimeRoomLiveExtension`, existing like/gift sessions and their repository.

Applications explicitly import the desired package(s):

```dart
import 'package:flutter_realtime_classroom_preset/flutter_realtime_classroom_preset.dart';
import 'package:flutter_realtime_live_preset/flutter_realtime_live_preset.dart';

final realtime = Realtime(
  providers: createMyProviders(),
  backendUrl: myBackendUrl,
  featurePlugins: const [
    ClassroomPreset(),
    LivePreset(),
  ],
);
final connection = await realtime.open(request);
final room = connection.mediaRoom!;
await room.readyFeatures(); // preset availability is safe to inspect
final classroom = room.classroom;       // null without an eligible preset
final live = room.liveInteractions;     // null without an eligible preset
```

The simplified Demo explicitly depends on and registers both plugins. Integrators omitting
`featurePlugins` never instantiate these sessions, even if room metadata says
the backend supports classroom or gifts. The existing `room.classroom` and
`room.liveInteractions` accessors are **extension getters from the corresponding
optional package**, rather than members of `RealtimeRoom` itself. This keeps
generic Runtime free of business type imports while allowing existing UI
components to use the same names. The original HTTP
repositories and the existing IM/RTC revision adapters are reused, and each
preset also accepts an optional host-provided `repositoryFactory`. The
Classroom preset is eligible for backend meeting rooms; Live requires the
`liveInteractions` room metadata flag. Applications using direct provider
credentials can explicitly set `enableForDirectRooms: true` and inject a
trusted `repositoryFactory` for either feature. Disabled/ineligible presets do not
allocate repositories. The feature registry handles teardown even if a
plugin fails or finishes attaching after the room has been disposed.

#### Core dependency boundary and remaining acceptance

`flutter_realtime_sdk_runtime/pubspec.yaml` now keeps business-specific
`classroom_core`, `live_core`, `whiteboard_core` and
`screen_annotation` out of its production dependencies. Its development
tests may still import the optional presets and those cores as dev
dependencies. `flutter_realtime_sdk` also does not declare a runtime
dependency on the presets. Optional `flutter_realtime_sdk_ui` currently
depends on both presets because it supplies both domain component sets;
further UI-only splitting remains a separate planned refinement.

**Still to verify:** real dual-client delivery and state recovery across each
provider/platform, complete Demo widget E2E and cross-platform build checks.
The current unrelated Media UI worktree contains unresolved references to
`RealtimeUiTokens` / `RealtimeStrings` and must be reconciled before those
widget/build tests can be accepted. Product Chat is *not* a general
authenticated interaction event transport here: it carries revision hints,
while transient events stay RTC-Data-only until an identity-aware IM adapter
is available.

#### Existing worktree

At plan start, the worktree already contains unrelated uncommitted Demo,
Pre-Join, Chat and UI edits, plus classroom notification overlay work. Keep
those changes intact; do not reset, overwrite or mix into refactor commits.


---

## 资源所有权与质量门禁

### Dependencies

Foundation is pure Dart. Domain cores depend on foundation and other required domain contracts. Runtime depends on cores and platform/processed-video controllers, with no bundled provider or built-in UI dependency. Provider bundles depend on runtime contracts and their adapters. SDK UI assembles domain views over runtime. The public `flutter_realtime_sdk` now depends only on Runtime; UI and Provider bundles are chosen by the host.

`Realtime(providers: …)` explicitly composes bundles; `Realtime.standard(drivers: …)` is an advanced explicit-driver option and does not select a built-in catalog. The connection, room, event and failure types are shared through the runtime's public library. Media and product Chat remain independently composable. Classroom/Live auxiliary sessions start in Runtime independent of UI mounting.

### Resource ownership

Sessions own connections and native resources. Room wrappers own subscriptions, shared-content coordination and the clients created for that room. UI owns input controllers, navigation and presentation subscriptions. Applications injecting HTTP clients retain ownership. A preview returned by `createLocalPreview()` must be disposed when cancelled or replaced.

Pre-Join defaults to microphone and camera off. Local preview factories must
defer camera capture until explicit enablement; device enumeration, background
selection and cancellation must not implicitly open it. The selected state is
preserved on room entry. In-app annotation tools float within the current
route's visible safe area and can be dragged outside the drawing canvas;
their overlay disappears with the owning surface.

Every cleanup stage is attempted in dependency order even when earlier stages fail. `CleanupFailure` records the stage, original failure and stack trace. `RealtimeException(cleanupFailed)` exposes an immutable failure list; its printable message contains stage names rather than native/HTTP payloads. Concurrent/repeated disposal shares a single future. Room/session `cleanupTimeout` controls the default ten-second stage limit. A timeout proves that a release attempt exceeded its limit; it does not prove a broken native resource was released.

Join failures retain the primary cause when rollback also fails. Closing owners reject new work and ignore late state callbacks. Internal serialization tails may consume errors already returned to the operation caller; detached UI callbacks require an explicit diagnostic owner.

### Network and protocol

A request deadline covers authentication headers, send, response body and JSON decoding. Timeout aborts the individual HTTP request. An authentication callback completing after cancellation cannot issue a late write. Non-success HTTP status classification remains valid for HTML or corrupt JSON responses. Successful malformed responses use `invalidResponse`.

The executors do not add automatic write retries. Typed classroom and whiteboard commands serialize only at repository boundaries, preserving the existing backend wire contract. Retries of a logical idempotent operation must preserve its event ID. Protocol readers report invalid fields and enums. Public collection-owning models and command payloads are defensive snapshots.

### Provider effects

`RealtimeProviderPlugin.effectsProbe` is an optional provider-owned role/platform probe returning `MediaBackgroundCapabilities`. Runtime does not infer support from a provider name or know a provider MethodChannel. Successful probes are cached per runtime instance and role; failed probes remain retryable and appear in runtime diagnostics. Optional effect failure does not prevent an ordinary preview. Protected publication still requires a compatible processed source and sink.

The LiveKit native external-track bridge is the one approved third-party internal import boundary. It targets the currently declared LiveKit version and the maintained Flutter WebRTC hotfix, and must be checked with native/processed-track tests when either dependency changes. Vendor source is not reformatted by SDK tooling.

### Validation

`scripts/sdk_packages.json` is the shared package inventory. Quality tooling analyzes and tests owned packages, including system annotation and new packages. Architecture checks reject cycles, UI/provider dependencies in runtime, duplicate root Chime implementation and cross-package internal imports outside the documented bridge.

Local tests and builds do not establish real-provider, multi-device, remote pixel, Windows or cloud cleanup acceptance. Those evidence categories remain separate in the acceptance documents.


---

## 应用、Runtime、UI 与后端边界

### 2. 依赖与数据流

```text
┌────────────────── 业务 App / example/ ──────────────────────┐
│  Realtime(providers: ...) / RealtimeRequest / Connection    │
│  Demo 展示 SDK 标准页面（也支持纯 Runtime 自定义 UI）   │
└────────────────────────────┬────────────────────────────────┘
                             │ 公共 SDK API
┌────────────────────────────▼────────────────────────────────┐
│ flutter_realtime_sdk_runtime                                │
│  房间/身份/生命周期、预检、事件、能力查询、Provider 解析      │
└───────────────┬───────────────────────────────────┬─────────┘
                │                                   │
    ┌───────────▼────────────┐        ┌─────────────▼─────────┐
    │ Media/Chat/Classroom/  │        │ Provider Bundles       │
    │ Live/Whiteboard Core   │◄───────│ AWS/LiveKit/Agora/     │
    │ （平台无关的契约）     │        │ TRTC/ARTC、Chat 驱动  │
    └────────────────────────┘        └─────────────┬─────────┘
                                                     │ 供应商 SDK
                                                  RTC / IM 云端
                             ┌───────────────────────┘
                       短期凭证、房间上下文
                      ┌───────────────┐
                      │ Demo Server   │
                      │ 可信控制面    │
                      └───────────────┘
```

完整包集成示例使用真实公开声明：

```dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';
import 'package:flutter_realtime_provider_livekit/flutter_realtime_provider_livekit.dart';

final realtime = Realtime(
  backendUrl: 'http://YOUR_LAN_IP:3000',
  providers: [createLivekitProvider()],
);
final connection = await realtime.open(
  RealtimeRequest.create(
    type: RealtimeExperience.meeting,
    user: const RealtimeUser(id: 'user-1', name: 'Alice'),
  ),
);

// connection.mediaRoom 是解析后的 SDK RealtimeRoom。
// 应用可独立使用 Runtime，或选择性引入 flutter_realtime_sdk_ui 组件。
// 页面离开 / 会话结束时由连接所有者调用：
await connection.dispose();
```

以上片段展示接口用法，**不应在画面刚创建完就立即 dispose**；宿主应在房间页面生命周期结束时释放。加入现有房间使用 `RealtimeRequest.join(type: ..., user: ..., roomCode: '...')`。纯聊天用 `RealtimeExperience.chat`，并处理 `connection.chatRoom` 而不是强行读取 `mediaRoom!`。无后端的高级接入可采用 `RealtimeSource.credentials(...)`，但 token 应由可信服务签发，不在客户端保存供应商密钥。

### 4. 标准页面与组件边界

`flutter_realtime_sdk_ui` 维护唯一的完整页面：`RealtimeRoomView` 根据后端
权威模式选择 `RealtimeMeetingPage` / `RealtimeLivePage`，独立聊天使用
`RealtimeChatPage`。`RealtimeRoomViewConfig` 是对应配置；其模式字段仅作
无后端元数据时的提示，不能授予主播或教师权限。

| 组件 | 所有权 / 责任 |
| --- | --- |
| 标准会议/直播页面 | 响应式排版、侧栏/弹层、工具栏及交互展示 |
| `RealtimeRoomUiController` | 共享 UI 订阅、操作去重、权限与错误投影 |
| `RealtimeMeetingStage` | 聚焦/网格和权威共享内容展示 |
| Runtime `RoomMembersController` | 逻辑 RTC/IM 成员同步与管理 |
| `InitialMediaSettingsController` | 设备与初始媒体设置，处理房间切换竞态 |
| `flutter_realtime_media_ui` | Media Core + 设计系统上的独立组件，无 Runtime/Chat 依赖 |

摄像头、麦克风和屏幕共享仍由 SDK/provider 契约控制；RTC Data 不等于产品
Chat。完整页面和自定义组件共享同一套会话。卸载 UI 只释放订阅和界面资源，
连接所有者在房间路由结束后调用 `connection.dispose()`。

### 6. Demo Server：控制面模块

```text
demo-server/server.ts            导出公开单入口（npm start）
          └── app.ts             Express/注册表/全局中间件/依赖装配
                ├── routes/dashboard-routes.ts      Admin/Health/默认 Provider
                ├── routes/room-routes.ts           Create/Join/Discover/Leave/Close
                ├── routes/chat-routes.ts           独立及附着式 Chat
                ├── routes/interaction-routes.ts    Classroom/Live 互动 API
                └── routes/legacy-chime-routes.ts   参考后端遗留兼容路由
                     ↘ providers/, chat/, classroom/, live/
```

`app.ts` 负责依赖装配、通用中间件、路由注册以及定时回收调度。身份与角色规则、房间解析注册、并发锁/摘要、半关闭失败补偿、管理员会话鉴权、Provider 默认选择与持久化分别交给 `services/room-input.ts`、`room-registry-service.ts`、`room-operations.ts`、`room-closure.ts`、`admin-auth.ts`、`provider-selection.ts`。Dashboard Router 通过显式注入的可读写 Provider 选择状态保持切换行为。Node 服务端只做授权、短期凭证、逻辑房间、成员/互动控制和必要可信 Provider 管理调用；真正的媒体传输由 RTC 供应商负责。HTTP 请求与响应遵循 [MEDIA_BACKEND_CONTRACT](MEDIA_BACKEND_CONTRACT.md)、[CHAT_BACKEND_CONTRACT](MEDIA_BACKEND_CONTRACT.md)，不应因重构改变状态码、鉴权、路径或合同版本。

请勿把 `DEMO_BEARER_TOKEN`、供应商 Secret、`roomOwnerCredential` 写进 Flutter 源码、日志或版本库；生产部署需接入真实业务身份、限流、持久化和可信密钥管理，Demo Server **不是生产后端模板**。
