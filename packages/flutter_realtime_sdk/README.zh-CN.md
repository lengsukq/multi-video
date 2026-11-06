# flutter_realtime_sdk（源码开发包）

[English](README.md) · **简体中文**

> **注意：本目录并不是 pub.dev 发布物。**
> 源码仓库中的 `packages/flutter_realtime_sdk` 是仅导出 Runtime 的轻量 Facade，
> `publish_to: none`。正式发布的单包 SDK 由发行脚本把 Provider、UI、Preset
> 等内部模块合并，用户不需要分别安装 44 个开发包。

## 版本说明

- [`0.1.0-dev.15`](https://pub.dev/packages/flutter_realtime_sdk/versions/0.1.0-dev.15)：**当前已发布的聚合单包预览版**，保留会议/直播、内容共享和组合式 UI，修复 iOS CocoaPods/Agora 原生依赖冲突及手机白板双指缩放跳动。
- dev.4–dev.9：较早的历史版本，已由 dev.15 取代。
- 本目录：源码开发使用的 Facade，版本与发布单包不应混为一谈。

## 一、何时使用此目录？

只有计划**修改 SDK 内部实现**，或需要调试独立 Provider 源码时，才用本地路径依赖：

~~~yaml
dependencies:
  flutter_realtime_sdk:
    path: ../multi-video/packages/flutter_realtime_sdk
  flutter_realtime_provider_livekit:
    path: ../multi-video/packages/flutter_realtime_provider_livekit
  # 自由选择可选 UI：
  flutter_realtime_sdk_ui:
    path: ../multi-video/packages/flutter_realtime_sdk_ui
~~~

上面的路径假设宿主 App 和 SDK Checkout 位于同一级目录，请按实际路径调整。

**只想在第三方 Flutter App 接入 SDK，请使用 pub.dev 单包：**

~~~yaml
dependencies:
  flutter_realtime_sdk: ^0.1.0-dev.15
~~~

发布版仅需 `import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';`。
**不要在 pub.dev 单包的宿主工程额外加入内部 Provider/UI 路径依赖。**
发行版的 iOS Podfile、原生平台和许可限制请以**该版本实际发布包**中的英文 README 为准。

## 二、源码 Facade 的基本用法

~~~dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';
import 'package:flutter_realtime_provider_livekit/flutter_realtime_provider_livekit.dart';

final realtime = Realtime(
  backendUrl: 'https://your-backend.example',
  providers: [createLivekitProvider()],
);

final connection = await realtime.open(
  RealtimeRequest.join(
    type: RealtimeExperience.meeting,
    roomCode: '123456',
    user: const RealtimeUser(id: 'user-1', name: 'Alice'),
  ),
);
final room = connection.mediaRoom!;
// 用 room.states / room.events 驱动自己的 UI。
// 仅在真正离开房间时：await connection.dispose();
~~~

通过 `RealtimeRequest.create` 创建房间，通过 `RealtimeRequest.join` 加入。
`RealtimeExperience.meeting`、`live` 和 `chat` 分别对应会议、直播和独立聊天。
需要预入会时，可以使用 `Realtime.preJoin` 与 `createLocalPreview`，并由应用负责预览会话的关闭。

使用 `RealtimeSource.credentials(...)` 可以接入自有可信后端签发的短期凭据。
不要将供应商 App Certificate、云密钥等写入客户端。

## 三、UI、互动与 Headless

- SDK UI 独立包：`flutter_realtime_sdk_ui`；提供可组合按钮、视频网格、默认会议/直播页面。
- 课堂：独立导入 `flutter_realtime_classroom_preset` 并注册 `ClassroomPreset()`。
- 白板/屏幕共享：独立导入 `flutter_realtime_shared_content_preset` 并注册
  `SharedContentPreset()`；与 ClassroomPreset 同时启用时无需手动控制顺序。
- 直播：独立导入 `flutter_realtime_live_preset` 并注册 `LivePreset()`。
- 没有 UI 依赖也可以使用 Runtime 的媒体、聊天与业务事件接口。
- 礼物/点赞是非支付互动，需要后端授权与状态同步。

**第三方 Headless Demo 的虚拟背景修复：** 新版本 Runtime 提供
`room.setCameraEnabled(true/false)`。此调用与
`room.setBackgroundEffect(...)` 串行化，避免关摄像头选背景后，直接调用
底层 `media.session.setVideoEnabled(true)` 导致摄像头源状态不一致。
源码开发时如需实际背景处理，还需配置视频特效 Factory；
已发布的 pub.dev 单包 `0.1.0-dev.15` 可从公共 import 获取
`DefaultRealtimeVideoEffects`。请始终检查能力支持，并处理初始化异常。

详见 [SDK / Headless 接入](../../doc/APP_INTEGRATION_QUICKSTART.zh-CN.md)。
宿主自己拥有 UI 与路由，SDK 自己拥有媒体会话；销毁 Widget 不代表离开房间。

## 四、供应商与平台

运行时显式注册所需的 Provider Bundle，例如 LiveKit、Agora、TRTC、ARTC 和 AWS；
聊天可独立选择 Agora Chat、Tencent Chat 或 IVS Chat。AWS Meeting 对应 Chime，
Live 对应 IVS。请根据 [能力矩阵](../../doc/SDK_CAPABILITY_MATRIX.zh-CN.md)
判断平台、角色和功能；仅有接口不等于通过真机验收。

## 五、更多资料

[仓库中文首页](../../README.zh-CN.md) ·
[首次接入清单](../../doc/APP_INTEGRATION_QUICKSTART.zh-CN.md) ·
[单包发行方案](../../doc/PUB_DEV_RELEASE_GUIDE.zh-CN.md) ·
[云录制](../../doc/CLOUD_RECORDING.md) ·
[Demo](../../example/README.md) ·
[pub.dev 发行清单](../../doc/PUB_DEV_RELEASE_GUIDE.zh-CN.md)
