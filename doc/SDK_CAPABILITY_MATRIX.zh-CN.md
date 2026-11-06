# SDK 能力矩阵

> **当前源码复核：2026-11-06** · 已发布聚合包：`flutter_realtime_sdk 0.1.0-dev.27`。
> 请先阅读 [逐引擎 × 平台 × 功能与验收分层核对表](SDK_CAPABILITY_AUDIT_2026-11-06.zh-CN.md)。
> 本页保留 API 介绍与部分早期专项验收记录；**过往快照不能覆盖最新源码结论**。
> “支持/✅”仅表示有 Driver 或基础实现，绝不自动代表已通过真实多设备媒体、权限与清理验收。
> Windows 原生插件补强、Windows CI 门禁、仍缺失的 Provider 与待验收清单：
> [Windows SDK 实现与验收说明](WINDOWS_SDK_IMPLEMENTATION_2026-11-06.zh-CN.md)。

### 当前结论速查

| 范围 | 当前可确认 | 主要限制 |
| --- | --- | --- |
| 媒体 | LiveKit / Agora / TRTC / ARTC / AWS（Chime Meeting、IVS Live），共 5 个外部 Provider、6 个引擎 | Windows 只声明 LiveKit/Agora/TRTC；Linux 无默认 Driver；ARTC macOS 依赖宿主 Framework |
| 产品 Chat | Agora / 腾讯 / Amazon IVS Chat，共 3 个可选引擎 | RTC fallback 要求媒体支持双向 Data；IVS Real-Time 无 RTC Data；产品 Chat 不自动回退 |
| 主持人结束房间 | `isLogicalOwner` 默认关闭逻辑房间，其他人仅退出自己；成员通过 5 秒心跳识别关闭 | 非厂商服务器端瞬时踢人，轮询存在延迟和在途请求 |
| 全系统共享 | iOS 27+ 六引擎对应的 ScreenCaptureKit 源码路径已接；LiveKit iOS 15–26 有 ReplayKit 扩展回退 | 真正切 App 的远端出帧、签名和双设备仍需验收，其他引擎旧版 iOS 路径有缺口 |
| 虚拟背景 | Android/Web/macOS Bridge 已实现；iOS 原生 Bridge/供应商 Sink 已有代码并通过无签名编译；Windows 有 ONNX 原生代码 | iOS 真实远端像素和 Windows 原生构建/设备待验收，不能把 `ProcessedVideoSink` 源码等于所有平台可用 |
| 课堂/直播/录制 | 白板/投票/Q&A/礼物/云录制控制面已实现；LiveKit/Chime/IVS 录制有历史实测反馈 | 各厂商双向声音、云录制音画质量与课程回放管理未全面验收 |

Meeting 教学互动 V1 已提供可选 ClassroomSession 和 SDK UI，举手、问答、
学生列表、消息提醒与课堂统计由 SDK 层统一处理。LiveKit Meeting 已
支持通过服务端 UpdateParticipant 限制/开放麦克风发布源；其他供应商
目前仅是 advisory（提示性许可），不能宣称强制禁麦。服务器参考实现
用 HTTP 控制面校验身份，可选 CLASSROOM_STATE_DIR 本机持久化；
IM System Hint / RTC Data 仅发送修订通知以加快同步。
详见 [Classroom SDK](CLASSROOM_SDK.md)。

**简体中文** | [English](SDK_CAPABILITY_MATRIX.md)

应用应根据 `MediaCapabilities` / `MediaFeature` 判断当前可用功能，而不是根据
`providerId` 推断。不同平台和角色可能拥有不同的能力集合。

## 自动生成的声明与验收边界

[平台、角色和功能声明](generated/SDK_DECLARATIONS.md)从可选驱动和 Adapter 源码生成。
`python3 scripts/generate_capability_matrix.py --check` 会拒绝过期内容。
声明、平台构建和真实通话是三种独立证据；[统一验收入口](ACCEPTANCE.md)记录设备、供应商版本、远端画面与资源清理。


## 可选 Provider Bundle 的平台 Driver 声明

**下表是开发工作区各可选 Provider Bundle 的 Driver 声明，而非真机验收。**
内部开发入口 `packages/flutter_realtime_sdk` 不传递依赖全部 Provider；但公开
pub.dev 单包 `flutter_realtime_sdk 0.1.0-dev.27` 已聚合源码和原生依赖：
**外部宿主只需一个 Pub 包，无需额外声明 `flutter_realtime_provider_*`，
但仍需在 `Realtime(providers: [...])` 中显式注册要使用的 Provider。**
这不保证未选中的原生厂商依赖被安装器剔除，避免把运行时按需加载误写为
二进制完全按需安装。
业务代码在所有平台使用同一套 API，Runtime 从**已注册**的 Driver 中按运行平台
解析。破折号表示该 Bundle 对应平台没有可用 Driver，按能力返回
`unsupportedPlatform` 或 Provider 未注册错误，而不是静默替换其他供应商。

| 对外 Media Provider | Android | iOS | macOS | Windows | Web |
| --- | --- | --- | --- | --- | --- |
| LiveKit | 支持 | 支持 | 支持 | 支持 | 支持 |
| Agora RTC | 支持 | 支持 | 支持 | 支持 | 支持 |
| Tencent TRTC | 支持 | 支持 | 支持 | 支持 | 支持 |
| Alibaba ARTC | 支持 | 支持 | 条件支持* | — | 支持 |
| AWS | 支持 | 支持 | 支持** | — | 支持 |

| Product Chat Provider | Android | iOS | macOS | Windows | Web |
| --- | --- | --- | --- | --- | --- |
| Agora Chat | 支持 | 支持 | 支持 | — | 支持 |
| Tencent Cloud Chat | 支持 | 支持 | 支持 | 支持 | 支持 |
| Amazon IVS Chat | 支持 | 支持 | 支持 | — | 支持 |

Linux 暂无上述官方 Bundle 的统一支持声明。高级使用者可以通过
`RealtimeProviderPlugin` 增加或覆盖 Driver，而无需修改 Core。

## 宿主应用要求

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

当前验证环境为 macOS：Android Debug APK、iOS 真机 Release（关闭签名）、
macOS Release 以及标准 JavaScript Web 均已完成构建验证。上表中的 Windows
组合已在对应的可选 Provider Bundle 中提供平台注册，并有平台选择单测覆盖；但 macOS 主机无法执行
Windows 原生构建。CI 配置了 Windows runner 构建；macOS 开发主机无法在本机生成
Windows 构建结果。

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
**最新细分清单以 [2026-11-06 复核表](SDK_CAPABILITY_AUDIT_2026-11-06.zh-CN.md) 为准。**

Demo 的 Pre-Join 直接使用 Platform Bridge 做实时虚化预览，不进入 Provider 房间。
正式入房前 `RealtimeRoomView` 会重新创建 processed source 并 attach 给当前
Provider Sink。如果 Sink 尚未实现，则保持摄像头关闭，避免发送未处理的真实背景。

Meeting 是多人双向音视频模式。Broadcast 是一对多直播模式：房主发布音视频，观众订阅观看。
Chime 当前只提供 participant 角色，不支持房主/观众直播角色。

## 产品聊天

产品聊天不由音视频 Provider 或 `MediaCapabilities` 决定，使用
`flutter_realtime_chat_core` 的 `ChatSession` / `ChatCapabilities`。

| 能力 | Amazon IVS Chat | Tencent Cloud Chat | Agora Chat | RTC Data fallback |
| --- | --- | --- | --- | --- |
| 发送消息 | 支持 | 支持 | 支持 | Media 同时支持双向 Data 时支持 |
| 接收实时消息 | 支持 | 支持 | 支持 | 支持 |
| 删除消息 | 房主/管理员令牌：客户端执行 | Demo 普通成员凭证不开放；可由自建 owner/admin 凭证扩展 | Demo 普通成员凭证不开放；可由自建 owner/admin 凭证扩展 | 不支持 |
| 断开用户 | 房主/管理员令牌：客户端执行 | Demo 走参考控制面 REST；供应商 owner/admin 凭证可声明 client | Demo 走参考控制面 REST；供应商 owner/admin 凭证可声明 client | 不支持 |
| 成员列表 | Demo 控制面逻辑成员列表 | Demo 控制面逻辑成员列表 | Demo 控制面逻辑成员列表 | 不提供管理目录 |
| 管理执行策略 | client 优先，必要时 backend | 当前 Demo 为 backend；真实 owner/admin 凭证可 client | 当前 Demo 为 backend；真实 owner/admin 凭证可 client | unsupported |
| 重连时自动刷新凭证 | 支持 | 支持 UserSig 刷新 | 支持 Token 刷新 | 跟随 MediaSession |
| 服务端消息历史 | IVS Chat 服务能力；Core v1 未提供历史分页 | Tencent Chat 服务能力；Core v1 未提供历史分页 | Agora Chat 服务能力；Core v1 未提供历史分页 | 仅当前会话内存 |
| 是否依赖音视频 Provider | 否，可独立选择 | 否，可独立选择 | 否，可独立选择 | 是 |

内置 UI 的用户聊天始终只消费 `ChatSession`。房间绑定独立产品 Chat Provider 时，
该 `ChatSession` 始终优先；房间没有绑定产品 Chat 时，只有当前 MediaSession 同时支持
RTC 数据发送和接收，`flutter_realtime_chat_rtc` 才会创建会话级 fallback。
独立产品 Chat 连接失败时不会自动降级到 RTC fallback。

原始 RTC Data 仍是独立的媒体传输/Debug 能力；`showRtcDataMessages` 不会把调试负载
注入 Chat 消息列表。RTC fallback 只保留当前会话内消息，没有服务端历史或管理员能力。
聊天能力与麦克风/摄像头发布权限完全独立。

管理能力通过 `ChatManagementExecution` 明确标记为 `client`、`backend`、
`hybrid` 或 `unsupported`。高层 `RealtimeChatModeration` 优先执行
Provider 客户端能力，只有供应商权限模型确实要求服务端管理员 API 时才回退到可选
control-plane。因此使用者不需要按 Provider 写分支，也不需要为了管理能力把长期密钥下发到 App。

## Provider 无关 API

### 加入前检查

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

### 房间发现

`MediaClient.listRooms()` 返回轻量级 `MediaRoomSummary`。发现接口不暴露用户/设备身份、参与者 ID 或
Provider 凭证。

### 设备与统计

会话可通过 `listMediaDevices()` / `selectMediaDevice()` 使用其已声明支持的设备能力。Core 也提供
`listMicrophones()`、`listCameras()`、`listAudioOutputs()`、`selectMicrophone()`、`selectCamera()` 和
`selectAudioOutput()` 等统一方法。未支持的操作应返回 `MediaErrorCode.unsupportedFeature`。

支持 RTC 指标的 Provider 实现 `MediaStatsProvider`。应用可读取最新的
`session.connectionStats`，也可订阅 `session.stats`；Adapter 不会伪造 Provider 未提供的数据。

### 数据消息与恢复

`session.sendData(...)` 是高级数据发送接口；旧的 `sendMessage(...)` 保持兼容。
`MediaSendOptions` 描述 topic、目标参与者、可靠性和顺序要求。Core 会根据
`MediaCapabilities` 校验请求语义及消息大小限制。
Provider 收到的数据消息统一通过 `session.dataMessages` 暴露；`canReceiveData` 与
`canSendData` 分开声明，从而能区分只能发送/只能接收与真正可双向 fallback 的角色。

`MediaRoomSession.recoveries` 将重连中、恢复成功和失败状态统一为恢复事件，同时保留逻辑参与者身份。
Provider 凭证刷新仍需保持 Provider、房间、角色和参与者身份不变。

### 房主管理

房主管理权限由后端验证。`MediaRoomSession.listParticipants`、`removeParticipant` 和 `closeRoom` 会把当前
参与者 ID 与凭证发给后端，由后端检查已登记的房主身份。客户端本地的 `MediaRole.host` 值本身不能授予
管理权限。

## 接入新 Provider

Adapter 只能声明实际实现的能力。新功能应先映射到 Provider 无关模型；高级场景可由 Adapter 包额外提供
Provider 专属接口。未支持的操作应返回有类型的错误，不能静默成功。

只有在无需加入房间即可执行真实诊断时，才应实现 `MediaPreJoinProbe`。不可用的检查应明确返回
`unsupported` 或 `unknown`，并保留 Core 指定的检查级别。

## 教学工具与直播互动

此处只保留**当前源码能力**，不再复制历史版本的需求/平台验收快照。

| 业务能力 | 当前状态 | 关键限制 |
| --- | --- | --- |
| 课堂互动 | 举手、许可发言、问答、投票、小测、公告、计时器、考勤和参与统计已有统一控制面 | 非 LiveKit 厂商的强制禁麦受限；作业提交/批改和资料上传/内置预览未完整闭环 |
| 共享内容/白板 | 独立分页白板、画笔、标注、撤销、清屏、迟加入快照和共享舞台 | 真正的跨 App 屏幕共享取决于平台权限、原生 Bridge、远端轨道和真实设备验收 |
| Live 互动 | 点赞、虚拟礼物、近期礼物条幅、观众订阅、房主结束直播 | 礼物不代表真实支付；无产品 Chat 时部分观众角色不能发送 RTC Data 聊天 |
| 云录制 | 统一开始/停止/状态/结果接口，多个厂商由可信后端执行 | 课程录像历史/同步回看不是完整产品闭环；不同厂商真实录制质量待验收 |

**详见：**[2026-11-06 SDK 当前能力复核](SDK_CAPABILITY_AUDIT_2026-11-06.zh-CN.md) · [课堂](CLASSROOM_SDK.md) · [白板](WHITEBOARD_SDK.md) · [直播互动](LIVE_INTERACTIONS_SDK.md) · [屏幕共享](SCREEN_SHARING_PROVIDER_STATUS.md) · [云录制](CLOUD_RECORDING.md)。
