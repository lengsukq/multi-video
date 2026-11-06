# Flutter Realtime SDK 文档

> 当前公开预览版：`flutter_realtime_sdk 0.1.0-dev.27`。此目录只维护 **10 份主题文档**；自动生成的 Driver 声明单独保留在 `generated/`。旧阶段性文档已合并或删除，仍可通过 Git 历史检索。

| 需求 | 唯一权威文档 | 内容 |
| --- | --- | --- |
| 快速集成 SDK | [接入指南](APP_INTEGRATION_QUICKSTART.zh-CN.md) | 单包依赖、创建/加入、Headless、Preset、自定义互动 |
| 维护模块与扩展 Provider | [架构规范](ARCHITECTURE.md) | 44 包职责、依赖边界、Adapter、事件可信性、质量治理 |
| 开发后端 | [媒体和聊天 API](MEDIA_BACKEND_CONTRACT.md) | Media、Chat、Chime 鉴权、接口、错误、角色权限 |
| 查供应商与跨平台支持 | [能力矩阵](SDK_CAPABILITY_MATRIX.zh-CN.md) | RTC/Chat、屏幕共享、麦克风、虚拟背景、Windows 缺口 |
| 开发课堂/白板/直播 | [功能说明](CLASSROOM_SDK.md) | 课堂、白板、系统标注、直播互动、头像 |
| 接入云录制和存储 | [云录制](CLOUD_RECORDING.md) | 云录制、下载、布局、S3/IAM/MediaConvert |
| 对齐 UI 与生命周期 | [UI 设计与退出](REALTIME_DESIGN_SYSTEM.md) | 响应式、角色、组合组件、退出和清理 |
| 验证真实设备 | [验收手册](ACCEPTANCE.md) | 六引擎 E2E、弱网、音视频、Windows、长连接 |
| 开发、打包、发布 | [开发与发布](PUB_DEV_RELEASE_GUIDE.zh-CN.md) | 本地构建、质量门禁、单包聚合、pub.dev 发布 |

**源码能力 ≠ 自动化测试通过 ≠ 双设备真实验收。** 修改厂商 Driver 后，运行 `python3 scripts/generate_capability_matrix.py` 并检查 [自动生成声明](generated/SDK_DECLARATIONS.md)。修改文档后运行 `python3 scripts/check_sdk_doc_links.py`，验证 10 份权威文档、链接和代码块。发布前按发布手册执行完整质量门禁。

维护原则：同一内容只在一份主题文档维护；跨主题使用链接。不要新增按日期/版本命名的重复审计文档；阶段性数据保留在 Git 历史、测试日志或 Issue。

**变更记录约定：**只维护 `scripts/release_notes_current.md` 作为当前公开版本的说明；`packages/flutter_realtime_sdk/CHANGELOG.md` 保留给发行组装脚本作为必需元数据，第三方 `packages/flutter_webrtc/CHANGELOG.md` 保留上游版本历史。内部未发布的子包不再单独维护 CHANGELOG，相关代码变更从 Git 历史查询。
