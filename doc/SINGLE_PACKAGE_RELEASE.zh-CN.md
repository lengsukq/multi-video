# Flutter Realtime SDK：单包发行架构

> **当前公开版本：`flutter_realtime_sdk 0.1.0-dev.27`。**
> 本页只说明**当前的技术实现与设计取舍**；发布步骤统一维护在 [发布指南](PUB_DEV_RELEASE_GUIDE.zh-CN.md)，不再维护历代预览版历史。

## 形态与依赖边界

- **对外**：pub.dev 唯一插件包 `flutter_realtime_sdk`，提供公开 `Realtime`、Provider 工厂、Media/Chat、RTC UI、Classroom/Live/SharedContent Preset 和相关平台桥。
- **对内**：44 个模块仍独立开发（Runtime、Core、Provider、UI、Preset、Native Bridge），均 `publish_to: none`，其单独 `path:` 引用仅适合源码开发宿主。
- **运行时**：宿主仍须显式注册 Provider 和 Preset，按会议/直播模式与实际媒体能力路由；不支持的平台应有明确错误，不在 Core 写死供应商逻辑。
- **依赖取舍**：虽然对外只有一个 Pub 依赖，单包列出的多厂商原生插件仍可能全部参与 CocoaPods、Gradle 和链接流程；**按需注册不等于按需安装二进制**。

```yaml
dependencies:
  flutter_realtime_sdk: 0.1.0-dev.27
```

```dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';

final realtime = Realtime(
  backendUrl: 'https://your-backend.example',
  providers: [createLivekitProvider()],
  featurePlugins: const [
    ClassroomPreset(),
    SharedContentPreset(),
    LivePreset(),
  ],
);
```

## 发行组装链

| 阶段 | 保留的标准工具 | 输出与职责 |
| --- | --- | --- |
| 模块架构与源代码质量 | `check_sdk_architecture.py`、`check_sdk_quality.py`、`generate_capability_matrix.py` | 验证源代码结构与能力声明 |
| 合并公共 Dart API | `assemble_single_sdk_candidate.py` | 将内部模块代码重写并合并到聚合包命名空间，消除公开包的内部 `package:` 引用 |
| 平台与资产组装 | `assemble_single_sdk_distribution.py` 及 `assemble_single_sdk_android/ios/macos/desktop.py` | 合并原生插件入口、Podfile/Gradle/CMake、Web JS 与静态资源 |
| 发布候选 | `prepare_single_sdk_release.py` | 只创建全新版本候选，准备包元数据、双语 README、CHANGELOG 和校验清单；不上传 |
| 发布资源审计 | `audit_single_pub_package.py`、`verify_single_sdk_web_assets.py` | 检查内部/第三方依赖、发布资源与 Web 静态资产 |
| 正式发布 | `publish_single_sdk.command` | 质量门禁 + 组装 + dry-run + pub.dev 交互式确认 |

典型候选路径为 `build/pub_release/0.1.0-dev.N/flutter_realtime_sdk/`，
`FILES.sha256.json` 与 `PREPARATION.json` 位于其父目录，保留不覆盖的完整源代码快照。二进制缓存、下载的厂商 Framework 和 Flutter 本地状态不应混入上传归档。

## 技术与验收边界

1. **公共 API 稳定**：从一个 import 解析 Provider 工厂、可选 UI / Preset，不向宿主泄漏内部模块路径。
2. **RTC 权限**：创建者的逻辑房主身份和 RTC 媒体角色可不同，服务端提供最终授权；不能根据客户端“点击创建”推断可管理所有成员。
3. **多平台构建**：Android/iOS/macOS/Web 是重点宿主；Windows/Linux 与 ARTC 设备/模拟器原生依赖仍有独立限制。
4. **跨厂商二进制**：Agora、ARTC、Chime、TRTC、LiveKit 的底层 WebRTC/系统音频依赖共存与授权需单独验收。
5. **功能证据**：源代码声明、测试、构建、真实设备音视频/录制是不同等级，不可互相代替；以 [当前能力复核](SDK_CAPABILITY_AUDIT_2026-11-06.zh-CN.md) 为准。
6. **保密与授权**：厂商密钥和长期凭据保留在后端；发布前验证 LICENSE、二进制再分发许可、私有证书和敏感数据清单。

开发者接入请阅读 [第三方接入指南](APP_INTEGRATION_QUICKSTART.zh-CN.md)；其他主题从 [文档索引](README.md) 进入。
