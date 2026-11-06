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
[单包发行工程方案](PUB_DEV_RELEASE_GUIDE.zh-CN.md)。
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
[Chat Contract](MEDIA_BACKEND_CONTRACT.md) 或注入自定义凭据服务。
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
[角色语义规范](REALTIME_DESIGN_SYSTEM.md)。

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
[屏幕共享状态](SDK_CAPABILITY_MATRIX.zh-CN.md)。
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
[UI 组件接入](REALTIME_DESIGN_SYSTEM.md)。

**Scope 与退出注意事项：** `RealtimeRoomUiScope.of(context)` 只能使用位于
`RealtimeRoomUiScope` **子树内部**的 `BuildContext`，不能在创建该 Scope 的页面
`State.context` 中查找它。`showDialog`、`showModalBottomSheet` 和抽屉
是在 Navigator 的 Overlay 路由中构建，不能假设它们自动继承会议页面的 Scope。
`showRealtimeRoomUiDialog` / `showRealtimeRoomUiBottomSheet`
已包含在当前版本（自 dev.15 起提供），使用时显式传入既有 Controller。
退出会议也不能将 `Navigator.pop()` 或仅仅销毁 Widget 当成
`controller.leave()`、`connection.dispose()`。
完整代码和资源所有权说明见
[房间 UI、弹窗与退出生命周期接入指南](REALTIME_DESIGN_SYSTEM.md)。

## 7. 选装课堂、直播互动与云录制

课堂举手/Q&A/授权发言、Live 点赞/礼物**不是主 SDK 自动开启的功能**。
公开单包直接使用已经导出的 `ClassroomPreset` /
`LivePreset`，在初始化时显式注册
`featurePlugins: const [ClassroomPreset(), LivePreset()]`；
内部源码开发版才需要另加对应模块依赖和 import。
后端还需实现权威状态与权限接口。
见 [互动 Preset 指南](APP_INTEGRATION_QUICKSTART.zh-CN.md)。

录制由供应商云端服务及**可信后端**执行，不依赖 Flutter 本地视频捕获；
录制模式、混流限制、存储、停止与 MP4 下载因供应商而异。
当前不是“所有厂商、所有平台均已真实验收”的状态：
请按 [云录制指南](CLOUD_RECORDING.md) 和
[云录制布局](CLOUD_RECORDING.md) 分别配置、验证。

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


---

## 自绘与高级 Runtime 操作

### 2. 创建、加入与退出

```dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';

final realtime = Realtime(
  backendUrl: 'https://your-backend.example',
  providers: [createLivekitProvider()],
);
final connection = await realtime.open(
  RealtimeRequest.join(
    type: RealtimeExperience.meeting,
    roomCode: 'room-code',
    user: const RealtimeUser(id: 'user-1', name: 'Alice'),
  ),
);
final room = connection.mediaRoom!;
final subscription = room.media.session.snapshots.listen((snapshot) {
  // 使用 immutable snapshot 更新宿主自己的任意 UI / 状态容器
});
// 仅当明确退出、销毁业务房间时：
await subscription.cancel();
await connection.dispose();
```

`RealtimeExperience.live` 用于直播；`RealtimeExperience.chat` 用于独立聊天。`RealtimeRequest.create` 与 `join` 使用同一身份结构。也可使用 `RealtimeSource.credentials` 传入业务后端签发的临时凭据，不要求使用仓库的 Demo Server。Web 的 Provider Bundle 自带按需 JS 加载回调；优先使用 `Realtime(providers: [...])` 而非手动拼接资源路径。

### 3. Media、Chat、直播与课堂的纯功能操作

以下 `room.liveInteractions` 与 `room.classroom` 来自可选互动
Preset。公开 dev.27 单包**已导出所需类型，无需额外安装内部模块**，
但仍要在 `Realtime(featurePlugins: ...)` 中显式注册。
只有使用多包本地源码结构时才需要额外依赖并单独导入
`flutter_realtime_live_preset`、`flutter_realtime_classroom_preset`。
未注册的宿主应跳过相关调用，仅使用媒体和 Chat。

```dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';

// 在创建 Realtime 时注册：
// featurePlugins: const [LivePreset(), ClassroomPreset()],
```

```dart
final media = room.media.session;
if (media is InteractiveMediaSession) {
  await media.setMuted(false);
  // 通过 SDK 入口操作摄像头，以便虚拟背景和采集源正确串行化。
  await room.setCameraEnabled(true);
  if (media.capabilities.canScreenShare) {
    await media.setScreenShareEnabled(true);
  }
}

// 使用 Flutter 自己决定视频尺寸、排序、背景等，而不是整页模板：
// MediaTrackView(renderer: room.renderer, track: participant.videoTrack)

final chat = connection.chatSession;
if (chat?.capabilities.canSendMessage == true) {
  await chat!.sendMessage('Hello');
}
await room.liveInteractions?.sendLike(); // 当前房间具备 Live 会话时
await room.classroom?.raiseHand();       // 当前房间具备课堂权限时
```

`RealtimeRoom` 提供 `states`、`events`，底层 `MediaSession` 还提供 `snapshots`；聊天提供 `messageSnapshots`。**事件流为 broadcast，不保证新订阅者收到历史事件，订阅时同时读取当前 state/snapshot。** UI 的创建、重建与销毁不会断开媒体会话，退出请显式 `connection.dispose()`。

#### Headless 第三方 Demo：虚拟背景与摄像头开关

在只使用 **一个 pub.dev 包** 的外部 App 中，构造 `Realtime` 时需要
通过该包公开的 `DefaultRealtimeVideoEffects` 注册效果服务：

```dart
final realtime = Realtime(
  backendUrl: 'https://your-backend.example',
  providers: [createLivekitProvider()],
  services: const RealtimeRoomServices(
    videoEffectsFactory: DefaultRealtimeVideoEffects.new,
  ),
);
```

`RealtimeRoom` 的 `setCameraEnabled` 是 SDK 提供的统一摄像头控制入口。
背景选择和摄像头发布进入相同操作队列；**不应在 Headless UI 中把
`room.media.session.setVideoEnabled(true)` 当作背景摄像头的开关**，
否则会绕过 SDK 对视频处理生命周期的串行保护。

```dart
// 先选背景，此时摄像头保持关闭，不发布原始画面。
if (room.backgroundCapabilities.canBlur) {
  await room.setBackgroundEffect(const MediaBackgroundEffect.blur());
}
await room.setCameraEnabled(true); // 先启用处理源，再进行 RTC 发布
await room.setCameraEnabled(false); // 停止发布和处理采集
await room.setBackgroundEffect(const MediaBackgroundEffect.none());
```

例如在外部按钮事件中，把裸 RTC 的 `setVideoEnabled` 替换为
`room.setCameraEnabled`；切换背景仍调用 `room.setBackgroundEffect`。
如需预设设备/背景，在加入房间后可先调用
`room.prepareVideoEffects(MediaLocalPreviewSettings(...))`，然后开启摄像头。
该 API 不修改其他厂商的业务消息、云录制或 Room 所属权；
不支持背景处理的平台需做 capability 判断并处理异常。

### 4. RTC + IM 成员与权限

与 Widget 无关的统一 RTC/IM 身份合并、成员列表、单人管理、批量静音、部分失败重试已位于 Runtime。

```dart
final directory = room.memberDirectory;
final result = await directory.load(
  room.media,
  chatSession: room.chat,
  chatModeration: room.chatModeration,
  isCurrent: () => true, // 实际集成时检查当前房间是否仍有效
);
final members = mergeSnapshotMembers(
  result.members,
  room.media.snapshot,
  localRole: room.media.role,
);
await directory.manageMedia(
  room.media,
  'target-participant-id',
  RoomMediaMemberAction.mute,
);
final batch = await directory.muteAll(room.media, isCurrent: () => true);
// batch.failures 记录失败成员及对应错误，可按失败成员再次提交 targets
```

Room 所在后端与各 Provider 负责权限最终裁决，SDK 依据能力矩阵拒绝不支持的操作。聊天室的 `room.chatModeration` 与 RTC 的 `room.mediaModeration` 互相独立。批量静音只是多次调用既有权限受控接口，不绕过服务端授权。

**角色语义：** Meeting 创建者通常持有单独的 `media.isLogicalOwner`，
即使其 RTC 角色是 `participant`；Live 只有 `MediaRole.host` 才是主播；
独立聊天使用已连接的 `ChatSession.role` 判断房主/成员。管理按钮须同时检查
**服务端权限和当前能力**，不能仅靠“点了创建按钮”判断房主。详见
[角色与 UI 语义](REALTIME_DESIGN_SYSTEM.md)。

Classroom / Live 可选服务由 `RealtimeRoom.initialize()` **在 Runtime 内启动一次**；UI 控制器不再负责启动，重复调用 initialize 不会重复创建轮询。初始失败通过 Runtime 事件报告，不应把仅课堂/直播辅助服务的错误当成媒体会话断开。退出时由 Room 统一清理辅助会话。

### 6. 可选 SDK UI（当前 Demo 唯一定位）

需要快速搭建页面时，公开 dev.27 单包可直接使用 SDK 导出的 UI 类型；
仅内部多包源码开发需要额外依赖 `flutter_realtime_sdk_ui`：

```dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';

RealtimeRoomUiScope(
  room: room,
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

SDK 同时提供完整页面与可组合组件。`RealtimeRoomView(room: room)` 按后端权威模式选择 `RealtimeMeetingPage` / `RealtimeLivePage`，这就是 Demo 使用的页面；独立聊天使用 `RealtimeChatPage(chatRoom: chatRoom)`，入会准备使用 `RealtimePreJoinPage`。Demo 的 Meeting/Live 适配层只注入背景图片与自定义挥手示例，Chat/Pre-Join 路由直接调用 SDK 页面，不维护第二套布局。完整页面已有桌面侧栏、手机弹层、工具栏收纳、虚拟背景与云录制入口。

宿主依然负责连接、路由和 `connection.dispose()`；卸载页面只清理 UI 资源。可以通过 `RealtimeRoomViewConfig`、`header`、`participantBuilder`、`loadImagePresets`、`onCustomReaction` 和 `stageOverlayBuilder` 调整内置页面，也可继续使用原子组件完全自定义布局。旧页面和兼容模板已移除，不提供旧名字别名。


---

## 自定义互动与插件扩展

### 4. 不依赖 Preset 的自定义互动

```dart
final interaction = room.interactions; // 懒创建，Room dispose 时一起清理
final subscription = interaction.events
    .where((event) => event.topic == 'myapp.reaction.wave')
    .listen((event) {
      // 自己定义 Toast、气泡或其他界面。不要把 payload 当作已验证授权。
    });

if (interaction.capabilities.canPublish) {
  await interaction.publish('myapp.reaction.wave', {'kind': 'wave'});
}
await subscription.cancel();
```

Demo 的 `example/lib/demo_custom_interaction.dart` 用同一套路实现
`demo.reaction.wave` 挥手按钮与限时气泡，不存在 SDK 内置的挥手业务方法，
也**没有另外创建第二套 Demo**。

RTC Data 的 `canPublish`/`canSubscribe`、定向发送和不可靠传输能力取决于
具体供应商及参与者角色。若能力不支持，应用应禁用按钮或给出说明；
**不能静默假装发送成功**。通用 Interaction 瞬时事件不是持久化消息、
课堂发言授权或者晚加入历史。

### 5. 自己实现可复用的 SDK Feature 插件

```dart
class MyPresenceController {
  void dispose() {}
}

class MyPresenceFeature extends RealtimeFeaturePlugin<MyPresenceController> {
  const MyPresenceFeature();
  static const featureKey =
      RealtimeFeatureKey<MyPresenceController>('myapp.presence');

  @override
  RealtimeFeatureKey<MyPresenceController> get key => featureKey;

  @override
  MyPresenceController? attach(RealtimeFeatureContext context) {
    // context.media / context.chat / context.interactions()
    // 此处可建立订阅；没有权限或房间类型不匹配时返回 null。
    return MyPresenceController();
  }

  @override
  void detach(MyPresenceController feature) => feature.dispose();
}

final realtime = Realtime(
  providers: myProviderBundles,
  featurePlugins: const [MyPresenceFeature()],
);
// 房间打开后：
// final feature = room.features.get(MyPresenceFeature.featureKey);
```

对应的公开 SDK API 编译回归测试在
`packages/flutter_realtime_sdk/test/third_party_plugin_example_test.dart`。
如果需要首次权威状态读取，覆盖插件的 `start(T feature)`；
SDK 仅在注册后 attach，每个房间独立初始化，错误彼此隔离，
断开房间时逆注册顺序释放。异步 attach 不应阻塞已经就绪的其他业务包。
`MyPresenceController` 为应用自定义的对象，代码片段只展示插件契约。

### 信任边界和验收

- IM / RTC Data 的版本提示只能用于**触发刷新**；可信身份以供应商传输
  元数据和后端授权为准，不能信任事件 JSON 自带的 `senderId`。
- 举手可作为前端事件展示，但教师发言授权、答题统计、作业历史、礼物支付
  等共享结果必须以**可信控制面**的状态为准。
- 晚加入与重连由权威 Snapshot + 递增 Revision 恢复；倒计时依据服务端
  的 `endsAt` 而不是接收事件时的本地秒表。
- 参考后端在 `demo-server`；无后端模式需由宿主提供适当身份和权威
  Repository，不意味着任意用户都能获得主持人权限。
- 当前自动化验证包括 Runtime、SDK、SDK UI、Demo Widget 与参考后端；
  **实际设备、真实 RTC/IM 供应商消息送达和远端画面**仍须按
  [互动验收清单](ACCEPTANCE.md) 单独验证。

详情参见 [架构](ARCHITECTURE.md)、
[课堂 API](CLASSROOM_SDK.md) 与 [直播 API](CLASSROOM_SDK.md)。
