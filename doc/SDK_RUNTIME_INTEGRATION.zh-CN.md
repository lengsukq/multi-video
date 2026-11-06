# Flutter Realtime SDK：纯功能调用与可选 UI 接入

本指南只提供 SDK 接入方法与**短代码片段**，不新增 Headless 示例工程或第二套 Demo。现有 `example/` 直接展示 SDK 内置页面，同时演示内容与自定义交互的参数注入。

**首次在独立宿主 App 接入**，请先按 [完整分步接入清单](APP_INTEGRATION_QUICKSTART.zh-CN.md)
准备 Flutter 依赖、可信后端、Provider、权限与创建/加入链路。公开单包
`flutter_realtime_sdk: 0.1.0-dev.27` 已发布在 pub.dev。以下多包 `path:`
代码仅用于仓库内部源码开发，**不是外部宿主必需配置**。

## 1. 依赖边界

公开单包宿主只需依赖 `flutter_realtime_sdk: 0.1.0-dev.27`，通过一个 SDK import
获得所有导出 API；仍须显式注册使用的 Provider / Preset。内部轻量开发入口
`packages/flutter_realtime_sdk` 只有 Runtime 生产依赖，按需添加内部
`flutter_realtime_provider_*` 和 UI 模块。**运行时按需注册并不等于公开单包不安装其他厂商原生依赖。**

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_realtime_sdk:
    path: ../packages/flutter_realtime_sdk
  flutter_realtime_provider_livekit:
    path: ../packages/flutter_realtime_provider_livekit
```

其他可选 Provider：`flutter_realtime_provider_agora`、`_trtc`、`_artc`、`_aws`、`_agora_chat`、`_ivs_chat`、`_tencent_chat`。这些后缀均接在 `flutter_realtime_provider` 后面。AWS 公开 Provider 对 Meeting 使用 Chime，对 Live 使用 IVS。不要在 Flutter 客户端保存厂商长期 Secret。

## 2. 创建、加入与退出

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

## 3. Media、Chat、直播与课堂的纯功能操作

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

### Headless 第三方 Demo：虚拟背景与摄像头开关

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

## 4. RTC + IM 成员与权限

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
[角色与 UI 语义](ROLE_UI_SEMANTICS.md)。

Classroom / Live 可选服务由 `RealtimeRoom.initialize()` **在 Runtime 内启动一次**；UI 控制器不再负责启动，重复调用 initialize 不会重复创建轮询。初始失败通过 Runtime 事件报告，不应把仅课堂/直播辅助服务的错误当成媒体会话断开。退出时由 Room 统一清理辅助会话。

## 5. Pre-Join 与平台差异

纯功能调用 `realtime.preJoin(...)` 获取诊断，`realtime.createLocalPreview(...)` 创建可选预览；预览由调用方显式销毁。能力、角色与平台差异均通过 `MediaCapabilities` / `ChatCapabilities` / Provider 注册信息判断。视频虚拟背景、屏幕共享、设备枚举、录制等功能受对应平台与供应商的实际能力限制，不能仅凭统一 API 推断全部可用。

## 6. 可选 SDK UI（当前 Demo 唯一定位）

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

## 7. 验证

从仓库根目录运行 `python3 scripts/check_sdk_architecture.py` 验证主包/Runtime 无强制 UI 与 Provider 依赖；`python3 scripts/check_sdk_quality.py --resolve --analyze --test` 进行跨包静态/自动化验证。真正的供应商双设备 E2E 和平台安装包大小需要单独记录，不能由纯 Dart 测试或 Web JS 字节数代替。
