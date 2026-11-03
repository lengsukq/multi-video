# SDK 能力矩阵

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

**下表是各个可选 Provider 包提供的 Driver 能力，不表示主 SDK 内置了所有厂商。**
宿主必须显式引入对应的 `flutter_realtime_provider_*` 并使用
`Realtime(providers: [createLivekitProvider(), ...])` 注册；纯
`flutter_realtime_sdk` 不会自动安装或注册任意 Vendor。
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
| 屏幕共享 | 发布者支持，Web 移动端限制 | 原生 Adapter 未提供；Web 按能力检查 | 原生暂未实现；Web 按能力检查 | Android/iOS 发布者；Web 按能力检查 | Web 按能力检查 | Web 按能力检查 |
| Blur / image processed-video sink | Android/macOS/Web，iOS Release 已编译，Windows 待验证 | Android/macOS conditional/Web | Android/macOS/Web，iOS Release 已编译，Windows 待验证 | Android/macOS/Web，iOS Release 已编译，Windows 待验证 | Android/macOS conditional/Web | Android/macOS conditional/Web |
| 房主查看参与者列表 | 后端验证逻辑房主 | Meeting 创建者通过逻辑房主凭证 | 后端验证逻辑房主 | 后端验证逻辑房主 | 后端验证逻辑房主 | 后端验证逻辑房主 |
| 房主移除参与者 | 支持 | 不支持 | 不支持 | 不支持 | 不支持 | 通过 IVS `DisconnectParticipant` |
| 房主关闭房间 | 后端支持 | Meeting 创建者通过控制面关闭 | 后端支持 | 后端支持 | 后端支持 | 后端支持 |

虚拟背景能力分成两层，不能把“本地能处理”和“Provider 能发布”混为一谈：

| Effects 平台 Bridge | Android | macOS | Web | iOS | Windows |
| --- | --- | --- | --- | --- | --- |
| 采集 + None/Blur 处理 | 已实现 | 已实现 | 已实现 | 已接入 Vision / Core Image，待真机 | Media Foundation + ONNX 源码已写入，待 Windows 编译/设备测试 |
| 实时本地预览 | Flutter Texture | Flutter Texture | HTML video | Flutter Texture，待真机 | Flutter Texture 原生代码已写入，待 Windows 编译 |
| Processed Source | Native RGBA Frame Hub | Native `CVPixelBuffer` Frame Hub | `MediaStreamTrack` | iOS `CVPixelBuffer` Frame Hub + LiveKit，待真实远端验收 | Windows Frame Hub → LiveKit 自定义 WebRTC 轨道 / Agora 外部视频轨道 / TRTC I420 数据投递源码已接入，待原生构建及真机验收 |

第一层由 `flutter_realtime_video_effects` 统一负责，提供模糊和图片替换；六个媒体 Engine 已有
`ProcessedVideoSink` 实现。Native 帧仍在 Native Frame Hub 中传递。
Android/macOS/Web 的发布者按平台与运行时能力启用；ARTC、Chime、IVS 的 macOS 输入需要真实能力探测。
当前源码（2026-10-21）已新增 iOS 效果桥和 LiveKit iOS 处理视频输入，并通过
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

> **2026-10-10 架构更新：** 此处列的是已经具备的业务能力，
> 不代表所有应用默认加载。普通 `flutter_realtime_sdk` /
> `flutter_realtime_sdk_runtime` 不再强制依赖课堂、直播礼物或白板。
> 需显式注册 `flutter_realtime_classroom_preset` 的 `ClassroomPreset`
> 或 `flutter_realtime_live_preset` 的 `LivePreset`；
> 主 SDK 也可仅使用 `room.interactions` 实现自己的瞬时互动。
> 详见 [四种接入方式](INTERACTION_PRESET_GUIDE.zh-CN.md)。
> 下方平台能力及历史构建状态仍按 **2026-10-08** 记录，
> 不代表本次重新完成了真实设备验收。

以下为 **2026-10-08 当前工作区快照**，包含未提交实现，不表示已发布版本。
功能属于 SDK 的供应商无关层；参考后端确认身份与状态，Demo 通过通用组件演示。

状态含义：**✅ 基础实现已有；△ 部分实现或有条件；❌ 未实现；— 不适用。**
状态不等于实机验收通过。Web、Android、iOS、macOS 已完成应用构建；
Windows 的已注册组合仍缺本次原生构建和新互动功能验收。

### 需求与各平台实现对照

| 预计功能 | Web | Android | iOS | macOS | 当前实现与缺口 |
| --- | :---: | :---: | :---: | :---: | --- |
| Live 集成 Chat | ✅ | ✅ | ✅ | △ | 媒体与产品 Chat 可自由组合；ARTC macOS 需官方 framework。各组合仍待真实联调 |
| Web 端 | ✅ | — | — | — | 标准 JavaScript Flutter Web 已实现并构建；完整 SDK 尚不支持 Wasm |
| Live 打赏，不接支付 | ✅ | ✅ | ✅ | ✅ | 虚拟礼物、数量、共享记录、汇总、动画和重试；无余额、支付或结算 |
| 举手 | ✅ | ✅ | ✅ | ✅ | 学生举手/取消，老师查看队列 |
| 允许指定学生发言 | △ | △ | △ | △ | LiveKit 有服务端麦克风权限控制；其他供应商只限制 SDK 界面，不能宣称强制禁麦 |
| 课堂聊天 | ✅ | ✅ | ✅ | ✅ | 使用独立产品 Chat；未配置产品 Chat 时，RTC fallback 需要双向数据能力 |
| Q&A | ✅ | ✅ | ✅ | ✅ | 提问、回答、标记已处理、搜索和筛选 |
| 学生列表 | △ | △ | △ | △ | 在线/离线、举手和发言许可已有；摄像头/麦克风信息缺失时显示未知 |
| 互动提醒 | ✅ | ✅ | ✅ | ✅ | 举手、问题、回答、发言批准提醒；聊天有未读提示 |
| 参与度统计 | ✅ | ✅ | ✅ | ✅ | 在线成员/学生、举手、问题等；消息数只是本机缓存数量，不是全班累计 |
| 独立白板与分页 | ✅ | ✅ | ✅ | ✅ | 独立 Core/UI，无媒体也可绘制；默认最多 20 页、逐页保留笔迹，真实多设备验收待完成 |
| 统一内容舞台 | ✅ | ✅ | ✅ | ✅ | 成员、白板、共享统一入口；教师控制、学生跟随；共享采集仍按下方供应商能力启用 |
| 画笔 | △ | △ | △ | △ | 白板可独立使用，屏幕标注需可渲染共享轨道；共用绘制层 |
| 高亮 | △ | △ | △ | △ | 白板已实现；屏幕标注需可渲染共享轨道 |
| 圆圈 | △ | △ | △ | △ | 白板已实现；屏幕标注需可渲染共享轨道 |
| 箭头 | △ | △ | △ | △ | 白板已实现；屏幕标注需可渲染共享轨道 |
| 文字说明 | △ | △ | △ | △ | 白板已实现；屏幕标注需可渲染共享轨道 |
| 撤销 | △ | △ | △ | △ | 白板/共享画布撤销最后一个标注 |
| 清除 | △ | △ | △ | △ | 清除当前白板页或共享画布 |
| 实时同步标注 | △ | △ | △ | △ | 已有同步、迟加入恢复、共享源切换重置；远端画面待验收，无通知通道时约两秒轮询 |
| Quiz 小测验 | ✅ | ✅ | ✅ | ✅ | 单选、提交/修改答案、教师查看结果；结束前对学生隐藏正确答案 |
| Poll 投票 | ✅ | ✅ | ✅ | ✅ | 单选投票、修改选择、结束和结果统计 |
| 课堂公告 | ✅ | ✅ | ✅ | ✅ | 教师发布，学生同步接收 |
| 专注提醒 | ✅ | ✅ | ✅ | ✅ | 文字提醒；不监控学生是否切出应用 |
| 布置作业 | ✅ | ✅ | ✅ | ✅ | 标题、说明、截止时间、发布和查看；未扩展提交或批改 |
| 考勤 | ✅ | ✅ | ✅ | ✅ | 本次课堂首次加入、最近离开、累计在线时长；没有应到名单或缺勤判定 |
| 教学资料 | △ | △ | △ | △ | 资料链接分享和打开已有；文件选择、实际上传及内置课件预览未实现，仅预留宿主上传接口 |
| 课堂计时器 | ✅ | ✅ | ✅ | ✅ | 服务器截止时间、同步倒计时和停止 |
| 课堂录制与回看 | ❌ | ❌ | ❌ | ❌ | 按当前范围暂缓，录制和回放均未实现 |

上表的 ✅ 表示 SDK 有该功能；实际可用性仍要求后端提供相应接口，
并配置可用的媒体/Chat Driver。新教学工具和礼物状态保留在本次房间生命周期内，
不提供跨课堂长期历史；存储和录制仍不在本轮范围内。

### Live 与产品 Chat 的平台接入

[可选 Provider Bundle 的平台 Driver 声明](#可选-provider-bundle-的平台-driver-声明) 表列出五套媒体供应商和三套产品 Chat
在 Web、Android、iOS、macOS、Windows 的接入情况。五套 Live 为 LiveKit、
Agora、TRTC、ARTC、AWS IVS；AWS Meeting 使用 Chime。ARTC macOS 有原生
framework 条件；Windows 已注册 LiveKit/Agora/TRTC 和 Tencent Chat，
AWS/ARTC、IVS Chat/Agora Chat 暂无 Windows Driver。Linux 暂无默认 Driver。

AWS Live 已取消强制绑定 IVS Chat。媒体与产品 Chat 自由组合，创建房间时固定
其 Chat 绑定，后续切换只影响新房间。未选择产品 Chat 时只有双向 RTC Data
才能提供用户聊天 fallback；Agora/TRTC/ARTC 观众及 IVS 无法依赖这个 fallback
发送聊天。礼物和教学状态有独立的控制面轮询，不依赖用户聊天 fallback。

### 教师发起屏幕共享的平台差异

标注工具已经实现，但教师能否发起共享仍取决于媒体能力：

| Meeting 供应商 | 桌面 Web | Android | iOS | macOS |
| --- | :---: | :---: | :---: | :---: |
| LiveKit | ✅ 浏览器能力允许时 | ✅ | △ 当前使用应用内采集 | ✅ 需屏幕录制权限 |
| TRTC | ✅ 浏览器能力允许时 | ✅ | △ 已调用原生 SDK，完整链路待实机验收 | △ 本轮补主屏选取与辅路，待实机 |
| Agora | △ 浏览器可共享，原生→Web共享标识已接，Web→原生信令待补 | △ 原生 MediaProjection + 远端共享信令已接，待实机 | ❌ ReplayKit 广播扩展未接 | △ macOS/Windows 已接主显示器自动选择，待实机 |
| ARTC | △ Web 发送与远端显示待多设备验收 | △ Android 原生屏幕采集与远端独立轨道已接，待实机 | △ 远端屏幕接收已接，主动共享缺 ReplayKit | △ macOS 远端接收已接，发送与可选原生 Framework 待验收 |
| AWS Chime | ✅ 浏览器能力允许时 | ❌ | ❌ | ❌ |

详细的五平台 × 六引擎缺口、验证边界和本轮改动见 [屏幕共享实现矩阵](SCREEN_SHARING_PROVIDER_STATUS.md)。
这里的 Web 指桌面浏览器；移动浏览器不能从桌面 Web 支持推断可发起共享。
LiveKit iOS 当前设置 `useiOSBroadcastExtension: false`，不能将应用内采集
描述为跨应用整屏共享。接收共享/标注也不意味着同平台可以发起共享。
标注操作发生在 SDK 的共享预览区域，系统级桌面标注层尚未实现。

### 剩余缺口与验收

- **尚未实现**：教学资料文件选择/实际上传/内置预览、课堂录制及回放。
  上传存储和录制按当前范围暂缓，宿主可接入自己的上传服务。
- **供应商覆盖不足**：LiveKit 之外的服务端强制发言权限，以及上表未实现的
  原生屏幕共享和 iOS 跨应用共享链路。
- **仍待真实验收**：各媒体 × Chat × 平台组合、观众发送聊天、LiveKit 实际禁麦、
  远端标注坐标/画面、横竖屏、重连恢复和资源清理。
- **非本轮扩展**：作业提交/批改、正式应到名单/缺勤判定、全班累计聊天分析、
  跨课堂长期历史。不要将这些扩展列为已完成能力。

上一轮实现验证记录为 55 项后端测试 + 156 项 Dart/Flutter 测试，共 **211 项**；
Web、Android、iOS、macOS 构建通过。这些证据不替代真实多人/供应商或远端画面验收。
详见 [交付与验收](INTERACTION_ACCEPTANCE.md)、
[Classroom SDK](CLASSROOM_SDK.md) 和 [Live 互动 SDK](LIVE_INTERACTIONS_SDK.md)。

白板与统一内容舞台详见 [SDK 文档](WHITEBOARD_SDK.md)。本批验证为 306 项相关测试，
构建证据与真实共享/远端像素验收分开记录，详见[最新验收记录](INTERACTION_ACCEPTANCE.md#independent-whiteboard-delivery--2026-10-08)。
