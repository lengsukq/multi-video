# Flutter Realtime SDK：发布与验收指南

> **当前已发布：[`flutter_realtime_sdk 0.1.0-dev.27`](https://pub.dev/packages/flutter_realtime_sdk/versions/0.1.0-dev.27)，2026-11-06。**
> 对外只发布 `flutter_realtime_sdk` 一个聚合 Flutter 插件；仓库内 44 个子模块保持 `publish_to: none`。
> 本指南仅保留**当前版本、下次发版流程和仍需验收事项**，不包含旧版本发布记录或专版发布脚本。

## 当前发行内容

| 项目 | 当前状态 |
| --- | --- |
| 版本 | `0.1.0-dev.27`，pub.dev 已确认接收；已在独立 Demo 中完成依赖解析 |
| 房间退出 | 创建者/逻辑房主退出即结束整个会议或直播；普通参会者/观众仅自己离开 |
| 全员结束通知 | 逻辑关房后其他端通过媒体心跳的 `roomNotFound` 识别退出；高层默认心跳 **5 秒**，并非保证 5 秒内完成厂商强制踢人 |
| UI | 取消主持人退出方式二选一；主持人提示“结束会议/直播”；修复平板 200% 字号下的按钮溢出 |
| 一并包含 | 直播近期礼物提示、LiveKit 视频渲染修复及现有跨平台媒体/课堂功能 |
| 本次已证实 | 单包分析、pub.dev dry-run（0 警告）、发布上传成功；独立 Demo 分析/测试及 iOS 无签名、Android Release 构建 |
| 未完成 | 多供应商真实双端音视频、iOS 系统共享实机出帧、Windows/Linux 目标验证、第三方内容再分发许可审查 |

引用当前 SDK：在应用 `pubspec.yaml` 中使用

```yaml
dependencies:
  flutter_realtime_sdk: 0.1.0-dev.27
```

代码只导入 `package:flutter_realtime_sdk/flutter_realtime_sdk.dart`，并显式注册所需 Provider、Preset。并不是运行时只选 LiveKit 就不会安装其他厂商原生依赖。详细接入见 [第三方 App 接入指南](APP_INTEGRATION_QUICKSTART.zh-CN.md)；源码能力与真实验收区分见 [能力复核](SDK_CAPABILITY_AUDIT_2026-11-06.zh-CN.md)。

## 下一次发布：唯一标准入口

在仓库根目录使用**全新、未在 pub.dev 使用过**的 `0.1.0-dev.N` 版本号。
先将 `scripts/release_notes_current.md` 的唯一版本标题和更新项改成将发布的版本，
再执行以下命令（例如下一候选为 dev.28 时）：

```bash
bash scripts/publish_single_sdk.command 0.1.0-dev.28
```

**不得重复发布已发布的 dev.27，也不要执行已删除的旧版本专用发布脚本。**
执行前检查 `git status`，确认准备发布的源文件与变更范围；旧版已冻结的 staging 目录不可覆盖，发版需要交互式终端确认。

此统一脚本依次完成：

1. 检查 44 个内部包依赖方向、Python 测试、各包分析与测试。
2. 运行课堂、白板、直播和共享内容的浏览器/VM 回归。
3. 使用 `scripts/assemble_single_sdk_distribution.py` 从当前源码组装单包。
4. 使用 `scripts/prepare_single_sdk_release.py --version <新版本>`，从与版本号一致的 `scripts/release_notes_current.md` 生成候选 CHANGELOG、README 和 SHA-256 清单；避免把旧变更说明带到新版本。
5. 核对 Web JS/模型/WASM 资源，在**最终 staging 包**中 `flutter pub get`、`flutter analyze --no-pub`、`flutter pub publish --dry-run`。
6. 最后由 `flutter pub publish` 的 **y/N 交互式确认**执行上传；脚本不会静默自动发布。

浏览器测试要求有可用的 Chromium 系浏览器：若未安装 Google Chrome，可先为可用的 Microsoft Edge 设置 `CHROME_EXECUTABLE`（Mac 实例）：

```bash
export CHROME_EXECUTABLE="/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
```

发布被中断时，**同版本**再次运行统一脚本只会验证已暂存包的哈希并尝试继续，不会自动重新组装当前源码。若是源代码修复，需要选择下一全新版本并重新组装。

仅检查，不上传的基本命令：

```bash
python3 scripts/check_sdk_architecture.py
python3 scripts/generate_capability_matrix.py --check
python3 -m unittest discover -s scripts/tests -q
python3 scripts/check_sdk_quality.py --analyze --test
python3 scripts/audit_single_pub_package.py --strict
```

发布产物生成链保留 `scripts/assemble_single_sdk_candidate.py`、各平台组装器、`scripts/prepare_single_sdk_release.py`、`scripts/verify_single_sdk_web_assets.py` 和 `scripts/publish_single_sdk.command`；旧的分版本脚本及废弃 Git 多包分发器不再使用。

## iOS 宿主注意事项

当前聚合包仍使用 CocoaPods。在宿主 `pubspec.yaml` 的 `flutter:` 下禁用 Swift Package Manager：

```yaml
flutter:
  config:
    enable-swift-package-manager: false
```

在 `ios/Podfile` 添加或合并：

```ruby
pre_install do |installer|
  require_relative '.symlinks/plugins/flutter_realtime_sdk/ios/podfile'
  FlutterRealtimeSdk::PodfileIntegration.prepare_agora_infrastructure!(installer)
end
```

若排查原生二进制互操作，可在安装 Pods 前设置 `FRSDK_IOS_DISABLE_CHIME=1` 或 `FRSDK_IOS_DISABLE_ARTC=1`；默认启用不意味着所有 RTC Objective-C 符号/音频路由已经真机验证。ARTC 官方 framework 可能不包含模拟器切片。有关第三方原生依赖、Podfile 和宿主权限详见 [发布 README 模板](../scripts/templates/single_sdk_README.zh-CN.md)。

## 发布门槛与风险

- 独立宿主仅使用**单个公开 SDK 包**完成依赖解析、平台构建和真实设备测试；内部 44 包通过分析不能代替用户场景验收。
- 核查厂商 SDK、`flutter_webrtc`、JS、模型、资源和二进制的再分发授权，排除任何长期凭据、账号信息及 `.env`。
- 验证主持人关房、普通用户退出、断线重连、异常清理、双向声音、远端画面、共享切出其他 App、云录制停止及下载。
- SDK 仅在客户端保留短期入会凭据；供应商云录制、S3、MP4 和账单控制均属于可信后端职责，见 [云录制](CLOUD_RECORDING.md)。
- **正式稳定版不能仅凭预览包 dry-run 和编译通过宣布完成验收。**

详细聚合原理见 [单包发行架构](SINGLE_PACKAGE_RELEASE.zh-CN.md)。返回 [文档导航](README.md)。
