# 第三方 Flutter App 接入 Flutter Realtime SDK（pub.dev 单包优先）

本文面向**不使用仓库 Demo 的宿主应用**，目标是从零完成一次真实的创建/加入/退出。
**当前已发布的单包预览版是 `0.1.0-dev.27`（2026-11-06）。** 普通宿主在 App 目录执行
`flutter pub add flutter_realtime_sdk:0.1.0-dev.27`，并参考
[当前版本发布包 README](https://pub.dev/packages/flutter_realtime_sdk/versions/0.1.0-dev.27)
配置 iOS Podfile、权限与后端。
Scope/Overlay 和离会并发改进始于 dev.15，已包含在 dev.27；之后在源码仓库新增的变更
仍需维护者发布新版本，第三方才可升级并回归验证。

**dev.27 iOS 必需配置：** 聚合包目前仍依赖 CocoaPods，请在宿主
`pubspec.yaml` 的 `flutter:` 下添加：

```yaml
flutter:
  config:
    enable-swift-package-manager: false
```

在 `ios/Podfile` 的 `post_install` 之前添加（如已有 `pre_install`，合并内容）：

```ruby
pre_install do |installer|
  require_relative '.symlinks/plugins/flutter_realtime_sdk/ios/podfile'
  FlutterRealtimeSdk::PodfileIntegration.prepare_agora_infrastructure!(installer)
end
```

这会解决 Agora RTC/Chat 的重复 `aosl.xcframework`；相关修复始于 dev.15，并包含于当前发行包，
同时修复了 Swift umbrella 头文件污染。不要再复制旧版 dev.13 的
手工修改 `source_files` / `public_header_files` 或 Headers 阶段的
Podfile workaround。**双指缩放跳动修复**同样包含在 dev.15：
触点数量变化时保持画布变换，不应影响随后单指绘画。该功能仍需各机型
真实设备手感与跨端同步验收。

**本文同时保留源码开发接入示例**，仅适用于需要修改内部模块的宿主。
Facade + Provider 的多个本地 `path:` 属于仓库开发结构；公开分发只需要
一个 `flutter_realtime_sdk` 包和一个 SDK import。详见
[单包发行工程方案](SINGLE_PACKAGE_RELEASE.zh-CN.md)。
Flutter、Dart、Java 和各平台最低版本详见 [能力矩阵](SDK_CAPABILITY_MATRIX.zh-CN.md)。

## 1. 安装依赖

**公开单包（推荐）：**

```yaml
dependencies:
  flutter_realtime_sdk: 0.1.0-dev.27
```

业务代码只需导入 `package:flutter_realtime_sdk/flutter_realtime_sdk.dart`；
Provider、可组合 UI、Classroom/Live/SharedContent Preset 已在单包导出，
但需显式注册使用的 Provider 和 Preset，不会自动启用全部厂商。

### 源码开发版（仅用于 SDK 内部调试）

假设 `my_app/` 与 `multi-video/` 在同一父目录，
宿主 `pubspec.yaml` 使用：

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_realtime_sdk:
    path: ../multi-video/packages/flutter_realtime_sdk
  flutter_realtime_provider_livekit:
    path: ../multi-video/packages/flutter_realtime_provider_livekit
```

然后在宿主目录执行 `flutter pub get`。上述路径需根据实际 checkout 修改。
想切换/并用供应商，可额外依赖并注册
`flutter_realtime_provider_agora`、`flutter_realtime_provider_trtc`、
`flutter_realtime_provider_artc`、`flutter_realtime_provider_aws`。
需要独立 Agora / Tencent / IVS Chat 的应用另注册对应 Chat Provider bundle；
它们和音视频 Provider **不是同一依赖或同一会话角色**。

**当前开发版**：只做功能不用 SDK 页面，保持以上依赖即可；宿主自行管理路由与 Widget。
**复用会议/直播/聊天组件**：再添加可选 `flutter_realtime_sdk_ui`。
**只复用视觉设计**：再添加独立 `flutter_realtime_design_ui`，不启动媒体会话。
仅需独立聊天室 UI 也可单独使用 `flutter_realtime_chat_ui`。

**注意：**外部单包依然要在 `Realtime(providers: ...)` 中指定启用的供应商；
**不保证**未选用厂商的原生依赖会被自动移除。

如果第三方要展示白板，在 `Realtime` 上显式注册
`featurePlugins: const [SharedContentPreset()]`；如需课堂互动，注册
`featurePlugins: const [ClassroomPreset(), SharedContentPreset()]`。
注册顺序不会改变课堂与共享内容的绑定。后端仍须实现相应
`/classroom/snapshot` 和 `/classroom/action` 控制面；
仅创建 `RealtimeRoomView` 并不能代替服务端权限与状态接口。

## 2. 配置可信后端并选定 Provider

必须先有能从终端访问、能签发**短期入会 Token** 的可信后端，
并提供 SDK 所需的 Backend Contract。开发时可启动本仓库
[demo-server](../demo-server/README.md)，生产可自行实现
[Media Contract](MEDIA_BACKEND_CONTRACT.md) 和
[Chat Contract](CHAT_BACKEND_CONTRACT.md) 或注入自定义凭据服务。
RTC/IM 的 App Certificate、SecretKey、Customer Secret 和 S3 密钥**不进入客户端**。

示例仅注册 LiveKit：`backendUrl` 指向你的可信后端，
并不是 LiveKit 的 WebSocket 地址。

```dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';

final realtime = Realtime(
  backendUrl: 'https://your-backend.example',
  providers: [createLivekitProvider()],
);
```

本机开发 URL：Mac/PC 运行应用一般用 `http://localhost:3000`；
Android 模拟器用 `http://10.0.2.2:3000`；
**物理手机的 localhost 是手机自己**，应使用局域网可达地址或 HTTPS 域名。
真实部署应采用 HTTPS、身份鉴权、最小权限及服务器端审计。
不同 Provider bundle 的工厂入口见 [主 SDK 包说明](../packages/flutter_realtime_sdk/README.md)。

## 3. 创建 / 加入：三种体验只改 Request

```dart
final user = RealtimeUser(id: 'stable-user-1', name: 'Alice');

// 创建会议；广播创建者改成 RealtimeExperience.live。
final creator = await realtime.open(
  RealtimeRequest.create(
    type: RealtimeExperience.meeting,
    user: user,
  ),
);

final roomCode = creator.mediaRoom!.media.roomCode;
// 在房间仍有效期间保持 creator 引用，退出才 dispose。

// 另一台设备、另一位用户的加入示例：
final guest = await realtime.open(
  RealtimeRequest.join(
    type: RealtimeExperience.meeting,
    roomCode: roomCode,
    user: const RealtimeUser(id: 'stable-user-2', name: 'Bob'),
  ),
);

// 显式退出；不要在视频组件单纯重建/换页面时意外断开会话。
await guest.dispose();
await creator.dispose();
```

独立 IM：`RealtimeExperience.chat`，连接后使用 `connection.chatRoom!`
及 `connection.chatSession`，而非 `mediaRoom`。
服务端必须配置独立 Chat Provider；未配置时不要假设它可以自动创建产品聊天室。
普通 Meeting/Live 房间也可能存在附属 `room.chat`，但它与独立 Chat 的权限不同。

## 4. 角色与功能判断：不能凭“创建/加入按钮”

| 场景 | 应读取的连接后信息 | 不应自行推断 |
| --- | --- | --- |
| 会议主持人 | `room.media.isLogicalOwner` **且**操作能力支持 | `MediaRole.host`（会议创建者仍可能是 participant） |
| 会议参会者 | 已加入的 `MediaRole.participant`，无管理授权 | “当前设备首次进入所以是房主” |
| 直播主播 | 服务端授予的 `MediaRole.host` | `role != viewer` |
| 直播观众 | 服务端授予的 `MediaRole.viewer` | 当前屏幕是否有摄像头 |
| 聊天室房主/成员 | 已连接的 `ChatSession.role` | 客户端传入的 ChatRole 请求值 |

正式房间页面的模式优先按服务端返回的 `roomMode` 选择；
加入前 UI 的会议/直播选择不是凭据。即使 UI 隐藏了按钮，
管理操作仍必须由后端进行最终鉴权。接口和异常回退说明参见
[角色语义规范](ROLE_UI_SEMANTICS.md)。

## 5. Pre-Join、权限与平台差异

```dart
final readiness = await realtime.preJoin(
  role: MediaRole.participant, // 直播观众改成 MediaRole.viewer
  roomCode: roomCode,
);
// 宿主读取 readiness 的各项检查，再决定是否继续、显示警告/阻断。
// 需要摄像头预览时使用 realtime.createLocalPreview(...)，退出预览后销毁。
```

Android/iOS/macOS 宿主应申请适当权限与用途说明；macOS 还需 entitlement。
Web 需要 HTTPS 或 localhost 安全上下文。iOS 模拟器、ARTC framework、
Windows Runner、Web Wasm 与移动端屏幕共享均有独立限制，详情看
[平台能力矩阵](SDK_CAPABILITY_MATRIX.zh-CN.md) 和
[屏幕共享状态](SCREEN_SHARING_PROVIDER_STATUS.md)。
**不要把“按钮存在”或“编译通过”写成某平台录屏可用。**

## 6. Headless 或可组合 UI（二选一）

Headless：订阅 `room.states`、`room.events`、
`room.media.session.snapshots`，并由宿主自行渲染与控制；不需要 UI 包。

可组合 UI（需要额外添加 `flutter_realtime_sdk_ui`）：

```dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';

RealtimeRoomUiScope(
  room: creator.mediaRoom!,
  child: const Column(
    children: [
      Expanded(child: RealtimeVideoGrid()),
      Row(children: [
        RealtimeMicrophoneButton(),
        RealtimeCameraButton(),
      ]),
    ],
  ),
);
```

宿主自己放置 `Scaffold`、退出按钮和面板，不需要内置整页。
也可使用 `RealtimeRoomView(room: creator.mediaRoom!)` 做快速演示，
但它不是 Headless 必需依赖。详见
[UI 组件接入](UI_COMPOSABILITY_ACCEPTANCE.zh-CN.md)。

**Scope 与退出注意事项：** `RealtimeRoomUiScope.of(context)` 只能使用位于
`RealtimeRoomUiScope` **子树内部**的 `BuildContext`，不能在创建该 Scope 的页面
`State.context` 中查找它。`showDialog`、`showModalBottomSheet` 和抽屉
是在 Navigator 的 Overlay 路由中构建，不能假设它们自动继承会议页面的 Scope。
`showRealtimeRoomUiDialog` / `showRealtimeRoomUiBottomSheet`
已包含在当前版本（自 dev.15 起提供），使用时显式传入既有 Controller。
退出会议也不能将 `Navigator.pop()` 或仅仅销毁 Widget 当成
`controller.leave()`、`connection.dispose()`。
完整代码和资源所有权说明见
[房间 UI、弹窗与退出生命周期接入指南](ROOM_UI_LIFECYCLE.zh-CN.md)。

## 7. 选装课堂、直播互动与云录制

课堂举手/Q&A/授权发言、Live 点赞/礼物**不是主 SDK 自动开启的功能**。
公开单包直接使用已经导出的 `ClassroomPreset` /
`LivePreset`，在初始化时显式注册
`featurePlugins: const [ClassroomPreset(), LivePreset()]`；
内部源码开发版才需要另加对应模块依赖和 import。
后端还需实现权威状态与权限接口。
见 [互动 Preset 指南](INTERACTION_PRESET_GUIDE.zh-CN.md)。

录制由供应商云端服务及**可信后端**执行，不依赖 Flutter 本地视频捕获；
录制模式、混流限制、存储、停止与 MP4 下载因供应商而异。
当前不是“所有厂商、所有平台均已真实验收”的状态：
请按 [云录制指南](CLOUD_RECORDING.md) 和
[云录制布局](CLOUD_RECORDING_LAYOUTS.md) 分别配置、验证。

## 8. 故障排查与验收

首次接入先确认：

1. `flutter pub get` 成功并注册所需 Provider；单包发布版可能同时解析未启用厂商的原生依赖，不要依赖 Demo 私有的 `demo_provider_catalog.dart`。
2. 设备能访问 `backendUrl`；后端具有真实供应商配置并能签发正确角色的 Token。
3. 创建者与加入者使用**不同 userId / 设备**，加入后房间号及远端成员一致。
4. 观众没有发布权限/主播工具；聊天室普通成员没有房主管理入口。
5. 权限拒绝、重复加入、断线恢复、离开后资源释放能给出有类型的错误。
6. 仅对已经启用并配置过的录制/屏幕共享/互动能力开展实际验收。

仓库本地回归：`python3 scripts/check_sdk_architecture.py`、
`python3 scripts/check_sdk_quality.py --analyze --test`、
`python3 scripts/generate_capability_matrix.py --check`；
供应商真实通话、多人音轨与录制费用仍须现场 E2E。
仓库内 44 个开发子模块仍设置 `publish_to: none` 和内部 `path:` 依赖；
**它们不独立发布，与已上架的 dev.27 单包是两种不同交付形式**；请阅读
[发布准备清单](PUB_DEV_RELEASE_GUIDE.zh-CN.md)。
