# Flutter Realtime SDK 文档导航

> **当前公开预览版：`flutter_realtime_sdk 0.1.0-dev.27`（2026-11-06）。**
> 这里是 SDK 工作区文档的统一入口。源码中的实现声明、已发布单包和真实设备验收是不同证据层级；以当前源码、具体版本的发布包与设备测试记录分别判断。

## 接入与架构

| 想完成的任务 | 推荐文档 | 说明 |
| --- | --- | --- |
| 第三方 App 从零接入 | [首次接入清单](APP_INTEGRATION_QUICKSTART.zh-CN.md) | **首选**：公开单包、权限、后端、Provider 注册、创建/加入/退出 |
| 自绘 UI / Headless 接入 | [Runtime / 自定义 UI](SDK_RUNTIME_INTEGRATION.zh-CN.md) | 公共 API 用法与内部源码开发 `path:` 示例的区分 |
| 了解内部 44 个模块 | [内部包索引](PACKAGE_INTEGRATION_INDEX.zh-CN.md) | 仅针对 monorepo 源码开发，不代表 44 个独立 pub.dev 包 |
| 加入自己的供应商 Driver | [Provider Adapter 指南](PROVIDER_ADAPTER_GUIDE.md) | Adapter SPI、能力声明和实现边界 |
| 了解互动插件 | [Feature / Preset 接入](INTERACTION_PRESET_GUIDE.zh-CN.md) | 纯功能、课堂、直播、内容共享 |
| 后端协议与鉴权 | [Media Backend Contract](MEDIA_BACKEND_CONTRACT.md) · [Chat Contract](CHAT_BACKEND_CONTRACT.md) | 权威控制面，服务端发短期凭据；Chime 专属旧合同见 [Chime Contract](BACKEND_CONTRACT.md) |

## 能力矩阵与实际验收

| 文档 | 用途 |
| --- | --- |
| **[当前 SDK 代码能力复核（2026-11-06）](SDK_CAPABILITY_AUDIT_2026-11-06.zh-CN.md)** | **首选**：六引擎 × 平台、Chat、屏幕共享、虚拟背景、录制及待验收项 |
| [中文能力矩阵](SDK_CAPABILITY_MATRIX.zh-CN.md) · [English Matrix](SDK_CAPABILITY_MATRIX.md) | 最新 API、能力和平台限制，已删除旧需求验收快照 |
| [自动生成声明](generated/SDK_DECLARATIONS.md) | 从源码注册与 Adapter 提取的 Driver/角色/能力证据，不能手工编辑 |
| [屏幕共享专项](SCREEN_SHARING_PROVIDER_STATUS.md) · [麦克风专项](MICROPHONE_CROSS_PLATFORM_AUDIT.md) | 具体供应商/平台的已实现和未验证边界 |
| [2026-11-04 厂商审查](RTC_VENDOR_PLATFORM_AUDIT_2026_11_04.md) | 有日期的技术调查；版本现状以 11-06 当前复核为准 |
| [统一验收](ACCEPTANCE.md) · [设备验收](DEVICE_E2E.md) | 真通话验收口径；各供应商专项见 [Agora](AGORA_E2E.md)、[ARTC](ARTC_E2E.md)、[TRTC](TRTC_E2E.md) |

## 功能与 UI

| 功能 | 文档 |
| --- | --- |
| 课堂/白板 | [Classroom](CLASSROOM_SDK.md) · [Whiteboard](WHITEBOARD_SDK.md) · [共享画面标注](SYSTEM_SCREEN_ANNOTATION_SDK.md) |
| 直播互动 | [直播礼物、点赞和互动](LIVE_INTERACTIONS_SDK.md) |
| 云录制 | [录制与下载](CLOUD_RECORDING.md) · [布局限制](CLOUD_RECORDING_LAYOUTS.md) · [AWS S3 权限](AWS_S3_RECORDING_PERMISSIONS.md) |
| 内置 UI / 自定义布局 | [UI 组件化验收](UI_COMPOSABILITY_ACCEPTANCE.zh-CN.md) · [设计系统](REALTIME_DESIGN_SYSTEM.md) · [角色语义](ROLE_UI_SEMANTICS.md) |
| 房间退出与清理 | [UI 生命周期](ROOM_UI_LIFECYCLE.zh-CN.md) |
| 头像与资料 | [头像接口](AVATARS.md) |

## 发布与研发

| 目的 | 文档 |
| --- | --- |
| 发新版本 | **[pub.dev 发布清单](PUB_DEV_RELEASE_GUIDE.zh-CN.md)** |
| 了解单包打包原理 | [单包发行架构](SINGLE_PACKAGE_RELEASE.zh-CN.md) |
| 本地开发 / CI | [Development](DEVELOPMENT.md) · [SDK Code Quality](SDK_CODE_QUALITY.md) · [Clean Code 治理](CLEAN_CODE_GOVERNANCE.md) |
| 互动系统设计 | [Interaction Architecture](INTERACTION_ARCHITECTURE.md) · [交互验收记录](INTERACTION_ACCEPTANCE.md) |

## 文档维护规则

1. **新版接入与版本号只以公开发行包和发布清单为准**；内部 `packages/flutter_realtime_sdk` 的 `publish_to: none` 不等于公开单包未发布。
2. **一个主题只有一个当前入口**：首次接入、能力矩阵、发行说明各有权威文档。过期阶段记录直接删除，不建立第二套历史归档。
3. **禁止将编译通过冒充真实厂商验收**；跨平台屏幕共享、录制、双向声音须区分代码/模拟测试/设备测试。
4. 改动 Adapter 后执行 `python3 scripts/generate_capability_matrix.py` 和 `--check`，不手工维护 `generated/SDK_DECLARATIONS.md`。
