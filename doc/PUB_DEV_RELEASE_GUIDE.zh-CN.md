# Flutter Realtime SDK — pub.dev 单包发布清单

> **当前发布形态（2026-11-03）：** 对外唯一发布物是聚合包
> [`flutter_realtime_sdk 0.1.0-dev.15`](https://pub.dev/packages/flutter_realtime_sdk/versions/0.1.0-dev.15)，
> 已于 2026-11-03 发布。44 个内部源码模块与根目录 tooling workspace
> 均保持 `publish_to: none`，不逐个发布。dev.15 在既有会议模式、
> 内容共享及 Web 白板修复的基础上，解决 iOS 单包 CocoaPods/Agora
> `aosl` 冲突和头文件导出问题，并修复移动端白板双指缩放跳动。
> Windows/Linux、真实设备/供应商 E2E 和第三方许可审查仍是独立验收项。
>
> 以下 dev.4–dev.9 条目是按时间保留的历史记录，不是当前发布状态；
> 不要对已发布版本目录重新发布。下一个版本必须使用新的显式版本号，
> 并由维护者审查后手动发布。本指南记录流程，不执行发布或上传。
>
> **历史快照提醒：** 下文候选目录、待发布标记和旧版本命令只还原当时状态，
> 不代表这些版本现在仍未发布，也不能当作当前版本或重新发布指引。

## 当前接入版本

```yaml
dependencies:
  flutter_realtime_sdk: ^0.1.0-dev.15
```

只需导入 `package:flutter_realtime_sdk/flutter_realtime_sdk.dart`。
发布构建由发行脚本聚合源码模块、Provider、可选 UI、Preset 和平台资源，
开发时仍保留分层的多包结构；这两种形态不可混用。

**dev.15 iOS 配置：** 当前聚合包采用 CocoaPods，请在宿主
`pubspec.yaml` 禁用该工程的 SwiftPM：
`flutter.config.enable-swift-package-manager: false`。
在 `ios/Podfile` 使用 `pre_install` 调用
`FlutterRealtimeSdk::PodfileIntegration.prepare_agora_infrastructure!(installer)`，
完整示例见 [第三方接入指南](APP_INTEGRATION_QUICKSTART.zh-CN.md)。
不再使用 dev.13 的私有头文件重写 workaround。

---

## 历史发布记录：dev.7

> 以下仅用于追溯当时修复和发布步骤，不再是待发布候选。
>
> `0.1.0-dev.7` 修复 Web Demo 的 Pre-Join 正常但进入会议/直播后
> 普通摄像头无法启动的问题：无虚拟背景时不再提前绑定处理视频源，
> 模糊/换图仍按需启用；白板切换前刷新课堂版本，只对明确的 409 版本冲突
> 重试一次；会议/直播会显示摄像头和共享内容操作错误。此版本保留 dev.6
> 的 Web 模型/WASM 资源修复。dev.7 目前已被后续版本取代。
> 当时使用 `scripts/publish_single_sdk_dev7.command`，后续版本应使用其对应的
> 版本化脚本与新候选目录，并始终先执行 dry-run。真实浏览器和供应商 E2E
> 验收仍不能由单元测试或 Web 构建替代。

---

> **历史记录（2026-10-15，dev.6 Web 虚拟背景修复）：**
> 当时的 `0.1.0-dev.6` 候选生成至
> `build/pub_release/0.1.0-dev.6/flutter_realtime_sdk/`；当时的候选状态已被后续版本取代。
> 修复两处 `dev.5` 单包问题：Flutter 资产目录不递归导致嵌套
> MediaPipe `vision.js`、WASM、TFLite 文件漏打包；
> 以及 `video-effects-bridge.js` 仍请求内部源码包旧 URL。
> 现已用仅依赖此 SDK 单包的**独立 Flutter Web 工程**完成 Release 构建，
> 并验证生成的 `AssetManifest` 和 8 个 JS/模型/WASM 资源；
> SDK 静态分析及 `flutter pub publish --dry-run` 通过（0 警告）。
> 此检查不等同于不同浏览器、真实摄像头和供应商 E2E 验收。

**历史发布步骤：dev.6** 在仓库根目录执行：

```sh
bash scripts/publish_single_sdk_dev6.command
```

脚本仅操作已准备的 `dev.6` 发布目录，检查包版本号、资源声明和 JS
地址，运行 `flutter pub get`、静态分析与 `flutter pub publish --dry-run`，
当时的脚本要求输入 `PUBLISH 0.1.0-dev.6` 才执行上传；此命令仅为历史记录，不能重发已发布版本。
如果仅需重新检查 Web 资源：

```sh
python3 scripts/verify_single_sdk_web_assets.py \
  --package build/pub_release/0.1.0-dev.6/flutter_realtime_sdk \
  --web-build build/single_sdk_web_smoke/build/web
```

dev.6 Web 资源修复允许第三方宿主不再复制 SDK 内部的 `web/models`、`web/wasm`；当前接入请使用 **`flutter_realtime_sdk: ^0.1.0-dev.15`**。仍需配置
`RealtimeRoomServices(videoEffectsFactory: DefaultRealtimeVideoEffects.new)`
及摄像头权限、HTTPS 或 localhost。此修复仅修改单包的资源组装方式，
并不改变内部源码包的模型路径。

> **历史记录（2026-10-15，dev.5 发布准备）：** `0.1.0-dev.5` 当时生成在
> `build/pub_release/0.1.0-dev.5/flutter_realtime_sdk/`，交由维护者手动发布，
> 本次没有执行上传。该版本修复会议屏幕/白板共享时参会者画面消失的问题，
> 加入主画面切换、缩略图隐藏/恢复和小屏共享工具栏适配。
> 静态分析及发布预检见 `build/quality/pub-dev5-analysis.log`、
> `build/quality/pub-dev5-dry-run.log`；全包检查见 `meeting-sharing-full.log`。
>
> **历史发布核对：** pub.dev 的 `0.1.0-dev.4` 版本元数据记录发布时间为
> 2026-10-15 14:41（北京时间）；当前已发布版本见本文顶部。唯一公开 SDK 包是 `flutter_realtime_sdk`，
> 不单独发布仓库内部 44 个模块。此前原生宿主构建证据不能替代本轮真机、
> 双设备共享与白板验收；Windows/Linux 和第三方许可审查继续保留其待验收状态。
> 此前“先依次发布 44 包、最后再发 Facade”的方案已废弃。
> [单包迁移架构、审计与组装原型](SINGLE_PACKAGE_RELEASE.zh-CN.md)
> 是这次发行准备的技术基线。

## 1. 最终交付形态

```yaml
# 当前已发布预览版
dependencies:
  flutter_realtime_sdk: ^0.1.0-dev.15
```

对外只需要 `package:flutter_realtime_sdk/flutter_realtime_sdk.dart`。
Factory / Runtime / optional Widgets / Classroom & Live Preset 由一个包
统一公开。Provider 仍通过 `Realtime(providers: [...])` **显式注册**；
Headless 宿主可以不使用 UI，但所有写入发行包 `dependencies` 的原生
第三方 SDK 仍可能被 Flutter 构建系统安装。别承诺“只用 LiveKit 就不安装
Agora/腾讯原生依赖”；这是单包与小体积之间的真实取舍。

44 个内部源码包和 Demo 继续用于日常开发/回归，
**不要为了发布而机械删除 Core/Provider/UI 分层**。
发布构建应在独立目录或 release 分支生成最终 Flutter 插件包，
避免打断现有业务迭代。

## 2. 已完成的发布工程基础

仅在忽略的构建目录生成单包候选：

```sh
python3 scripts/audit_single_pub_package.py
python3 -m unittest scripts.tests.test_audit_single_pub_package scripts.tests.test_assemble_single_sdk_distribution
python3 scripts/assemble_single_sdk_distribution.py
cd build/single_sdk_candidate
flutter pub get
flutter analyze
flutter pub publish --dry-run
```

`audit_single_pub_package.py` 输出内部依赖、`package:` 导入、
各平台插件注册点和资产模块；`--json` 便于 CI 分析，
`--strict` 在尚未具备单包发行条件时返回非零。
`assemble_single_sdk_candidate.py` 只装配 Dart；新的
`assemble_single_sdk_distribution.py` 在此基础上整合六平台
Flutter Plugin 原生注册、Gradle/CocoaPods/CMake、JS/资源及发布元数据，
仍只改动忽略的 `build/`，不修改 44 个源模块和 Demo。

**候选不是交付成品。** Android 10 个和 macOS 10 个注册点现已统一，
独立 Flutter App 的 Android APK、macOS App 和 Web 构建均通过。
iOS 4 个桥均进入真机目标构建，IVS Broadcast/Chat 使用原 SwiftPM
声明中的官方 URL 和 SHA-256，由包内解析器在 pod install 时下载/校验。
发布归档排除生成的 `ios/Frameworks/`；宿主不接收重新上传的厂商二进制。
Agora RTC/Chat 通过包内 Podfile helper 移除重复嵌入，接入代码见发布 README。
全量组合的 iOS Simulator 因 ARTC framework 无模拟器切片仍不支持。
Windows/Linux 尚需各自在目标 OS 编译；需要双设备实际音视频和业务 E2E。
**dry-run 已通过不等于原生运行完成，更不等于已发布。**
源码模块和工程候选保留 `publish_to: none`。单独的预览版准备器可以创建
可供 pub dry-run 验证的公开元数据目录，不改源码，不自动上传。

```sh
# 新版本候选示例（版本号必须未使用，已发布版本不可重建）
python3 scripts/prepare_single_sdk_release.py --version 0.1.0-dev.11
# 目录：build/pub_release/0.1.0-dev.11/flutter_realtime_sdk/
```

### README 中英文独立维护

仓库首页由 [英文 README](../README.md) 和
[中文 README](../README.zh-CN.md) 分别维护；源码 Facade 也在
`packages/flutter_realtime_sdk/README.md` 与
`packages/flutter_realtime_sdk/README.zh-CN.md` 中区分两种语言。

**发布到 pub.dev 的文件不能只改仓库首页。** 它们由
`scripts/templates/single_sdk_README.md`（默认英文）和
`scripts/templates/single_sdk_README.zh-CN.md`（完整中文）生成，
发布目录同时包含 `README.md`、`README.zh-CN.md`，双向提供语言链接。
发布脚本会把 `@VERSION@` 占位符替换为目标版本。

如果未发布的候选已经组装、只需调整文档，**不要删除发布目录重新复制代码**，
可以执行仅更新 README 与文件校验清单的安全操作：

```sh
python3 scripts/prepare_single_sdk_release.py --version 0.1.0-dev.11 --refresh-readmes
cd build/pub_release/0.1.0-dev.11/flutter_realtime_sdk
flutter pub publish --dry-run
```

发版前在 dry-run 的文件树中确认中文文件已被包含，并以完整独立宿主进行
音视频验证。以上是当时针对 dev.5 的历史记录；当前接入请使用顶部所列的已发布 dev.15。

## 3. 正式单包发版验收门槛

- [ ] **统一 Dart 公共 API**：确认同名符号没有冲突、
      `createLivekitProvider()/createAgoraProvider()` 等工厂可从单入口调用、
      `ClassroomPreset()/LivePreset()` 及 UI 自由组合可用。
- [ ] **Android 插件合并**：统一注册入口、合并 Gradle / Manifest、
      Kotlin/Java 依赖、权限和厂商 SDK，不丢失各子插件的 channel。
- [ ] **iOS/macOS 插件合并**：整合 Swift/ObjC、podspec、SPM/CocoaPods、
      Bundle/资源、Entitlement、签名、摄像头与麦克风权限。
- [ ] **Web/Windows/Linux**：单包可加载内置 JS 资源、
      Web 平台注册正确；Windows CMake/插件注册、Linux 目标验证。
- [ ] **内外依赖**：发布的 `pubspec.yaml` 完全不含内部
      `path:` / `git:` / 私有仓库依赖（包括 dev_dependencies）。
      外部托管的第三方依赖需满足版本和版权约束。
- [ ] **WebRTC fork 与第三方版权**：核对 `flutter_webrtc` 热修复差异、
      `flutter_aws_chime`、Agora/Tencent/ARTC 原生库、
      Web JS、模型和所有 assets 的再分发许可。
      仓库根 MIT 版权归属不代表第三方内容获得重新发布授权。
- [ ] **文件清单与安全**：单包附正确 README/CHANGELOG/LICENSE；
      `pub publish --dry-run` 实际包含所需 `lib/`、`android/`、
      `ios/`、`macos/`、`windows/`、`web/` 和 assets；
      无任何 App Certificate、Customer Secret、UserSig 私钥、
      AWS/腾讯/阿里云 Key、.env、测试账单或设备配置。
- [ ] **真实外部宿主验收**：新建独立 Flutter App，**仅依赖**
      `flutter_realtime_sdk`；Android/iOS/macOS/Web/Windows 逐平台
      编译，双设备 Host/Guest、Meeting/Live/Chat、音视频比例、
      屏幕共享、礼物/课堂跨端提示、云录制 Stop/下载，
      对不同供应商开展真实 E2E。
- [ ] **版本与发布授权**：确认 pub.dev 名称归属、发行账号、
      版本号与 Tag、CI 自动发布策略、回滚/修复流程。
- [ ] **dry-run 通过**：在**真正合并的原生发行包**目录执行
      `flutter pub publish --dry-run`；不能用
      `--skip-validation` 或仅凭原型候选的 Dart 分析代替验收。

## 4. 日常内部模块的质量门禁（不是 44 次发布）

以下检查保护日常分层开发，与“发布了几个包”无关：

```sh
python3 scripts/check_sdk_architecture.py
python3 scripts/generate_capability_matrix.py --check
python3 scripts/format_sdk.py --check
python3 scripts/check_sdk_quality.py --analyze --test
python3 scripts/check_pub_release_readiness.py --report-only
```

旧 `check_pub_release_readiness.py` 检查的是 44 个**源模块的文档和
元数据完整程度**；它的“44 个未满足发布条件”不代表计划公开 44 个包。
**判断单包发行条件应首先使用**
`scripts/audit_single_pub_package.py --strict`，随后进行真实平台构建和
pub.dev dry-run。

项目最低 Dart 3.12 / Flutter 3.47；如果系统的 `dart` 仍为旧版本，
请用项目对应 Flutter 附带的 Dart/Flutter 工具执行分析与测试。

## 5. 云录制/授权特别说明

Flutter SDK **只持有短期凭据和控制合同**，不能把录制后台服务
（Agora REST Acquire/Start/Stop、AWS S3、MP4 转换、监控/账单）
一起打进 Flutter 客户端。用户退出后防漏停、服务端异常重启后的
任务持久化与成本上限仍需独立后端验收；使用单包不解决服务器侧问题。
参见 [云录制](CLOUD_RECORDING.md) 和
[角色与 UI 语义](ROLE_UI_SEMANTICS.md)。

## 6. 当前结论

**当前已发布的聚合单包预览版为 `0.1.0-dev.15`；稳定版的全面验收尚未完成。**
内部 44 包的 `publish_to: none` 保持不变；独立分发准备器仅支持
`0.1.0-dev.N`，生成真实接入 README、CHANGELOG、文件哈希清单，并排除
iOS 厂商框架和本地缓存。实际上传使用经过 dry-run 的同一目录，由维护者
确认账号与预览版范围后执行；稳定版按第 3 节完成验收。

官方资料：
[pub 不允许上传带 path/git 依赖的包](https://dart.dev/tools/pub/dependencies)、
[Flutter 包与插件开发](https://docs.flutter.dev/packages-and-plugins/developing-packages)、
[pub publish --dry-run](https://dart.dev/tools/pub/cmd/pub-lish)。
