# Flutter Realtime SDK 内部 44 模块职责与接入索引

本文中列出的 44 个是**内部源码开发模块**，不是 44 个独立 pub.dev 产品。
**对外当前已发布单包预览版 `flutter_realtime_sdk 0.1.0-dev.27`。**
目前开发版仍需主 Facade + 选定 Provider 的本地 `path:` 依赖；
是否引入 UI 和 Preset 由应用按需决定。内部 Core/Adapter 包的单独使用属于进阶场景。

包名是当前 monorepo 源码包名，**内部子包未分别发布 pub.dev**。开发版依赖使用本地
`path:`，请参考 [独立应用的从零接入](APP_INTEGRATION_QUICKSTART.zh-CN.md)。
单包的聚合与迁移边界见
[单包发行方案](SINGLE_PACKAGE_RELEASE.zh-CN.md)。

## 当前源码开发期的入口（不代表未来 44 个独立发布）

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

## 领域 Core：通常只作为传递依赖

| 包名 | 定位 |
| --- | --- |
| `flutter_realtime_foundation` | 错误模型、HTTP 工具、清理与公共基础能力 |
| `flutter_realtime_interaction_core` | 通用互动消息、版本通知、权威控制面合同 |
| `flutter_realtime_media_core` | 媒体 Session、角色、轨道、能力、录制蓝图 |
| `flutter_realtime_chat_core` | Chat Session、Token/成员、会话能力与管理模型 |
| `flutter_realtime_classroom_core` | Classroom 领域模型、事件与会话 |
| `flutter_realtime_live_core` | Live 互动 Session、点赞与礼物模型 |
| `flutter_realtime_whiteboard_core` | 白板与标注相关的领域合同 |

## 底层 Provider / Platform Adapter（一般不直接选用）

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

## 独立 UI 和其他可选 Preset

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
[运行时 SDK API](SDK_RUNTIME_INTEGRATION.zh-CN.md)、
[可组合 UI](UI_COMPOSABILITY_ACCEPTANCE.zh-CN.md)、
[角色语义](ROLE_UI_SEMANTICS.md)、
[云录制](CLOUD_RECORDING.md)、
[pub.dev 发布准备](PUB_DEV_RELEASE_GUIDE.zh-CN.md)。
