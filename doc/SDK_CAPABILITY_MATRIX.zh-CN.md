# SDK 当前能力复核（2026-11-09）

> 本文件针对 **SDK 工作区当前源码**（包含未提交改动）进行静态/声明/测试证据核对，而非复制厂商官网宣传表。公开单包最后已确认发布为 `flutter_realtime_sdk 0.1.0-dev.28`；**当前工作树不等同于发布归档的逐文件校验**。本文件只给出本轮能够证明的结论，未实际运行所有厂商的双设备 RTC、真实录制及跨 App 共享。

## 口径与证据

- **Driver**：源码有目标平台注册/路由，不等于原生二进制已可用。
- **实现**：可找到 SDK Adapter、Bridge、API 与资源清理路径；不表示远端实际收到音视频。
- **自动化**：Mock、静态分析、独立宿主编译或浏览器回归；只证明覆盖的调用/布局。
- **真实验收**：需给出厂商账号、端到端设备组合、远端音视频/帧、权限及退出清理结果；不把“按钮显示”“返回成功”“编译通过”算作验收。
- 可复现的声明来自 [自动生成的 Driver/角色/能力声明](generated/SDK_DECLARATIONS.md)，生成器为 `scripts/generate_capability_matrix.py`；运行时真实能力必须由 `MediaCapabilities` / `ChatCapabilities` 按平台、角色和供应商查询。

### 本次更新结论：主仓库与 Windows 工作区必须分开统计

| 引擎 | 主仓库当前 Driver 范围 | Windows 工作区增量 | Windows 验证结论 |
| --- | --- | --- | --- |
| LiveKit | Web、Android、iOS、macOS、Windows | 已有 Windows Driver | 本轮未新增双端 E2E 证据 |
| Agora RTC | Web、Android、iOS、macOS、Windows | 已有 Windows Driver 与处理后视频桥 | 本轮未新增双端 E2E 证据 |
| Tencent TRTC | Web、Android、iOS、macOS、Windows | 已有 Windows Driver 与处理后视频桥 | 本轮未新增双端 E2E 证据 |
| Alibaba ARTC | Web、Android、iOS、macOS；**主仓库尚未合并 Windows Driver** | **本地 Windows x64 C++ 原生插件、Texture、屏幕共享路径已接入** | **Debug 构建 + 原生 SDK 加载/Texture 冒烟测试通过；未做真实双机收发验收** |
| AWS Chime（Meeting） | Web、Android、iOS、macOS WebKit | **没有可用 Windows x64 媒体桥** | 官方 Windows C++ v0.11.2 静态库实查为 x86，不能直接链接 x64 |
| AWS IVS Real-Time（Live） | Web、Android、iOS、macOS WebKit | **没有 Windows 原生媒体桥** | 未验收；WebView2 不能视为官方支持 |

**证据等级：**「Driver 声明」≠「编译与原生库加载」≠「创建本地 Texture」≠「真实双端音视频／录屏正常」。以上 Windows ARTC 的通过记录只证明前三级中的实际测试范围，不等于真实会议、直播或远端渲染成功。Windows ARTC 供应商二进制目前仅安装于 Windows 工作区的 Git 忽略目录 `.local/vendor-cache/`，未合入 macOS 主仓库和已发布的单包。没有相应二进制的外部宿主须失败关闭。

## 一、供应商 × 平台 Driver 声明

| RTC 引擎 | Web JS | Android | iOS | macOS | Windows | Linux |
| --- | --- | --- | --- | --- | --- | --- |
| LiveKit | Driver | Driver | Driver | Driver | Driver | — |
| Agora RTC | Driver | Driver | Driver | Driver | Driver | — |
| Tencent TRTC | Driver | Driver | Driver | Driver | Driver | — |
| Alibaba ARTC | Driver | Driver | Driver | 条件 Driver¹ | — | — |
| AWS Chime（Meeting） | Driver | Driver | Driver | WebKit Driver² | — | — |
| AWS IVS Real-Time（Live） | Driver | Driver | Driver | WebKit Driver² | — | — |

| Product Chat | Web JS | Android | iOS | macOS | Windows | Linux |
| --- | --- | --- | --- | --- | --- | --- |
| Agora Chat | Driver | Driver | Driver | Driver | — | — |
| Tencent Cloud Chat | Driver | Driver | Driver | Driver | Driver | — |
| Amazon IVS Chat | Driver | Driver | Driver | WebKit Driver² | — | — |

### Windows 供应商原生接入进度（2026-11-09，macOS 主仓库尚未合并／发布）

Mac 的 `flutter_multi_livestream_video` 是 SDK 唯一开发／发布主仓库。上表和 [主仓库自动声明](generated/SDK_DECLARATIONS.md)只反映 **Mac 当前源码**，因此 ARTC/Chime/IVS 的 Windows 单元格仍为“—”；Windows 工作区中的未提交修改不能倒填为公开 SDK 能力。

- **ARTC：本地原生基础链路已实现，双端验收未完成。**在 Windows 工作区接入阿里云官方 Windows x64 C++ SDK v7.6.0、`AliRTCSdk.lib/.dll`，增加 Flutter Windows Plugin 注册、Method/Event Channel、入会/离会回调、远端成员/音视频轨道事件、摄像头与麦克风控制、RTC Data、BGRA → Flutter Texture 和屏幕区域共享 API。运行 `flutter build windows --debug --no-pub` 成功；`example/integration_test/windows_artc_bridge_smoke_test.dart` 在 Windows 宿主上通过 `isAvailable` 和纹理注册测试；ARTC Adapter 18 项测试、Flutter 静态分析、44 包架构检查通过。**尚未实测房间鉴权／双人通话、远端音视频帧、共享屏幕的远端画面、反复进退及清理。Windows ARTC 的处理后虚拟背景和摄像头切换仍缺实现。**
- **AWS Chime：x64 原生阻塞已实证。**下载官方 Windows C++ SDK v0.11.2 的 `libamazon-chime-sdk.lib` 并检查 COFF，对象机器码为 `0x014c`（x86），与 [官方 Windows 集成说明](https://github.com/aws/amazon-chime-sdk-cpp/blob/main/guides/setup_windows.md)只支持 x86 的记载相符。**不能将此库直接链接进 Flutter Windows x64。**独立 x86 媒体进程 + IPC、或官方支持的 Electron/JS 运行时 + 媒体桥属于候选方案，尚未实现。Pre-Join 继续失败关闭。
- **AWS IVS Real-Time：Windows 原生接入未实现。** [IVS Web 广播 SDK](https://docs.aws.amazon.com/ivs/latest/RealTimeUserGuide/broadcast.html)不支持嵌入式 WebView，不能直接假设 WebView2 可用；仅有 Windows 平台可用性阻断与错误处理。
- **产品 Chat：**Tencent Chat 已声明 Windows Driver，Agora Chat 和 IVS Chat 尚无 Windows Driver；RTC Data 不能当作完整产品 Chat。

**升级为“Windows 已支持”的门槛：**Windows 原生运行时与构建、真实双端收发音视频／远端 Texture、权限、屏幕共享、消息、断线与销毁全链路通过，且改动回流 Mac 主仓库、更新单包发行装配和测试后，才能进入正式发布声明。

¹ ARTC macOS 需要宿主另行配置官方原生 Framework，仓库不随包再分发，缺少依赖时不可用。² macOS AWS 采用内部 WebKit JS 运行时，不应等同于拥有原生桌面屏幕共享桥。公开 Provider `aws` 根据模式选择 Chime（Meeting）或 IVS（Live）。Web 指常规 JavaScript Flutter Web，**不是**整套依赖已经支持 Wasm。iOS Simulator 受 ARTC 原生二进制限制，不能用无签名设备目标的编译结果推断模拟器可用。

**发包边界：**内部 `packages/flutter_realtime_sdk` 是轻量、`publish_to: none` 的开发入口；对外发布的 `flutter_realtime_sdk 0.1.0-dev.28` 是把内部源码和第三方依赖组装成的**单一 Pub 包**。因此外部宿主只声明一个 SDK 依赖、显式注册 `create*Provider()`，但单包依赖图仍可能安装未选中的原生插件/二进制，按需注册并不等于按需安装。来源：`scripts/assemble_single_sdk_distribution.py`、`scripts/prepare_single_sdk_release.py`、`scripts/templates/single_sdk_README.zh-CN.md`。

## 二、RTC 功能矩阵：能力、角色及边界

| 能力 | LiveKit | Agora | TRTC | ARTC | Chime | IVS Real-Time |
| --- | --- | --- | --- | --- | --- | --- |
| Meeting 双向音视频 | 已实现 | 已实现 | 已实现 | 已实现 | 已实现 | 已实现（但 AWS Meeting 默认走 Chime） |
| Live 房主发布/观众订阅 | 已实现 | 已实现 | 已实现 | 已实现 | 不提供 host/viewer Live 模式 | 已实现 |
| 麦克风/摄像头开关、远端订阅 | 有代码/回归 | 有代码/回归 | 有代码/回归 | 有代码/回归 | 有代码/回归 | 有代码/回归 |
| RTC Data 双向/聊天回退 | 角色允许时 | 房主和普通成员；观众不能发 | 房主和普通成员；观众不能发 | 房主和普通成员；观众不能发 | Meeting 可用 | 无 RTC Data |
| 定向 / 不可靠 Data | 支持（按角色/能力） | 未提供 | 未提供 | 未提供 | 未提供 | 未提供 |
| 设备切换/统计 | SDK 能力较完整，受平台限制 | 统计可用，设备选择适配器不完整 | 统计可用，设备选择适配器不完整 | 设备选择/统计受限 | 原生和 WebKit 不同 | 设备探测/部分切换，基础统计 |
| 服务端管理：关闭逻辑房间 | 有统一控制面 | 有统一控制面 | 有统一控制面 | 有统一控制面 | 有统一控制面 | 有统一控制面 |
| 服务端直接移除 RTC 成员 | 有相关能力 | 不能默认声称支持 | 不能默认声称支持 | 不能默认声称支持 | 不能默认声称支持 | IVS `DisconnectParticipant` 路径 |
| Blur / 图片虚拟背景 | Source/Sink 已接，运行时探测 | Source/Sink 已接，运行时探测 | Source/Sink 已接，运行时探测 | 有条件接入 | 有条件接入 | 有条件接入 |

房主/创建者退出的高层策略按 `room.media.isLogicalOwner` 而非单独按 RTC `MediaRole.host` 判定：点击离开即尝试结束会议/直播；参会者和观众只离开自己。后端 `close` 关闭的是**逻辑房间**，其他在线端由 `room.presence.heartbeat` 的 `roomNotFound` 事件检测并清理，当前高层客户端心跳间隔为 **5 秒**；不保证 RTC 厂商服务端瞬时踢出全部设备。正在进行的课堂/直播轮询可能有在途 404，不能简单将心跳 404 改为 200。代码：`packages/flutter_realtime_room_ui/lib/src/realtime_room_ui_controller.dart`、`packages/flutter_realtime_media_core/lib/src/session/room_presence.dart`、`packages/flutter_realtime_sdk_runtime/lib/src/realtime_client.dart`、`packages/flutter_realtime_sdk_ui/lib/src/realtime_meeting_page.dart`、`realtime_live_page.dart`。

## 三、屏幕共享：发送端实现状态（**不是远端实测通过**）

| 引擎 | 桌面 Web | Android | iOS | macOS | Windows |
| --- | --- | --- | --- | --- | --- |
| LiveKit | 浏览器授权/运行时能力 | MediaProjection 接入 | iOS 27+ ScreenCaptureKit；15–26 ReplayKit 扩展回退（需宿主签名/配置） | 系统录屏权限 | 驱动/实现；本机未做 Windows 原生验证 |
| Agora | 捕获接入，Web→原生共享类型信令缺口 | MediaProjection/状态信令有代码 | iOS 27+ ScreenCaptureKit 自定义视频；旧系统无通用跨 App 回退 | 主屏自动选取代码 | 主屏自动选取代码；构建/双机待验收 |
| TRTC | JS 屏幕辅路有代码 | 原生辅路有代码 | iOS 27+ ScreenCaptureKit 辅路；旧系统未接同等回退 | 主屏自动选取代码 | 主屏自动选取代码；构建/双机待验收 |
| ARTC | Web 捕获/远端映射有代码 | MediaProjection 桥有代码 | iOS 27+ ScreenCaptureKit 外部屏幕流；旧系统未接 | 主要是远端接收；发送端/Framework 有缺口 | Windows 本地工作区有屏幕区域共享 API；未验远端画面／未合并主仓库 |
| Chime | 浏览器 Content Share | 原生发送端未接 | iOS 27+ ScreenCaptureKit → Content Share，远端 Content Tile 待验收 | 无桌面发送桥 | 无 Driver |
| IVS | 浏览器屏幕**替换摄像头** | 原生发送端未接 | iOS 27+ ScreenCaptureKit → Stage 替换摄像头，非双路 | 无桌面发送桥 | 无 Driver |

所有 iOS 27+ 路径均须双端验证切出 App 后画面继续、授权/撤销、远端轨道、音频和退出清理；LiveKit 旧版 ReplayKit 要求 App Group 与 Broadcast Extension 签名。IVS 单 Token 模式无法同时发布摄像头和屏幕两路视频。Web 移动浏览器不能从桌面 Web 支持推断为可共享。屏幕录制标注限于 SDK 自身显示画布，不是系统级桌面涂鸦层。详见 [逐厂商屏幕共享实现说明](SDK_CAPABILITY_MATRIX.zh-CN.md)。

## 四、虚拟背景与平台桥

| Bridge | Android | Web | macOS | iOS | Windows |
| --- | --- | --- | --- | --- | --- |
| 采集/分割/模糊/换图/预览 | Native Frame Hub + Texture | 处理后 MediaStreamTrack + HTML video | CVPixelBuffer + Texture | Vision / Core Image + Texture，**无签名 Release 构建已验证、真机待验收** | Media Foundation + ONNX、Texture 源码已写，**Windows Demo Debug 构建通过；ONNX 实时推理／远端处理后画面尚未验收** |
| 真实远端处理后画面 | 非全厂商/设备验收 | 非全浏览器/厂商验收 | 非全厂商验收，WebKit 运行时有条件 | 六厂商组合不能一概宣称通过 | 未验收 |

声明层所有六个媒体引擎有 `ProcessedVideoSink` 源码，但实际开关需要同时满足 Provider 角色权限、Bridge 可用和 Runtime Probe；没有 Sink 时要求**失败关闭**，不能偷偷把原摄像头未处理背景发布。原生帧不走 Dart MethodChannel。来源：`packages/flutter_realtime_video_effects`、`packages/flutter_realtime_media_*/lib/src`，以及自动声明文档。

**Windows 补强记录（本轮未发布）：**Windows 原生 box blur 已优化为线性复杂度；对不合法效果值采取失败关闭、摄像头断线后重新选择设备可恢复、WIC 图片解码前增加尺寸校验；已有 Windows CI 配置，覆盖 MSVC CTest、多 Provider Demo 和单包 SDK 原生构建。Windows 副工作区**另已真实执行 ARTC x64 Debug 构建、SDK 原生加载和 Flutter Texture 集成测试**；这不同于 Windows CI 全门禁通过，也不同于真实双设备 RTC。**本轮未执行完整 Windows CI 或双设备互通验收。**

## 五、独立 Chat、课堂、直播与录制

| 功能域 | 代码能力 | 本轮不能声称的事项 |
| --- | --- | --- |
| Product Chat | Agora Chat、Tencent Chat、IVS Chat 独立于 RTC 选择；发送/接收、按凭证的管理与刷新；无产品 Chat 时，双向 RTC Data 方可提供短期 fallback | 不提供通用服务端历史分页；产品 Chat 连接失败不自动降级为 RTC 聊天；RTC fallback 无管理员和持久历史 |
| Classroom | 普通/课堂会议、举手、点名与发言许可、问答、投票、小测、公告、计时器、作业发布、资料链接、参与统计 | 其他厂商不具备 LiveKit 同等级别的服务端麦克风发布强制策略；作业提交/批改、正式应到名单、课程资料完整上传/预览不闭环 |
| 白板/共享内容 | 分页、撤销、清除、工具标注、迟加入快照、权限/Revision 冲突、统一内容舞台 | 共享屏幕标注必须有可用远端屏幕轨道；非所有设备/厂商已实测远端像素与坐标 |
| Live 互动 | 点赞、虚拟礼物、数量、去重/重试、历史快照、视频舞台近期礼物条幅、主动/被动结束直播 | 没有真实支付、积分、结算；不等于自动具备所有厂商实时 Chat |
| 云录制/MP4 | SDK 统一开始/停止/状态/结果接口；Demo Server 有 LiveKit、Chime、IVS、Agora、TRTC、ARTC 厂商执行器；历史记录中 LiveKit/Chime/IVS 曾获用户实际成功反馈 | Agora 等供应商真实录制与存储配置仍有待验收；不代表各平台所有录制布局/长时间音画/课程历史回看均已通过 |
| 生命周期 | 房主关房、普通成员本地退出、远端关房心跳终止、清理前停止云录制（具备对应实现） | 不等于厂商层瞬时强制断开；5 秒轮询不是精确 5 秒退出 SLA；同时断线/弱网/多厂商均待双机验收 |

相关实现和证据分别见 [Classroom SDK](CLASSROOM_SDK.md)、[Live SDK](CLASSROOM_SDK.md)、[云录制](CLOUD_RECORDING.md)、[音频专项](SDK_CAPABILITY_MATRIX.zh-CN.md)、[跨端审查](SDK_CAPABILITY_MATRIX.zh-CN.md)。

## 六、已核实与待验收

**本次源码复核：**Mac 主仓库自动声明 `python3 scripts/generate_capability_matrix.py --check` 通过。此前 `dev.27` 发布流程中，44 包内部分析/测试、95 项 Python 测试、Edge/Chromium Web 回归及 Pub dry-run（0 warnings）通过；独立 Demo 当时可通过 `flutter pub get` 获取 dev.27。主仓库现记录公开单包为 `dev.28`。本轮 Windows 另已完成 ARTC x64 Debug 构建、原生加载与 Texture 宿主集成测试、ARTC 18 项 Adapter 测试、Flutter 静态分析和 44 包架构检查。**不同层次与不同时间的证据不可合并解释为 dev.28 已包含 Windows ARTC，或六厂商全平台均完成真实验收。**

**最重要的验收缺口：**逐厂商 Web↔iOS、iOS↔Android 真实双向麦克风/扬声器、摄像头与远端黑屏；切 Safari/其他 App 的 iOS 屏幕共享；Agora Web→原生共享类型信令；Chime/IVS 原生非 iOS 27 屏幕共享；iOS 多 WebRTC 二进制共存；Windows 的 ARTC 本地原生编译虽通过，**真实双人收发仍未验证**；Chime Windows x64 桥尚缺；非 LiveKit 的强制禁麦；全供应商云录制与 MP4 音画完整性；资源清理和重连稳定性。

复查命令（SDK 工作区根目录）：

```bash
python3 scripts/generate_capability_matrix.py
python3 scripts/generate_capability_matrix.py --check
python3 -m unittest scripts.tests.test_capability_declarations -v
python3 scripts/check_sdk_architecture.py
```


---

## 公共能力接口与宿主要求

### 自动生成的声明与验收边界

[平台、角色和功能声明](generated/SDK_DECLARATIONS.md)从可选驱动和 Adapter 源码生成。
`python3 scripts/generate_capability_matrix.py --check` 会拒绝过期内容。
声明、平台构建和真实通话是三种独立证据；[统一验收入口](ACCEPTANCE.md)记录设备、供应商版本、远端画面与资源清理。

### 宿主应用要求

当前全量 SDK Demo 的最低目标为 Android API 28+（compile SDK 37）、iOS
15+、macOS 12+、Windows 10+，以及安全浏览器上下文中的标准 Flutter Web。
Android 构建使用 Flutter 3.47+、Dart 3.12+ 和 Java 17。单独使用低层
Adapter 包时，部分 Adapter 支持更低的 Android 版本。

Android 插件 Manifest 声明所需的运行时权限。宿主 iOS/macOS 应用必须提供
摄像头和麦克风用途说明；macOS 应用还需对应摄像头/麦克风 entitlement。
Demo 已包含这些设置。浏览器会请求设备访问权限，Web 部署必须使用 HTTPS
或 localhost。Pre-Join 和连接错误会通过 SDK 类型化诊断报告权限拒绝。

ARTC 的 iOS 二进制支持真机目标，但无法链接 iOS Simulator；因此 CI 使用
关闭代码签名的 iOS 设备目标构建。
`条件支持*` 表示 ARTC macOS 原生桥已经实现并通过构建，但仓库不重新分发
阿里官方 Mac framework；发布包未携带该 framework 时，Adapter 会明确返回
`unsupportedPlatform`，不会伪装成可用。

上表 Web 当前指标准 JavaScript Flutter Web 目标。`flutter build web`
已验证通过，但现有 Tencent Cloud Chat 依赖仍使用 `dart:html`、`dart:js`
以及 FFI 相关代码，因此 Flutter 的 Wasm dry-run 会报告不兼容；在上游依赖完成
迁移之前，不应把当前整套 Web Driver 宣称为 Wasm-ready。

macOS 已使用 CocoaPods 验证构建通过。AWS 的 `支持**` 表示完整 SDK 内部使用
同一个 WebKit Runtime：Meeting 加载锁定版本的 Chime JS，Live 加载锁定版本的
IVS Web Broadcast；业务代码仍只看到 `aws` 和统一 Dart API，不创建 WebView、
不加载脚本。Flutter 当前会提示部分插件尚未提供 macOS Swift Package Manager
支持；这是打包限制，不是本 SDK 的 Driver 路由失败。

Amazon IVS Chat 也支持 macOS：复用同一个隐藏 WebKit Runtime 和本地打包的 Chat
JavaScript bridge。Chat bridge 只会在首次打开 IVS Chat 会话时加载。

macOS 主仓库的历史构建记录包括 Android Debug APK、iOS 真机设备目标 Release（关闭签名）、
macOS Release 和标准 JavaScript Web。Windows 独立工作区额外完成了
`flutter build windows --debug --no-pub`、ARTC 官方 x64 原生库链接及
`windows_artc_bridge_smoke_test.dart` 的原生可用性／Texture 集成测试。
**这些 Windows 成果仍只保存在 Windows 工作区，尚未回流 Mac 主仓库／单包发行，且未实测双端媒体互通。**
CI 中存在 Windows runner 门禁配置，不能用其存在代替一次真实 CI 成功记录。

SDK 包自带 Web bridge 和锁定版本的供应商 JavaScript 资源。首次连接媒体或产品 Chat
时由 facade 自动加载；应用不需要维护 script 标签、CDN 链接或单独执行 npm 构建。
资源缺失或无法加载时返回 `webSdkUnavailable`。

AWS 对外统一展示为一个 Vendor，内部按模式路由：`Meeting -> Chime`、
`Live -> IVS Real-Time`。下表中的 Chime / IVS Real-Time 表示 AWS 内部 Engine 的能力。

| 能力 | LiveKit | Chime | Agora | TRTC | ARTC | IVS Real-Time |
| --- | --- | --- | --- | --- | --- | --- |
| Meeting 实时音视频 | 支持 | 支持 | 支持 | 支持 | 支持 | 支持 |
| Broadcast 直播房主/观众 | 支持 | 不支持（仅 participant） | 支持 | 支持 | 支持 | 支持 |
| RTC 数据发送 | 支持 | 支持 | 房主/participant | 房主/participant | 房主/participant | 不支持 |
| RTC 数据接收 | 支持 | 支持 | 支持 | 支持 | 支持 | 不支持 |
| RTC Chat fallback | 角色可发送时支持 | 支持 | 房主/participant | 房主/participant | 房主/participant | 不支持 |
| 单条 RTC 消息上限 | 15 KiB | 2 KiB | 1 KiB | 1 KiB | 1 KiB | — |
| 定向发送数据 | 支持 | 不支持 | 不支持 | 不支持 | 不支持 | 不支持 |
| 不可靠数据发送 | 支持 | 不支持 | 不支持 | 不支持 | 不支持 | 不支持 |
| 设备枚举/选择 | 支持，视平台而定 | 音频输出选择 | Adapter 未提供 | Adapter 未提供 | Adapter 未提供 | 麦克风/摄像头探测；切换摄像头仅 Android/iOS |
| 加入前原生设备探测 | 麦克风/摄像头 | 无 | 无 | 无 | 无 | 麦克风/摄像头 |
| 加入前 Provider 网络探测 | 需要房间凭证时不支持 | 无 | 无 | 无 | 无 | 需要参与者令牌时不支持 |
| 网络统计 | 支持 | Adapter 未提供 | 支持 | 支持 | Adapter 未提供 | 基础 RTC 统计 |
| 屏幕共享 | Web/Android/macOS；iOS 27+ 系统共享，15–26 ReplayKit 扩展 | Web Content Share；iOS 27+ ScreenCaptureKit（需验收），其他原生端缺桥 | Web/Android/macOS/Windows 有适配；iOS 27+ 外部屏幕轨道，旧版未接 | Web/Android/macOS/Windows 有适配；iOS 27+ 辅路，旧版未接 | Web/Android 有代码；iOS 27+ 外部屏幕轨道；macOS 发送端缺 | Web 单视频流替换；iOS 27+ Stage 替换摄像头，其他原生端缺 |
| Blur / image processed-video sink | Android/macOS/Web；iOS 已接且无签名编译通过；Windows 源码待验证 | Android/macOS 有条件/Web；iOS 需实测 | Android/macOS/Web；iOS 已接；Windows 源码待验证 | Android/macOS/Web；iOS 已接；Windows 源码待验证 | Android/macOS 有条件/Web，iOS 逐引擎待实测 | Android/macOS 有条件/Web，iOS 逐引擎待实测 |
| 房主查看参与者列表 | 后端验证逻辑房主 | Meeting 创建者通过逻辑房主凭证 | 后端验证逻辑房主 | 后端验证逻辑房主 | 后端验证逻辑房主 | 后端验证逻辑房主 |
| 房主移除参与者 | 支持 | 不支持 | 不支持 | 不支持 | 不支持 | 通过 IVS `DisconnectParticipant` |
| 房主关闭房间 | 后端支持 | Meeting 创建者通过控制面关闭 | 后端支持 | 后端支持 | 后端支持 | 后端支持 |

虚拟背景能力分成两层，不能把“本地能处理”和“Provider 能发布”混为一谈：

| Effects 平台 Bridge | Android | macOS | Web | iOS | Windows |
| --- | --- | --- | --- | --- | --- |
| 采集 + None/Blur/换图处理 | 已实现 | 已实现 | 已实现 | 已接入 Vision / Core Image，待真机 | Media Foundation + ONNX 源码已写入，待 Windows 编译/设备测试 |
| 实时本地预览 | Flutter Texture | Flutter Texture | HTML video | Flutter Texture，待真机 | Flutter Texture 原生代码已写入，待 Windows 编译 |
| Processed Source | Native RGBA Frame Hub | Native `CVPixelBuffer` Frame Hub | `MediaStreamTrack` | iOS `CVPixelBuffer` Frame Hub + LiveKit，待真实远端验收 | Windows Frame Hub → LiveKit 自定义 WebRTC 轨道 / Agora 外部视频轨道 / TRTC I420 数据投递源码已接入，待原生构建及真机验收 |

第一层由 `flutter_realtime_video_effects` 统一负责，提供模糊和图片替换；六个媒体 Engine 已有
`ProcessedVideoSink` 实现。Native 帧仍在 Native Frame Hub 中传递。
Android/macOS/Web 的发布者按平台与运行时能力启用；ARTC、Chime、IVS 的 macOS 输入需要真实能力探测。
当前源码已有 iOS 效果桥和 LiveKit iOS 处理视频输入，并通过
iOS 无签名 Release 构建，但**尚未完成真机与真实远端像素验收**；Agora/TRTC/ARTC/AWS 的
iOS LiveKit、Agora、TRTC 原生处理后视频轨道均已接入并通过 iOS 无签名 Release
构建，但仍需分别完成 iPhone 真实远端像素及长时间运行测试。Windows 已写入 Media Foundation
摄像头、ONNX PPHumanSeg 人像分割、模糊/换图合成、Flutter Texture 插件与本地原生帧分发；
预编译的 PPHumanSeg 模型及 Apache-2.0 许可文件已校验；Windows CMake 默认
获取 SHA256 固定校验的官方 ONNX Runtime x64 并打包运行库与许可，
也支持 `REALTIME_ONNXRUNTIME_ROOT` 在离线环境复用已安装的运行库。
LiveKit、Agora、TRTC Windows 三个 Provider 的 Native ProcessedVideoSink 发布桥接代码均已写入，
包括完整的原生插件注册、单包 SDK 打包适配和退出/重连释放路径的代码。
相关 Dart 平台能力测试和帧处理测试通过，但 Windows 原生链接、ONNX 推理性能、
远端视频画面与长时间稳定性均待实机验收。**当前不得视为三个供应商生产级已完成**。
Flutter Windows 原生构建门禁见 `.github/workflows/windows-video-effects-smoke.yml`；
工作流包含三个 Provider 的 Windows 原生构建检查，并执行带 ONNX Runtime
链接的 x64 Release 构建。编译通过不代表实际人像分割质量和远端像素验收通过；
仍必须完成 Windows 双设备真实通话。
以上描述的是源码中的实现声明；具体发布版支持范围以该版本的能力矩阵和
实际设备测试为准。源码实现不等于真实远端画面验收通过。
**最新细分清单以 [2026-11-06 复核表](SDK_CAPABILITY_MATRIX.zh-CN.md) 为准。**

Demo 的 Pre-Join 直接使用 Platform Bridge 做实时虚化预览，不进入 Provider 房间。
正式入房前 `RealtimeRoomView` 会重新创建 processed source 并 attach 给当前
Provider Sink。如果 Sink 尚未实现，则保持摄像头关闭，避免发送未处理的真实背景。

Meeting 是多人双向音视频模式。Broadcast 是一对多直播模式：房主发布音视频，观众订阅观看。
Chime 当前只提供 participant 角色，不支持房主/观众直播角色。

### Provider 无关 API

#### 加入前检查

`MediaClient.runPreJoinCheck()` 在创建或加入房间前提供统一的就绪状态。Core 会检查后端可达性、目标
Provider 是否已注册、权限状态、设备可用性（Provider 支持时）和基础网络可达性。Adapter 可通过
`MediaPreJoinProbe` 增加检查。

- `required` 检查为 `failed`、`unsupported` 或 `unknown` 时会阻止继续。
- `recommended` 检查未通过时显示警告，不阻止继续。
- `skipped` 表示不执行该检查。
- Adapter 不应把未实际执行的检查报告为 `passed`。
- 需要正式房间凭证才能执行的 Provider 网络探测应返回 `unsupported`，不能为了诊断而创建房间。

后端 `GET /health` 是可选诊断接口，不是 Backend Contract 的必要条件。接口不存在时可显示警告；网络
传输或超时错误属于网络失败；已实现的健康接口明确返回错误时属于后端失败。

#### 房间发现

`MediaClient.listRooms()` 返回轻量级 `MediaRoomSummary`。发现接口不暴露用户/设备身份、参与者 ID 或
Provider 凭证。

#### 设备与统计

会话可通过 `listMediaDevices()` / `selectMediaDevice()` 使用其已声明支持的设备能力。Core 也提供
`listMicrophones()`、`listCameras()`、`listAudioOutputs()`、`selectMicrophone()`、`selectCamera()` 和
`selectAudioOutput()` 等统一方法。未支持的操作应返回 `MediaErrorCode.unsupportedFeature`。

支持 RTC 指标的 Provider 实现 `MediaStatsProvider`。应用可读取最新的
`session.connectionStats`，也可订阅 `session.stats`；Adapter 不会伪造 Provider 未提供的数据。

#### 数据消息与恢复

`session.sendData(...)` 是高级数据发送接口；旧的 `sendMessage(...)` 保持兼容。
`MediaSendOptions` 描述 topic、目标参与者、可靠性和顺序要求。Core 会根据
`MediaCapabilities` 校验请求语义及消息大小限制。
Provider 收到的数据消息统一通过 `session.dataMessages` 暴露；`canReceiveData` 与
`canSendData` 分开声明，从而能区分只能发送/只能接收与真正可双向 fallback 的角色。

`MediaRoomSession.recoveries` 将重连中、恢复成功和失败状态统一为恢复事件，同时保留逻辑参与者身份。
Provider 凭证刷新仍需保持 Provider、房间、角色和参与者身份不变。

#### 房主管理

房主管理权限由后端验证。`MediaRoomSession.listParticipants`、`removeParticipant` 和 `closeRoom` 会把当前
参与者 ID 与凭证发给后端，由后端检查已登记的房主身份。客户端本地的 `MediaRole.host` 值本身不能授予
管理权限。

### 接入新 Provider

Adapter 只能声明实际实现的能力。新功能应先映射到 Provider 无关模型；高级场景可由 Adapter 包额外提供
Provider 专属接口。未支持的操作应返回有类型的错误，不能静默成功。

只有在无需加入房间即可执行真实诊断时，才应实现 `MediaPreJoinProbe`。不可用的检查应明确返回
`unsupported` 或 `unknown`，并保留 Core 指定的检查级别。


---

## 屏幕共享控制契约及剩余问题

### 标准契约

`InteractiveMediaSession.setScreenShareEnabled(true/false)` 是供应商无关的共享入口。`snapshot.localScreenShareEnabled` 必须只在真正的本地采集/发布成功时为 true；`snapshot.contentShareTrack` 是共享画面轨道，`MediaTrackPublished/MediaTrackUnpublished` 通知 UI；远端应按共享源原始纵横比 `BoxFit.contain` 展示，而不是裁剪。用户主动停止、屏幕源意外终止、权限被拒绝、离会/销毁都必须清理采集资源与状态。

**凡仅能接入摄像头，但无法远端正确呈现共享画面的组合，均不应称为已完成全链路。**

### 仍未完成的关键闭环

1. **Agora Web 发起共享时的反向信令和端到端验收**：Agora Web 4.24.8 有 `stream-message` 接收事件，但没有可用的 `sendStreamMessage` 发布接口。原生 → Web 的 DataStream 控制消息已接通代码层；Web → 原生需另设 provider-neutral 信令服务/IM 通道或合法的屏幕子 UID/Token，不能用视频宽高猜测屏幕类型。所有方向都还需要实机确认。
2. **ARTC/Chime/IVS 剩余原生平台适配**：ARTC Android 和 iOS 27+ 的共享接入已新增，但尚需实机媒体验收；ARTC 旧版 iOS/桌面发送端尚缺。Chime、IVS 的 iOS 27+ 原生共享适配已新增，仍需真机 Content Tile / Stage 视频流验收，其余移动/桌面平台尚未完成。IVS 单 Stage Token 的视频源替换无法自动向远端标注“屏幕轨道”，共享类型需另设有鉴权的信令或提供者标识，不可根据视频宽高猜测。
   IVS **同时发布摄像头和屏幕**按 [AWS 官方说明](https://docs.aws.amazon.com/ivs/latest/RealTimeUserGuide/web-publish-subscribe.html) 需要额外的共享 Stage Token 和独立参与者；目前 Demo 的单 Token 模式采用暂停摄像头视频并共享屏幕的策略，而非双路并行。
3. **iOS 跨 App 全屏共享的剩余验收**：iOS 27+ 的 ScreenCaptureKit 不需要 Broadcast Upload Extension 或 App Group，但宿主必须启用 `UIBackgroundModes: screen-capture` 并提供 `NSScreenCaptureUsageDescription`。iOS 15–26 的 LiveKit ReplayKit 回退仍需要 App Groups + 两个 Target 的正确签名。均须双设备验证 Safari/微信切换、远端持续出帧、系统停止/权限取消/应用退后台/离会清理。仅执行无签名 Xcode 编译不能宣称全链路通过。
4. **原生桌面多显示器与窗口共享**：TRTC 和 Agora 都已接主显示器自动选择；但还没有 SDK 级共享源列表 UI / 手动选择其他显示器或窗口，也没有桌面真机播放验收。AWS 桌面仍未接入。
5. **运行时权限和系统停止事件**：Android 前台 MediaProjection 服务，macOS 屏幕录制权限，iOS 广播停止、浏览器 `track.ended`、销毁和重连；真实场景均需端到端确认。
6. **多供应商/多平台验收**：每个组合至少用双设备测试本地采集 → 发布 → 远端订阅 → 坐标与画面比例 → 主动停止/权限拒绝/意外停止 → 重连与退出。自动化 Mock 测试不等于真实 SDK 通过。

官方资料：[Agora Flutter Screen Sharing 示例](https://github.com/AgoraIO-Extensions/Agora-Flutter-SDK/blob/main/example/lib/examples/advanced/screen_sharing/screen_sharing.dart)、[腾讯 TRTC 屏幕共享](https://trtc.io/zh/document/39859?platform=flutter)、[AWS Chime 移动屏幕共享](https://aws.amazon.com/about-aws/whats-new/2021/01/amazon-chime-sdk-ios-android-support-screen-share/)。


---

## iOS 多厂商音频会话与麦克风风险

### 2026-11-04 P0 根因：未使用 IVS 时插件注册抢占 iOS 音频会话

#### 现象与定位证据

- 完整聚合 SDK 的 iPhone 12 Demo：尚未使用 Amazon IVS，仅进行原生 `AVAudioEngine` 录音诊断，就出现约 **0.28 秒后停止采集**（5 个缓冲区、24,000 帧，测试结束时 `engineRunning=false`）。本应维持的 `AVAudioSessionModeMeasurement` 被改成 `AVAudioSessionModeDefault`。
- 最初通过 `FRSDK_IOS_DISABLE_CHIME=1`、`FRSDK_IOS_DISABLE_ARTC=1` 排除 Chime/ARTC 原生依赖，问题**仍可复现**。所以 Objective-C WebRTC 类重名虽然是独立高风险事项，却**不能直接当作这次 0.28 秒中断的已证实原因**。
- 在 **仅用于定位的 Demo Debug 构建**中记录 `AVAudioSession` 的 `setActive`、`setCategory:mode:options:` 等 setter 调用栈，定位到：

```text
FlutterRealtimeMediaIvsPlugin.init
  → IVSDeviceDiscovery.init
  → AmazonIVSBroadcast
  → AVAudioSession.setActive / setCategory:mode:options:
```

聚合包的 `FlutterRealtimeSdkPlugin.register` 会在 App 启动时注册多个厂商插件。旧 IVS 实现使用 `private var discovery = IVSDeviceDiscovery()`，**插件实例一创建，就会初始化 IVS 设备发现并重配置 App 进程全局共享的 `AVAudioSession`**，即使当前房间使用的是 LiveKit。这会干扰其他厂商的录音/播放引擎。

#### 修复及防回归

1. 在 `packages/flutter_realtime_media_ivs/ios/flutter_realtime_media_ivs/Sources/flutter_realtime_media_ivs/FlutterRealtimeMediaIvsPlugin.swift` 中，将 `discovery` 改为可选成员，通过 `deviceDiscovery()` **首次真正需要 IVS 本地发布设备/屏幕源时才创建**；`leave()` 时置空。
2. IVS `probeDevices`（入会前检查）使用 `AVCaptureDevice.devices(for: .video/.audio)` 获取数量，不再为了检查设备就初始化 IVS 音频会话。
3. 通过 `scripts/tests/test_ios_ivs_audio_session_lifecycle.py` 限制注册、预检查不得提前创建 `IVSDeviceDiscovery`；`scripts/tests/test_ios_vendor_conflict_isolation.py` 同时保护 CocoaPods `exclude_files` setter 兼容性。
4. 追踪 setter 的临时 Objective-C swizzle 已从最终 Demo 删除，**不可将全局音频拦截作为生产修复方案**。其他供应商仍会注册 Flutter MethodChannel，但不应在插件注册阶段占用共享音频会话。

#### 结果与边界

| 测量项 | 修复前（完整插件宿主） | 修复后（完整插件注册、Chime/ARTC 暂隔离时） |
| --- | --- | --- |
| 原生 PCM 采集跨度 | 约 0.28 秒 | **约 2.88 秒** |
| 采集缓冲区 | 5 | **31** |
| 采样帧数 | 24,000 | **148,800** |
| 诊断结束时引擎 | 停止 | **运行中** |
| AVAudioSession mode | `Default` | **`Measurement`** |

另以 LiveKit 自动创建两个参与者，已验证开麦、静音、再次开麦和对端收到**未静音音轨的发布信息**。此结果**不等于**对端扬声器实际出声、PCM/RTP 数据持续发送，也不等于六厂商双向通话全部通过；LiveKit `inputMixer` 入会前配置曾出现 Audio Device Module 尚不可用的日志，仍需用引擎/RTP 统计和两台设备复核。

**正式发布**：`flutter_realtime_sdk 0.1.0-dev.24` 已上传 pub.dev；Demo 已改为从 pub.dev 获取该版本，而非本地 `path` 覆盖。之后恢复 Chime、ARTC 默认启用的完整 iOS 宿主，CocoaPods 安装和无签名编译通过；**由于测试 iPhone 锁屏，恢复后的原生 PCM 和真实双向音频尚未复测**，不能把全供应商共存标为运行时验收成功。

### iOS 多供应商二进制冲突

同一 App 同时链接独立 `WebRTC.framework`、`AmazonChimeSDKMedia.framework`、`AliVCSDK_ARTC.framework` 时，iOS 日志已经报告 `RTCRtpCapabilities`、`RTCAudioSession` 等 Objective-C 类重名。

这不是普通的提示文案问题：**可能因运行时绑定到错误的 WebRTC/AVAudioSession 实现而出现没有声音或崩溃**。应用能显示首页、Xcode 能编译，不代表混用这些二进制时音频链路安全。根治应做原生依赖隔离/厂商兼容性验证，或按发行 Flavor 将真正不使用的原生供应商二进制排除；不可简单删除某一个 WebRTC.framework，否则可能让另一家 SDK 启动失败。本次未尝试未经厂商支持的二进制修改。


---

## Windows 实现与未验收项

### 一、覆盖范围与仍缺失的能力

| Windows 功能 | 当前实现状态 | 验证边界 |
| --- | --- | --- |
| LiveKit Meeting / Live RTC | Driver/Adapter 与 Windows WebRTC 原生轨道相关代码已有 | 需 Windows Release 编译、麦克风/扬声器/视频双设备验证 |
| Agora RTC Meeting / Live | Windows Driver、原生屏幕采集与外部视频帧插件代码已有 | 需校验 Agora Windows 原生 SDK 头文件、动态库与远端订阅 |
| Tencent TRTC Meeting / Live | Windows Driver、主屏幕共享、原生视频帧插件代码已有 | 需校验 TRTC 原生 SDK 和自定义采集开关、远端帧 |
| 处理后的视频 / 虚拟背景 | Media Foundation 摄像头 → PPHumanSeg ONNX → Blur/Replace BGRA → 单一 FrameHub → 三厂商 Native Sink | 原生 C++ Windows DLL 仍未链接验证；**不能把无报错预览等同于远端收到处理后画面** |
| Windows 屏幕标注 | Win32 顶层透明窗口、绘图/文本工具实现代码已有 | 多显示器、高 DPI、共享窗口捕获范围和实际直播叠加效果未验收 |
| ARTC | Windows 副工作区已添加条件 Driver、x64 原生 Method/Event Channel、BGRA Texture、屏幕区域共享调用路径 | Debug 构建与原生加载/Texture 集成测试通过；Mac 主仓库未合并／未发布；真实双端仍未验收 |
| AWS Chime / AWS IVS RTC | **无 Windows 媒体 Driver** | Chime 官方 C++ 库实查 x86，不能直接链入 Flutter x64；IVS 缺原生桥 |
| Agora Chat / Amazon IVS Chat | 无默认 Windows Chat Driver；Tencent Cloud Chat 有 Windows 声明 | 未补聊天原生厂商 SDK；不能将 RTC Data 回退等同为完整产品聊天 |

### 二、本轮实际代码修改

1. **高性能模糊算法：**`packages/flutter_realtime_processed_video/windows/include/processed_video_compositor.h` 改为行、列前缀和的分离式 box blur，单帧处理量不再随 8/16/24/32 模糊半径成倍增长。保持整数均值和 BGRA→RGBA 预览语义不变，不改 RTC Data 帧格式。
2. **隐私保护：**`packages/flutter_realtime_video_effects/windows/flutter_realtime_video_effects_plugin.cpp` 拒绝格式错误/未知的 effect 类型，不再悄悄切回未处理的 `none`；溢出整数配置被拒绝；替换图片在 WIC 转换前验证像素尺寸和压缩文件大小。
3. **异常恢复：**Windows Media Foundation 摄像头异常后，用户重新选择有效摄像头会先停止旧采集线程，再清空失败标志与 FPS 节流状态、重新启动新设备，避免永远黑屏。仍须在真实 Windows USB 热插拔场景验收。
4. **可运行的原生测试：**`packages/flutter_realtime_processed_video/windows/test/processed_video_blur_test.cpp` 将优化结果和旧实现逐字节比较，覆盖 1 像素边界、奇数尺寸、带 padding 的 BGRA stride、7 种半径；`windows/test/CMakeLists.txt` 将该测试与合成、FrameHub、I420 一起纳入 CTest。
5. **Windows CI：**`.github/workflows/windows-video-effects-smoke.yml` 增加三层真实 Windows 构建门禁：MSVC x64 + CTest；源码模块 Demo 的 Flutter Windows Release；已组装的单包 SDK 在全新独立 Windows 宿主中的 Flutter Release。校验 ONNX Runtime DLL、模型资产和 SDK DLL 是否随包输出。

### 五、尚未补齐的 Windows 项目

- ARTC Windows 原生基础桥已在副工作区编译/加载通过，但**尚未实测双端通话、音视频帧、共享画面、重连和资源清理**；处理后虚拟背景输入未接。Mac 主仓库/已发布 SDK 仍未合并该 Driver。
- Chime/IVS Windows 完整媒体 Driver、Agora Chat/IVS Chat Windows 产品聊天 Driver 仍缺。Windows ONNX 实时推理、所有厂商自定义轨道、远端音视频、屏幕共享、扬声器与麦克风全链路仍待实测。
- 单包 `flutter_webrtc` 的自定义 Windows 视频轨道接口要与实际安装版本严格匹配，不能假定所有公网上游二进制都包含本仓库的扩展；Windows CI 的新宿主编译用于尽早暴露此类不匹配。
- 经过完整 Windows 门禁和多设备远端画面验收后，才能将这些项由“有代码”提升为“已验证”，并决定后续 dev 版本发布。

参见 [总能力矩阵](SDK_CAPABILITY_MATRIX.zh-CN.md) 与 [2026-11-06 当前能力审计](SDK_CAPABILITY_MATRIX.zh-CN.md)。
