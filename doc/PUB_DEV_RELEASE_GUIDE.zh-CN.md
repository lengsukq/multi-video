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

代码只导入 `package:flutter_realtime_sdk/flutter_realtime_sdk.dart`，并显式注册所需 Provider、Preset。并不是运行时只选 LiveKit 就不会安装其他厂商原生依赖。详细接入见 [第三方 App 接入指南](APP_INTEGRATION_QUICKSTART.zh-CN.md)；源码能力与真实验收区分见 [能力复核](SDK_CAPABILITY_MATRIX.zh-CN.md)。

## 下一次发布：唯一标准入口

文档发生改动时先执行 `python3 scripts/check_sdk_doc_links.py`；它会检查
10 份主题文档和自动生成声明的存在性、跨仓库 README 的本地链接及代码块闭合。

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

详细聚合原理见 [单包发行架构](PUB_DEV_RELEASE_GUIDE.zh-CN.md)。返回 [文档导航](README.md)。


---

## 单包分发的技术边界

### 形态与依赖边界

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

### 发行组装链

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

### 技术与验收边界

1. **公共 API 稳定**：从一个 import 解析 Provider 工厂、可选 UI / Preset，不向宿主泄漏内部模块路径。
2. **RTC 权限**：创建者的逻辑房主身份和 RTC 媒体角色可不同，服务端提供最终授权；不能根据客户端“点击创建”推断可管理所有成员。
3. **多平台构建**：Android/iOS/macOS/Web 是重点宿主；Windows/Linux 与 ARTC 设备/模拟器原生依赖仍有独立限制。
4. **跨厂商二进制**：Agora、ARTC、Chime、TRTC、LiveKit 的底层 WebRTC/系统音频依赖共存与授权需单独验收。
5. **功能证据**：源代码声明、测试、构建、真实设备音视频/录制是不同等级，不可互相代替；以 [当前能力复核](SDK_CAPABILITY_MATRIX.zh-CN.md) 为准。
6. **保密与授权**：厂商密钥和长期凭据保留在后端；发布前验证 LICENSE、二进制再分发许可、私有证书和敏感数据清单。

开发者接入请阅读 [第三方接入指南](APP_INTEGRATION_QUICKSTART.zh-CN.md)；其他主题从 [文档索引](README.md) 进入。


---

## 开发环境、Apple 平台与本地构建

### Repository checkout name on iOS

The pub package is named `flutter_aws_chime`, while this GitHub repository is
named `multi-video`. Flutter 3.47.x has a Swift Package
Manager issue for local path plugins when the plugin checkout directory name
differs from the Dart package name. Flutter merged the upstream fix on
August 14, 2026, but that change landed after the Flutter 3.47 branch cutoff
and is not present in the current 3.47 stable line.

For local iOS SwiftPM development, clone the repository into a directory named
`flutter_aws_chime`:

```bash
git clone https://github.com/lengsukq/multi-video.git flutter_aws_chime
cd flutter_aws_chime
```

This limitation affects the repository's own local `example/` path dependency.
Apps that consume a published package are resolved into a package directory
with the correct package identity and are not affected by this checkout-name
workaround.

The CI workflow intentionally checks out the repository as `flutter_aws_chime`
so the SwiftPM build validates the supported consumer layout.

Upstream issue/fix: <https://github.com/flutter/flutter/issues/186881> and
<https://github.com/flutter/flutter/pull/188647>.

### iOS dependency managers

The plugin supports both:

- Swift Package Manager through `ios/flutter_aws_chime/Package.swift`;
- CocoaPods through `ios/flutter_aws_chime.podspec`.

Both dependency managers compile the same Swift source tree under
`ios/flutter_aws_chime/Sources/flutter_aws_chime`.

The full Demo enables SwiftPM by default so the iOS IVS Media/Chat plugins work
with a standard iOS Flutter command. From the `example` directory, use:

```sh
flutter run -d iPhone
flutter build ios --release --no-codesign
```

For a first checkout that needs local `FlutterFramework` SwiftPM shims, the
repository also provides a bootstrap helper (run from the repository root):

```sh
python3 scripts/flutter_ios.py build ios --release --no-codesign
python3 scripts/flutter_ios.py run -d <ios-device-id>
```

This optional helper resolves Dart dependencies from the local cache and
prepares missing iOS SwiftPM Flutter framework shims after a fresh checkout.
It never rewrites `pubspec.yaml` or global Flutter settings. Both iOS and
macOS run directly from `example/` with SwiftPM enabled. Avoid building
both Apple platforms simultaneously because they share generated plugin files.

### Real-device media verification

See [`ACCEPTANCE.md`](ACCEPTANCE.md) for the opt-in physical-device workflow.

### macOS validation

Both Apple platforms now use the **same** `example/` Flutter application.
All eight in-repository macOS native plugin packages previously limited to
CocoaPods have been migrated to SwiftPM. CocoaPods podspecs reuse those native
source trees; no duplicate Dart UI, providers, SDK packages or app hosts exist.

```sh
cd example
flutter run -d macos
flutter run -d iPhone
```

The app-wide SwiftPM toggle remains enabled. Vendor
`tencent_cloud_chat_sdk` and `tencent_rtc_sdk` still do not ship macOS
SwiftPM manifests, so Flutter 3.47 uses its CocoaPods fallback for those two
plugins. This is not a claim that all third-party code is SPM-only. We retain
the CocoaPods Podfile and source-compatible local plugin podspecs.
Local Agora Chat and AWS WebKit plugin resources are bundled via
`Bundle.module` on SwiftPM and CocoaPods resource bundles otherwise.

The same-app macOS Debug build and `flutter run` have passed on macOS 27,
including startup and an active Dart VM Service. They do not prove full
provider end-to-end meeting, recording, background, or screen sharing tests.
Agora's binary frameworks may log duplicate Objective-C classes between
AgoraRtcKit and AgoraScreenCaptureExtension; track this separately before
declaring release readiness.

The legacy macOS .command entrypoints remain available for release and IDE
compatibility, but now call the same standard Flutter SwiftPM commands
without temporarily editing `pubspec.yaml` or Xcode Runner. From the
repository root:

```sh
./run_macos_debug.command
./build_macos_arm64.command
```

For normal debug use the `example/` commands above. They support Flutter
hot reload (`r`), hot restart (`R`) and quit (`q`) without toggling the
manifest. Full installed-DMG/signing QA still requires validation.

#### Validate desktop provider runtime assets

After building the Demo on macOS, check that all provider JS entrypoints are
included in the native Flutter asset bundle:

```sh
python3 scripts/check_macos_provider_assets.py --configuration Debug
python3 scripts/check_macos_provider_assets.py --configuration Release
python3 -m unittest discover -s scripts/tests
```

The arm64 DMG packager runs the Release asset check automatically **before**
creating or installing the app. Native AWS WebKit loads Chime/IVS JavaScript
from `flutter_realtime_provider_aws`, the shared media bridge from
`flutter_realtime_media_web`, and IVS Chat from
`flutter_realtime_provider_ivs_chat`. The core `flutter_realtime_sdk` package
does not bundle these optional provider scripts. Do not hardcode the old
`flutter_realtime_sdk/assets/provider_web_runtime` path in native plugins.

### Apple Silicon release installer and Applications installation

Use an **Apple Silicon Mac** with Flutter, Xcode, CocoaPods, and the Demo's Dart
dependencies installed. On first checkout, resolve packages from `example/`:

```sh
cd example
flutter pub get
cd ..
```

From the **repository root**, run:

```sh
./build_macos_arm64.command
./build_macos_arm64.command --skip-build
```

Or double-click `build_macos_arm64.command` in Finder. It automatically builds
the Demo, creates the DMG, installs/replaces the same application in
`/Applications`, and opens it. If necessary, enable execution once with
`chmod +x build_macos_arm64.command`. The shell entry point invokes the internal
Python packaging utility; you do not need to run a `.py` file yourself.

The DMG tool invokes `scripts/build_flutter_macos.py --release --no-pub`
as a compatibility entrypoint, which now simply delegates to standard
`flutter build macos --release --no-pub` using the same SwiftPM setup as
direct development. It no longer changes Flutter's manifest or removes
macOS native SPM Xcode references. The SwiftPM Release command has built
`multi-video.app` successfully. The DMG packager independently verifies arm64
and creates the archive under `dist/macos/`; the full installed-DMG
workflow still requires user-device acceptance testing.
The DMG contains the `.app` and an `Applications` shortcut for drag-and-drop.
The default `.command` invocation copies the `.app` into `/Applications` and
replaces existing installations of the same application. Replacement is refused for a
different bundle identifier or symlink and stages the new app before swapping
it into place. Close the previous Demo app before replacing it.

The command launches the installed app; `--skip-build` packages the latest
existing Release artifact without rebuilding. If `/Applications` is not writable
for your account, either use the DMG's drag-and-drop install in Finder (macOS
will request authorization if necessary) or pass
`./build_macos_arm64.command --applications-dir ~/Applications` after creating
that directory.
Do not run the Flutter build itself with `sudo`.

#### macOS build lock troubleshooting

The one-click packager holds an advisory lock at
`example/.dart_tool/macos-arm64-package.lock` for its full build/package/install
run. Starting another `.command` while the first is active exits with the
current packager PID instead of letting two builds contend for Xcode's
`XCBuildData/build.db`. The lock is automatically released on normal exit,
failure, or process termination; **do not delete the lock file** (it is
deliberately persistent to avoid races). `--skip-build` also takes this lock
to avoid two installers replacing the same `.app` simultaneously.

Before compiling, the script checks for external builders currently holding
`example/build/macos/Build/Intermediates.noindex/XCBuildData/build.db` via
`lsof` and reports the process names/PIDs. It never kills processes or clears
build files automatically. To diagnose an unexpected `database is locked`
error, stop or wait for the other Flutter/Xcode build first. Once **all**
builds have exited, you may remove only the generated `XCBuildData` directory
and retry; it is unsafe to remove it while Xcode still holds it open. The
`iris_method_channel` / `RealtimeNativeFrameSinks` module resolution errors
are unrelated Swift Package Manager/CocoaPods integration problems and will
not be fixed by deleting `build.db`.

This is a **development DMG**, not a signed/notarized public distribution.
macOS Gatekeeper may require additional approval on other machines. Build
validation proves the main executable supports arm64; it does not replace
device-level tests of bundled media plugins, microphone/camera permissions,
or backend connectivity.


---

## 尚需继续审查的 Clean Code 边界

### 重点模块职责状态

| 模块 | 资源/状态 owner 与边界 | 状态 |
| --- | --- | --- |
| media_room_view | 页面只组装；Chat 展示控制器持有草稿/滚动，成员展示控制器持有目录加载/批量结果，会议舞台持有焦点；布局接收 Widget 和窄回调。全部父 State part 和宽泛 Host 已移除 | 已完成主要职责拆分；弹窗与动作入口继续审查 |
| classroom_panel/tools | 宿主启动会话；问答/名单/反馈/工具独立展示；倒计时只由 timer card 更新；工具命令各自持有展示状态 | 主要拆分完成 |
| pre_join | 整页和组合式组件复用一个 controller；preview owner 独立释放订阅与采集；控制器负责阶段、权限、重试、错误诊断，页面负责导航 | 已统一；继续审查独立组件输入与权限帮助展示 |
| meeting_dock/room_live_components/chat_components | 公共组件已分文件；完整模板保留组装，基础媒体 UI 在轻量包 | 主要组件拆分完成；基础 dock 与完整入口仍需职责复审 |
| provider_web_session_factory | factory、JoinInfo decoder、browser capabilities、preview、role session、snapshot decoder 分离 | 已拆分；真实浏览器/厂商验收待验证 |
| bridge.js | 共享协议与供应商模块分离；构建在仓库 tooling，生成资产进入发布包 | 已拆分 |
| AndroidVideoEffectsSource | Source 编排；CameraX owner、Person segmenter、bitmap converter、texture preview、frame dispatcher 分离；处理线程先排空再释放预览；清理尝试全部 owner | 已拆分；真机与长时性能待验证 |
| demo_join_screen | coordinator 准备 SDK 请求与身份；凭据缓存按后端隔离；room page 独立；widget 管导航和表单展示 | 设置/表单仍需拆分 |
| app/room-routes/chat-routes | app 组装与服务生命周期分离；路由只解析/验证/委派；业务用例负责可信权限与 provider 委派 | 主要拆分完成；继续审查所有权与失败路径 |
| Dashboard | HTML 壳、CSS、API、翻译、登录、Provider、房间、日志与刷新模块 | 已拆分；浏览器操作验收待验证 |
| Agora/LiveKit/TRTC/ARTC/Chime/IVS Dart sessions | 需要把生命周期编排、映射、发布、设备、数据、统计与帧接收分离 | 尚未完成 |
| AWS macOS/IVS iOS 插件 | 需要把注册分发、WebKit/Stage owner、资源、delegate 和视图分离 | 尚未完成 |
