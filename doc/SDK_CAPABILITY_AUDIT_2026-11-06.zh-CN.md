# SDK 当前能力复核（2026-11-06）

> 本文件针对 **SDK 工作区当前源码**（包含未提交改动）进行静态/声明/测试证据核对，而非复制厂商官网宣传表。公开单包最后已确认发布为 `flutter_realtime_sdk 0.1.0-dev.27`；**当前工作树不等同于发布归档的逐文件校验**。本文件只给出本轮能够证明的结论，未实际运行所有厂商的双设备 RTC、真实录制及跨 App 共享。

## 口径与证据

- **Driver**：源码有目标平台注册/路由，不等于原生二进制已可用。
- **实现**：可找到 SDK Adapter、Bridge、API 与资源清理路径；不表示远端实际收到音视频。
- **自动化**：Mock、静态分析、独立宿主编译或浏览器回归；只证明覆盖的调用/布局。
- **真实验收**：需给出厂商账号、端到端设备组合、远端音视频/帧、权限及退出清理结果；不把“按钮显示”“返回成功”“编译通过”算作验收。
- 可复现的声明来自 [自动生成的 Driver/角色/能力声明](generated/SDK_DECLARATIONS.md)，生成器为 `scripts/generate_capability_matrix.py`；运行时真实能力必须由 `MediaCapabilities` / `ChatCapabilities` 按平台、角色和供应商查询。

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

¹ ARTC macOS 需要宿主另行配置官方原生 Framework，仓库不随包再分发，缺少依赖时不可用。² macOS AWS 采用内部 WebKit JS 运行时，不应等同于拥有原生桌面屏幕共享桥。公开 Provider `aws` 根据模式选择 Chime（Meeting）或 IVS（Live）。Web 指常规 JavaScript Flutter Web，**不是**整套依赖已经支持 Wasm。iOS Simulator 受 ARTC 原生二进制限制，不能用无签名设备目标的编译结果推断模拟器可用。

**发包边界：**内部 `packages/flutter_realtime_sdk` 是轻量、`publish_to: none` 的开发入口；对外发布的 `flutter_realtime_sdk 0.1.0-dev.27` 是把内部源码和第三方依赖组装成的**单一 Pub 包**。因此外部宿主只声明一个 SDK 依赖、显式注册 `create*Provider()`，但单包依赖图仍可能安装未选中的原生插件/二进制，按需注册并不等于按需安装。来源：`scripts/assemble_single_sdk_distribution.py`、`scripts/prepare_single_sdk_release.py`、`scripts/templates/single_sdk_README.zh-CN.md`。

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
| ARTC | Web 捕获/远端映射有代码 | MediaProjection 桥有代码 | iOS 27+ ScreenCaptureKit 外部屏幕流；旧系统未接 | 主要是远端接收；发送端/Framework 有缺口 | 无 Driver |
| Chime | 浏览器 Content Share | 原生发送端未接 | iOS 27+ ScreenCaptureKit → Content Share，远端 Content Tile 待验收 | 无桌面发送桥 | 无 Driver |
| IVS | 浏览器屏幕**替换摄像头** | 原生发送端未接 | iOS 27+ ScreenCaptureKit → Stage 替换摄像头，非双路 | 无桌面发送桥 | 无 Driver |

所有 iOS 27+ 路径均须双端验证切出 App 后画面继续、授权/撤销、远端轨道、音频和退出清理；LiveKit 旧版 ReplayKit 要求 App Group 与 Broadcast Extension 签名。IVS 单 Token 模式无法同时发布摄像头和屏幕两路视频。Web 移动浏览器不能从桌面 Web 支持推断为可共享。屏幕录制标注限于 SDK 自身显示画布，不是系统级桌面涂鸦层。详见 [逐厂商屏幕共享实现说明](SCREEN_SHARING_PROVIDER_STATUS.md)。

## 四、虚拟背景与平台桥

| Bridge | Android | Web | macOS | iOS | Windows |
| --- | --- | --- | --- | --- | --- |
| 采集/分割/模糊/换图/预览 | Native Frame Hub + Texture | 处理后 MediaStreamTrack + HTML video | CVPixelBuffer + Texture | Vision / Core Image + Texture，**无签名 Release 构建已验证、真机待验收** | Media Foundation + ONNX、Texture 源码已写，**Windows 构建/实机待验收** |
| 真实远端处理后画面 | 非全厂商/设备验收 | 非全浏览器/厂商验收 | 非全厂商验收，WebKit 运行时有条件 | 六厂商组合不能一概宣称通过 | 未验收 |

声明层所有六个媒体引擎有 `ProcessedVideoSink` 源码，但实际开关需要同时满足 Provider 角色权限、Bridge 可用和 Runtime Probe；没有 Sink 时要求**失败关闭**，不能偷偷把原摄像头未处理背景发布。原生帧不走 Dart MethodChannel。来源：`packages/flutter_realtime_video_effects`、`packages/flutter_realtime_media_*/lib/src`，以及自动声明文档。

**Windows 补强记录（本轮未发布）：**Windows 原生 box blur 已优化为线性复杂度；对不合法效果值采取失败关闭、摄像头断线后重新选择设备可恢复、WIC 图片解码前增加尺寸校验；新增 Windows CI，覆盖 MSVC CTest、多 Provider Demo 和单包 SDK 的原生构建。当前机器仅完成可移植 C++/Dart/单包组装测试，**未执行 Windows CI 或双设备 RTC**。详见 [Windows SDK 实现与验收说明](WINDOWS_SDK_IMPLEMENTATION_2026-11-06.zh-CN.md)。

## 五、独立 Chat、课堂、直播与录制

| 功能域 | 代码能力 | 本轮不能声称的事项 |
| --- | --- | --- |
| Product Chat | Agora Chat、Tencent Chat、IVS Chat 独立于 RTC 选择；发送/接收、按凭证的管理与刷新；无产品 Chat 时，双向 RTC Data 方可提供短期 fallback | 不提供通用服务端历史分页；产品 Chat 连接失败不自动降级为 RTC 聊天；RTC fallback 无管理员和持久历史 |
| Classroom | 普通/课堂会议、举手、点名与发言许可、问答、投票、小测、公告、计时器、作业发布、资料链接、参与统计 | 其他厂商不具备 LiveKit 同等级别的服务端麦克风发布强制策略；作业提交/批改、正式应到名单、课程资料完整上传/预览不闭环 |
| 白板/共享内容 | 分页、撤销、清除、工具标注、迟加入快照、权限/Revision 冲突、统一内容舞台 | 共享屏幕标注必须有可用远端屏幕轨道；非所有设备/厂商已实测远端像素与坐标 |
| Live 互动 | 点赞、虚拟礼物、数量、去重/重试、历史快照、视频舞台近期礼物条幅、主动/被动结束直播 | 没有真实支付、积分、结算；不等于自动具备所有厂商实时 Chat |
| 云录制/MP4 | SDK 统一开始/停止/状态/结果接口；Demo Server 有 LiveKit、Chime、IVS、Agora、TRTC、ARTC 厂商执行器；历史记录中 LiveKit/Chime/IVS 曾获用户实际成功反馈 | Agora 等供应商真实录制与存储配置仍有待验收；不代表各平台所有录制布局/长时间音画/课程历史回看均已通过 |
| 生命周期 | 房主关房、普通成员本地退出、远端关房心跳终止、清理前停止云录制（具备对应实现） | 不等于厂商层瞬时强制断开；5 秒轮询不是精确 5 秒退出 SLA；同时断线/弱网/多厂商均待双机验收 |

相关实现和证据分别见 [Classroom SDK](CLASSROOM_SDK.md)、[Live SDK](LIVE_INTERACTIONS_SDK.md)、[云录制](CLOUD_RECORDING.md)、[音频专项](MICROPHONE_CROSS_PLATFORM_AUDIT.md)、[跨端审查](RTC_VENDOR_PLATFORM_AUDIT_2026_11_04.md)。

## 六、已核实与待验收

**本次源码复核：**重新执行声明生成、声明测试和 44 包架构检查。最近一次 `dev.27` 发布流程中，44 包内部分析/测试、95 项 Python 测试、Edge/Chromium Web 回归及 Pub dry-run（0 warnings）通过；独立 Demo 已能通过 `flutter pub get` 获取 dev.27、通过 Flutter 分析/测试，iOS 无签名和 Android Release 构建成功。这些是**不同层次的证据**，不能叠加成六厂商全平台已通过。

**最重要的验收缺口：**逐厂商 Web↔iOS、iOS↔Android 真实双向麦克风/扬声器、摄像头与远端黑屏；切 Safari/其他 App 的 iOS 屏幕共享；Agora Web→原生共享类型信令；Chime/IVS 原生非 iOS 27 屏幕共享；iOS 多 WebRTC 二进制共存；Windows 本机原生链接；非 LiveKit 的强制禁麦；全供应商云录制与 MP4 音画完整性；资源清理和重连稳定性。

复查命令（SDK 工作区根目录）：

```bash
python3 scripts/generate_capability_matrix.py
python3 scripts/generate_capability_matrix.py --check
python3 -m unittest scripts.tests.test_capability_declarations -v
python3 scripts/check_sdk_architecture.py
```
