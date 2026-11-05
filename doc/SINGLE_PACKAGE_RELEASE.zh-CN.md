# Flutter Realtime SDK：仅公开 1 个 pub.dev 包的发行方案

> **产品目标：外部开发者只安装 `flutter_realtime_sdk`。**
> 开发根目录（本仓库根）是私有 tooling workspace，`publish_to: none`；44 个内部源码模块
> 同样保持 `publish_to: none`，不逐个发布。发行脚本把这些模块聚合为唯一对外发布包
> `flutter_realtime_sdk`。
> **当前已发布版本为 `flutter_realtime_sdk 0.1.0-dev.25`（2026-11-05）。**
> `0.1.0-dev.1`（2026-10-15）是首个单包预览版，相关发布叙述仅为历史记录，
> 已被后续版本取代，不代表当前版本。
> 真机通话、Windows/Linux、部分供应商组合和第三方许可仍需单独验收，不因包已发布而视为完成。
> 本文为发布工程的唯一目标规范，取代之前“把 44 个包逐个发布 pub.dev”的路线。

## 版本状态

| 版本 | 状态 | 说明 |
| --- | --- | --- |
| `0.1.0-dev.25` | **当前已发布（2026-11-05）** | P1 布局修复：课堂工具弹窗与统计卡片支持 200% 字号；直播无聊天会话时隐藏无效入口；分段控件使用选项数自适应断点。内部包质量检查通过，Chrome 浏览器测试因主机缺少 Chrome 未执行 |
| `0.1.0-dev.24` | 历史版本（2026-11-04） | 修复 IVS 注册时抢占 iOS 全局音频会话；ARTC/Chime 重新启用并通过全量 iOS 编译，但双向声音仍待真机验收 |
| `0.1.0-dev.15` | 历史版本（2026-11-03） | iOS CocoaPods 聚合包、Agora `aosl` 与公开头修复；手机双指白板缩放稳定性 |
| `0.1.0-dev.13` | 历史版本 | 课堂与共享内容预设顺序无关、跨平台 CI 修复 |
| `0.1.0-dev.12` | 历史版本（2026-11-03） | Web 白板事件 ID 与共享内容错误修复 |
| `0.1.0-dev.11` | 历史版本 | 已由后续版本取代 |
| `0.1.0-dev.10` | 历史（2026-10-20） | 会议模式、组合式预览与内容共享 |
| `0.1.0-dev.1` | 历史（2026-10-15） | 首个单包预览版，已被 dev.2–dev.10 取代，不是当前版本 |

dev.1 的“已上传/已发布”叙述只还原当时的首发动作；当前接入、升级和问题定位
一律以 dev.25 为准，不要据此安装或引用 dev.1。

## 目标、边界和必须接受的代价

**宿主的依赖和导入只有一个 SDK 名称。当前已发布版本（dev.25）的声明如下**：

```yaml
dependencies:
  flutter_realtime_sdk: 0.1.0-dev.25
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
// 需要 UI 时，使用同一包导出的 RealtimeRoomView、可组合组件；
// Headless 宿主可以完全不创建任何 SDK Widget。
```

**一个 Pub 包 ≠ 一个 Dart 文件 ≠ 只有一个供应商。**
源代码仍允许拆分为 Runtime、媒体/聊天 Core、平台 Provider、独立 UI 和课堂/直播
Preset，并通过按需**注册**决定运行什么。生成发布包时将内部源码与资源统一装配
到一个包，并由一个公开的 Flutter Plugin 入口协调原生平台。

必须如实说明的取舍：**单一公开包会让所有声明在其 pubspec 中的第三方依赖随之被
解析**，并可能增加原生构建时间、二进制体积和插件冲突概率。
运行时只注册 LiveKit，**不保证** Agora/TRTC 等原生依赖被 Flutter 自动裁剪。
如果将来要求“pub.dev 单依赖 + 未选择厂商原生依赖完全不安装”，通常需要重新考虑
单包目标或引入厂商插件的独立发布包；不能仅靠 Dart Tree Shaking 承诺实现。

## 当前依赖与原生插件审计

```sh
python3 scripts/audit_single_pub_package.py
python3 scripts/audit_single_pub_package.py --json
python3 -m unittest scripts.tests.test_audit_single_pub_package
```

脚本读取 `scripts/sdk_packages.json` 和实际 `pubspec.yaml`、`lib/`、
`assets/`、Flutter 插件声明，汇总**内部库引用、原生注册点、资源包、
第三方依赖和发布阻断项**；`--strict` 会在尚未具备发行资格时退出非 0。
不会读取密钥、改动代码或调用任何云服务。

2026-10-14 初始审计：44 个自有内部包、612 个 Dart 源文件、
515 处指向其他内部包的 `package:` URI、40 个含 path/git 引用的包、
13 个带 assets 的模块、12 种非 Flutter 的第三方依赖名称。
**Android 与 macOS 各有 10 个**插件注册点，iOS 4 个、
Windows/Linux/Web 各 1 个（包含几个只声明平台而不直接使用原生源的包装层）。
这些数据由脚本动态计算，源代码变化后需重新运行，不将它们当作不变量。

## 已实现：生成隔离的 Dart + 六平台原生单包候选（初版 2026-10-15，记录保留）

```sh
python3 scripts/assemble_single_sdk_distribution.py
python3 -m unittest scripts.tests.test_audit_single_pub_package scripts.tests.test_assemble_single_sdk_distribution
cd build/single_sdk_candidate
flutter pub get
flutter analyze
flutter pub publish --dry-run
# 输出位置：build/single_sdk_candidate/（被 Git 忽略，不影响源码包）
```

完整组装器在 Dart 层基础上执行 Android、iOS、macOS、Windows/Linux/Web 子组装器：

1. 保留 44 个内部目录不变，把各自 `lib/` 的 Dart 文件复制进同一
   `lib/src/_bundled/<原模块>/` 命名空间；
2. 将源码中指向内部包的 `package:<module>/...` 引用改成候选包本地 URI，
   并收集 13 个模块的 assets，重写常见 Web 静态资源路径；
3. 在 `lib/flutter_realtime_sdk.dart` 生成**一个** SDK 对外入口，
   导出 Runtime、五套媒体 Provider、Chat Provider、可选 UI 与 Preset；
4. 合并 Android 10 个原生插件、Manifest、Gradle 和 JNI 修复；
   合并 macOS 10 个注册点；合并 iOS 4 个 Swift 注册点；
   为 Windows/Linux 和 Web 生成同包注册入口；
5. 输出独立 Git 发布验证目录，附 LICENSE / CHANGELOG、源码、JS、资源、
   `pubspec.yaml` 和精确范围的第三方压缩 JS 密钥误报排除；
6. 生成不含内部 `path:` / `git:` 的公开依赖清单，并**始终保留**
   `publish_to: none`，直至真正通过全部平台与版权门禁。

### 实际独立宿主验收结果（2026-10-15，历史记录）

> 本表是 2026-10-15 对当时候选（早于 dev.9）的验收证据，保留用于追溯技术方案；
> 它不是对当前已发布 dev.15 的验收结论。当前版本仍待完成的验收项见文末“后续阶段与验收门槛”。

使用 `build/single_sdk_host`（仅依赖单一 SDK 路径包），不是现有大 Demo：

| 检查 | 结果 | 限制 |
| --- | --- | --- |
| Flutter 单入口 / `flutter analyze` | **通过** | 测试涵盖五个媒体 Provider 工厂、课堂/直播 Preset |
| 单元测试 | **17 项通过** | 包装生成、IVS 缓存校验、重复框架处理和预览版分发准备 |
| Android debug APK | **构建成功** | 所有厂商的 native 都会入包；需设备上分别验证 |
| macOS debug `.app` | **构建成功** | 构建不等于真实注册/媒体设备 E2E |
| Web JS release 构建 | **构建成功** | Tencent Chat 依赖仍不能使用 Wasm 构建 |
| iOS Release 真机目标（无签名） | **构建成功，191.9 MB** | IVS 官方 archive 校验后接入；含 Podfile Agora 去重配置；未安装至设备/实测通话 |
| iOS simulator | **不支持当前全量组合** | ARTC framework 只有真机切片；不再归因于 IVS Pod 解析问题 |
| Windows/Linux | **未执行** | 需要对应平台 CI 和媒体功能测试 |
| `flutter pub publish --dry-run` | **19 MB、0 warnings、成功** | 只验证发布文件和元数据，**不编译原生平台** |

Android 独立宿主构建期间，发现 Hyphenate Chat AAR 和 Agora RTC 的 JNI 库
`libaosl.so` 同名但字节不同。候选生成器在构建时移除 Hyphenate AAR 内的
重复副本，保留 Agora 依赖独立的 `io.agora.infra:aosl`，不再需要宿主
`pickFirst`。这避免编译冲突，但两家厂商共存时的运行时 ABI 仍需真机 E2E。

**iOS 依赖修复（2026-10-15）**：删除不可解析的 IVS CocoaPods 名称，
从原模块 `Package.swift` 读取 Broadcast 1.47.0 / Chat 1.0.1 官方 URL 和
SHA-256，在 podspec 收集 vendored frameworks 前校验并解包官方 archive。
Flutter 使用 `:path` 安装插件，CocoaPods 不会执行 `prepare_command`，
因此解析器在 podspec 加载时执行；首次安装需要网络，有缓存可离线构建。
所有 iOS 厂商 XCFramework 均排除在 Pub 文件清单之外。

**dev.15 当前 iOS 宿主安装方式（取代旧版 SwiftPM 混合方案）：**
聚合包仍使用 CocoaPods。宿主 `pubspec.yaml` 应配置
`flutter.config.enable-swift-package-manager: false`，仅对该工程生效；
宿主 `ios/Podfile` 添加 `pre_install`：

```ruby
pre_install do |installer|
  require_relative '.symlinks/plugins/flutter_realtime_sdk/ios/podfile'
  FlutterRealtimeSdk::PodfileIntegration.prepare_agora_infrastructure!(installer)
end
```

这会在两个 Pod 同时存在时保留版本较新的 `aosl` framework 声明，
不删除官方二进制；合包 Podspec 只导出必要 Objective-C 公共头文件，
避免 Swift 模块扫描私有 C++ 头。已验证独立 Demo 的 iOS Debug 真机目标编译；
Agora RTC/Chat 实际同会话共存的 ABI 及通信质量仍需双设备验收。
旧的 `post_integrate` / `deduplicate_agora_frameworks!` 属于
此前 SwiftPM 混用方案，**不要作为 dev.15 的默认集成步骤**。
具体安装细节见
[`scripts/templates/single_sdk_README.md`](../scripts/templates/single_sdk_README.md)。

此外独立的第三方 `flutter_webrtc` fork 必须另行验证功能兼容和许可证；
原型使用 pub.dev 的版本声明并不意味着 fork 差异已得到验证。

## 后续阶段与验收门槛

| 阶段 | 任务 | 完成判据 |
| --- | --- | --- |
| 1：Dart 层聚合 | 整合公共入口、内部 URI、assets，排查命名冲突 | 候选包从单一入口通过 `flutter analyze`、独立宿主编译 |
| 2：Android | 一个对外 Android Plugin 入口向现有子模块原生桥注册，合并 Gradle/Android Manifest/权限、厂商 SDK 依赖 | Android 物理设备 Meeting/Live/Chat、共享屏幕和录制控制验收 |
| 3：Apple | iOS/macOS 统一 Plugin 注册，合并各 podspec、Swift、CocoaPods 与隐私/权限声明，补足视频桥 | iOS/macOS 实机、arm64 DMG、音视频权限与构建通过 |
| 4：Web/Windows/Linux | 同包 JS asset URL、平台注册、Windows/CMake 和 Linux 插件兼容 | 分平台构建、实际页面/多方音视频 E2E 成功 |
| 5：许可证与部署 | 梳理 WebRTC fork、Chime/厂商 SDK、JS 及模型数据再分发许可；复核外部依赖及敏感信息 | 律权审查与密钥扫描通过，无非公开/未知许可证产物 |
| 6：单包发布 | 独立发布 checkout、公开 `pubspec` 与单包文档、统一版本；`flutter pub publish --dry-run` | **一个** `flutter_realtime_sdk` 可发布包，无 path/git、dry-run 无 error，外部 App 只需一个 SDK 依赖 |

必须对**已发布产物**而不是原开发仓库执行第三方宿主验收：
不同设备创建/加入/退出、远端画面比例、Host/Viewer 角色语义、
举手/Q&A 与礼物事件跨端提示、正常/异常退出云录制、安全停止与下载。
原 Demo 项目不作为 pub 包一部分；它应以单包导入运行并显示全部菜单。

## 现阶段的使用方式与安全规则

已有开发宿主可以继续按
[当前开发版接入指南](APP_INTEGRATION_QUICKSTART.zh-CN.md)
使用 `flutter_realtime_sdk` + 选定 Provider 的**本地 path 依赖**。
源码模块仍保留 `publish_to: none`；准备下一个尚未发布的新预览版本时：

```sh
python3 scripts/assemble_single_sdk_distribution.py
python3 scripts/prepare_single_sdk_release.py --version 0.1.0-dev.11
cd build/pub_release/0.1.0-dev.11/flutter_realtime_sdk
flutter pub get
flutter analyze --no-pub
flutter pub publish --dry-run
```

准备器只创建独立目录，不上传、不提交；已存在的版本目录拒绝覆盖。
`FILES.sha256.json` 与 `PREPARATION.json` 保存在包外，用于记录文件与
待验收项。稳定版仍须按上述完整门槛验收，不能使用 `--skip-validation`。
本次只优化发布工具与文档，不更改会议、直播、IM、录制或 Demo 的现有业务 API。

官方依据：[Dart pub.dev 不允许发布含 path/git 依赖的包](https://dart.dev/tools/pub/dependencies)、
[Flutter 单包插件与 federated 结构](https://docs.flutter.dev/packages-and-plugins/developing-packages)、
[Flutter pubspec 插件平台声明](https://docs.flutter.dev/tools/pubspec)。
