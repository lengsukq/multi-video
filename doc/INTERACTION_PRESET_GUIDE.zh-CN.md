# Interaction SDK 接入指南：纯功能、课堂预装、直播预装、自定义互动

这是**前端 Flutter SDK**，不是固定的直播产品或课堂应用。应用控制界面、
路由和业务工作流；SDK 负责供应商无关的连接、能力检测、事件、会话生命周期。
已有课堂和直播业务实现作为**可选预装包**保留，Demo 不重新实现它们。

## 选择依赖

| 需求 | 生产依赖 | UI |
| --- | --- | --- |
| 普通 Meeting / Live / Chat | `flutter_realtime_sdk` + 指定 Provider Bundle | 可完全不用 SDK UI |
| 通用瞬时互动 | 上述依赖，使用 `room.interactions` | 应用自己组合按钮和事件展示 |
| 课堂举手、授权、Q&A、公告、作业、倒计时、共享白板 | 再引入 `flutter_realtime_classroom_preset` | 可选 `flutter_realtime_sdk_ui` / `flutter_realtime_classroom_ui` |
| 直播点赞、礼物和统计 | 再引入 `flutter_realtime_live_preset` | 可选 `flutter_realtime_sdk_ui` / `flutter_realtime_live_ui` |

主 SDK 的生产依赖不包含任何 Preset 或 UI；Runtime 也不引入
`classroom_core`、`live_core`、`whiteboard_core` 或系统标注模块。
综合 `flutter_realtime_sdk_ui` 是可选 UI 聚合包，当前仍同时依赖两个业务
Preset；如果只需要纯功能 SDK，请不要引入此 UI 聚合包。

以下片段中 `myProviderBundles` 是应用自己按目标平台注册的 Provider Bundle，
`backendUrl` 是提供连接凭证的可选后台；省略供应商注册细节。

## 1. 纯 Headless 会议

```dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';

final realtime = Realtime(providers: myProviderBundles, backendUrl: backendUrl);
final connection = await realtime.open(
  RealtimeRequest.join(
    type: RealtimeExperience.meeting,
    roomCode: 'room-123',
    user: const RealtimeUser(id: 'alice', name: 'Alice'),
  ),
);
final room = connection.mediaRoom!;
final participants = room.participants;
final caps = room.capabilities;

// 完全不创建 SDK UI。自行订阅 room.states / room.events、渲染视频与控制设备。
// 显式离会时调用；仅卸载应用 Widget 不应该断开 SDK Room。
await connection.dispose();
```

聊天可通过 `RealtimeExperience.chat` 创建独立 Chat 会话，
也能在 Meeting / Live 房间中复用 `room.chat`。没有选装 Preset 时，
通用房间**不会自动创建**课堂或礼物业务 Session。

## 2. 课堂预装（复用现有能力）

```dart
import 'package:flutter_realtime_classroom_preset/flutter_realtime_classroom_preset.dart';
import 'package:flutter_realtime_shared_content_preset/flutter_realtime_shared_content_preset.dart';

final realtime = Realtime(
  providers: myProviderBundles,
  backendUrl: backendUrl,
  featurePlugins: const [ClassroomPreset(), SharedContentPreset()],
);
final connection = await realtime.open(meetingRequest);
final room = connection.mediaRoom!;
await room.readyFeatures();
final classroom = room.classroom; // 此 getter 来自可选包的 extension
if (classroom != null) {
  final sub = classroom.events.listen((event) {
    // 宿主 UI 决定在哪里显示举手/发言授权/Q&A 通知。
  });
  await classroom.raiseHand();
  await sub.cancel();
}
await connection.dispose();
```

`ClassroomPreset` 使用已有的 `ClassroomSession` 和
`HttpClassroomRepository` 处理举手、发言授权等课堂互动。
`SharedContentPreset` 独立提供 `room.sharedContent`（白板、屏幕共享与批注）。
两者可以任意顺序注册：SDK 会先附加已经注册的课堂插件，
再创建共享内容控制器。普通会议也能仅注册 `SharedContentPreset()`
而不加载教学功能。没有对应 Meeting 元数据或凭证时，功能可能不可用；
也可以注入 `repositoryFactory` 对接自己的可信控制面。
完全自定义的直连房间须同时设置
`enableForDirectRooms: true` 和 `repositoryFactory`。

## 3. 直播预装（复用点赞、礼物）

```dart
import 'package:flutter_realtime_live_preset/flutter_realtime_live_preset.dart';

final realtime = Realtime(
  providers: myProviderBundles,
  backendUrl: backendUrl,
  featurePlugins: const [LivePreset()],
);
final connection = await realtime.open(liveRequest);
final room = connection.mediaRoom!;
await room.readyFeatures();
final gifts = room.liveInteractions; // 来自可选包 extension
if (gifts != null) {
  await gifts.sendLike();
  // 订阅 gifts.events / gifts.states 自行决定动画与礼物面板位置。
}
await connection.dispose();
```

`LivePreset` 保留原有 `LiveInteractionSession`、礼物目录、历史与计数；
参考礼物**不涉及资金支付、钱包、充值或结算**。需要真实资金交易时必须由
应用可信服务端完成授权、支付和幂等，不可将 RTC/IM 消息当付款凭据。

## 4. 不依赖 Preset 的自定义互动

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

## 5. 自己实现可复用的 SDK Feature 插件

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

## 信任边界和验收

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
  [互动验收清单](INTERACTION_ACCEPTANCE.md) 单独验证。

详情参见 [架构](INTERACTION_ARCHITECTURE.md)、
[课堂 API](CLASSROOM_SDK.md) 与 [直播 API](LIVE_INTERACTIONS_SDK.md)。

## 交付检查与建议提交批次

代码应按照**逻辑改动**提交，不能用 `git add .` 混入其它正在进行的
首页 / Media UI 视觉修改。建议分为：

1. 通用 Interaction Core、Runtime FeatureRegistry 和单元测试。
2. Classroom/Live 两个 Preset、通用 Revision Transport 与依赖瘦身。
3. SDK UI 组合适配和独立 Classroom/Live Widget 测试。
4. Demo 的注册入口、自定义 Wave、Pre-Join 与导航回归。
5. 架构质量检查、中文/英文能力矩阵及接入文档。

这只是**提交边界建议**，不是已执行的 Git 提交。执行前需复核工作区
已有未提交文件，分批暂存并单独运行相应测试。
