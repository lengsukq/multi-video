# multi-video

[English](README.md) · **简体中文**

**multi-video** 是跨平台 Flutter 实时音视频 Demo 和 SDK 源码仓库，提供会议、直播、聊天、课堂互动、内容共享和可选 UI 组件。公开 SDK 包仍然叫 `flutter_realtime_sdk`，本次更名不改 SDK 包名或公开 API；宿主应用可以自由编排 UI，也可以使用 Headless 接口。

## 版本与发布状态

| 版本/形态 | 状态 | 如何接入 |
| --- | --- | --- |
| [`flutter_realtime_sdk 0.1.0-dev.12`](https://pub.dev/packages/flutter_realtime_sdk/versions/0.1.0-dev.12) | **已发布预览版（2026-11-03）** | 新增会议模式、组合式预览与仓库驱动的内容共享，更新会议/直播/聊天/课堂/白板 UI、内置字体和 macOS 麦克风电平表 |
| 源码仓库 | 开发用 | Facade + 选定的 Provider/UI 内部包 |

**不要混淆两种使用方式：** pub.dev 发布物把 44 个内部模块组装为**一个公开 SDK 包**；本仓库开发时仍然是多模块源码，依赖配置不同。支持列表不代表每个供应商和设备都完成实机验收，Windows/Linux、部分平台组合和第三方许可审查仍有待完成。

## 一、安装已经发布的单包 SDK

要求 Flutter ≥ 3.47、Dart ≥ 3.12；合并包原生环境最低 Android API 28、iOS 15、macOS 12。

~~~yaml
dependencies:
  flutter_realtime_sdk: ^0.1.0-dev.12
~~~

已发布的单包 SDK **只需要一个 Dart import**：

~~~dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';

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
// 使用 room.states / room.events 驱动自己编排的 UI。
// 真正离开房间时：await connection.dispose();
~~~

所有供应商都需要在运行时**显式注册**。创建房间、签发短期凭据和执行管理操作需要可信后端；客户端不能保存 App Certificate、签名 Secret、云存储密钥等长期凭据。可以使用 [Demo Server](demo-server/README.md)，也可以通过 `RealtimeSource.credentials(...)` 接自己的后端。

UI 可以选择 `RealtimeRoomView`、组合式按钮/网格，或全部自己实现。课堂预设 `ClassroomPreset` 和直播预设 `LivePreset` 需要显式注册，并依赖后端权限控制；示例礼物不包含支付。

### Headless 摄像头及虚拟背景

已发布的 **`0.1.0-dev.12`** 保留 `room.setCameraEnabled(bool)` 和 `DefaultRealtimeVideoEffects` 导出，并新增会议模式、组合式预览、仓库驱动的内容共享、更新后的会议/直播/聊天/课堂/白板 UI、内置字体和 macOS 入会前麦克风电平表。电平表读取系统默认输入设备，不代表远端实际收到音频。

~~~dart
// 当前已发布的 dev.12 包含此接口：
final realtime = Realtime(
  backendUrl: 'https://your-backend.example',
  providers: [createLivekitProvider()],
  services: const RealtimeRoomServices(
    videoEffectsFactory: DefaultRealtimeVideoEffects.new,
  ),
);

// 入会后先检查 room.backgroundCapabilities 能否支持虚拟背景：
await room.setBackgroundEffect(const MediaBackgroundEffect.blur());
await room.setCameraEnabled(true); // 不直接调用 media.session.setVideoEnabled(true)
~~~

完整的权限判断、摄像头关闭后选背景再开启等流程，参考 [SDK / Headless 接入指南](doc/SDK_RUNTIME_INTEGRATION.zh-CN.md)。不同平台/角色的虚拟背景支持能力并不相同。

## 二、基于仓库源码开发（多模块）

只有准备**修改 SDK 内部实现**时，才需要使用路径依赖：

~~~yaml
dependencies:
  flutter_realtime_sdk:
    path: ../multi-video/packages/flutter_realtime_sdk
  flutter_realtime_provider_livekit:
    path: ../multi-video/packages/flutter_realtime_provider_livekit
  # 可选 UI：
  flutter_realtime_sdk_ui:
    path: ../multi-video/packages/flutter_realtime_sdk_ui
~~~

源码版 Facade 仅导出 Runtime，不会自动依赖或注册供应商与 UI。**不要把上面的多包路径方式与 pub.dev 单包安装方式混用。**

| 内部模块 | 责任 |
| --- | --- |
| `flutter_realtime_sdk` / Runtime | 房间 API、生命周期、平台无关契约 |
| Media/Chat Core 与 Provider Bundle | RTC/IM、能力声明及供应商适配 |
| `flutter_realtime_video_effects` | 处理后的视频源、虚拟背景、摄像头控制 |
| `flutter_realtime_sdk_ui` | 可组合组件和可选的默认会议/直播 UI |
| Classroom/Live/Shared Content Preset | 教学、举手、问答、互动与内容共享 |
| `example/`、`demo-server/` | 演示应用与参考后端，**不是第二套 SDK** |

参阅 [内部模块索引](doc/PACKAGE_INTEGRATION_INDEX.zh-CN.md)、[单包发行设计](doc/SINGLE_PACKAGE_RELEASE.zh-CN.md)、[角色与 UI 语义](doc/ROLE_UI_SEMANTICS.md)。

## 三、运行 Demo

参考后端要求 Node.js ≥ 22.18。请在服务端配置供应商凭据，填入设备能够访问的后端地址：Android 模拟器可用 `10.0.2.2`，物理手机需要局域网地址或 HTTPS 域名。

~~~bash
cd demo-server && npm install && npm start
# 另开终端：
cd example && flutter pub get && flutter run -d macos
~~~

Demo 直接调用 SDK 内置的 Meeting/Live/Chat/Pre-Join 页面，只保留连接配置、导航与示例内容注入，不维护第二套 UI。项目根目录运行 `./build_macos_arm64.command` 可以打包 Apple Silicon macOS **Demo 安装包**，它不是 pub.dev SDK 包。

## 四、平台能力、安全与发布限制

- [供应商与平台能力矩阵（中文）](doc/SDK_CAPABILITY_MATRIX.zh-CN.md) · [English](doc/SDK_CAPABILITY_MATRIX.md)：每项能力与实际设备、平台、供应商及用户角色相关。
- [云录制方案](doc/CLOUD_RECORDING.md)：由可信后端调用供应商云录制与云存储，不依赖 Flutter 本地编码。
- 发布版虽然只需要一个依赖，但仍可能解析和安装**全部内置供应商的原生依赖**。
- Web 摄像头/麦克风需要 HTTPS 或 localhost；iOS/macOS/Android 需要宿主权限配置。
- iOS 单包还需要按照 [SDK 发布模板中的 iOS/IVS/Agora 配置](scripts/templates/single_sdk_README.md)处理 Podfile；部分模拟器、Windows/Linux 和实机组合未验收。
- 单元测试、静态分析、真实供应商互通测试是不同的验收证据，详见 [验收记录](doc/ACCEPTANCE.md)。

## 五、质量检查与详细文档

~~~bash
python3 scripts/check_sdk_quality.py --resolve --analyze --test
python3 scripts/check_sdk_architecture.py
python3 scripts/format_sdk.py --check
python3 scripts/generate_capability_matrix.py --check
~~~

[第三方 App 完整接入清单](doc/APP_INTEGRATION_QUICKSTART.zh-CN.md) · [Headless / SDK Runtime 指南](doc/SDK_RUNTIME_INTEGRATION.zh-CN.md) · [UI 组件化与验收](doc/UI_COMPOSABILITY_ACCEPTANCE.zh-CN.md) · [pub.dev 发布清单](doc/PUB_DEV_RELEASE_GUIDE.zh-CN.md) · [Demo 说明](example/README.md) · [开发环境](doc/DEVELOPMENT.md)

**英文版：** [README.md](README.md)。
