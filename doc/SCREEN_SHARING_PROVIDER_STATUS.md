# 屏幕共享：供应商 × 平台实现/验证矩阵

> 审查基于统一媒体 SDK 的真实 adapter/source/controller，而不是厂商官网支持矩阵。**源码接入 / SDK 能力声明 / 真实多人远端画面验收是三种不同状态。** 不要仅通过客户端按钮是否显示来判断成功。

## 标准契约

`InteractiveMediaSession.setScreenShareEnabled(true/false)` 是供应商无关的共享入口。`snapshot.localScreenShareEnabled` 必须只在真正的本地采集/发布成功时为 true；`snapshot.contentShareTrack` 是共享画面轨道，`MediaTrackPublished/MediaTrackUnpublished` 通知 UI；远端应按共享源原始纵横比 `BoxFit.contain` 展示，而不是裁剪。用户主动停止、屏幕源意外终止、权限被拒绝、离会/销毁都必须清理采集资源与状态。

**凡仅能接入摄像头，但无法远端正确呈现共享画面的组合，均不应称为已完成全链路。**

## 当前代码状态

以下表格中的“基础”表示采集与控制代码存在，未实机验收；“初步”表示本轮已接入部分代码，仍缺完整远端/权限验收；“未接”表示 SDK 未接通，不代表厂商官方不支持；“条件”表示取决于浏览器/系统。

| RTC 媒体适配器 | Web 桌面浏览器 | Android | iOS | macOS | Windows |
|---|---|---|---|---|---|
| LiveKit | 基础，浏览器授权 | 基础，MediaProjection | **应用内屏幕共享已修复（待真机实际授权和远端验收）**；跨 App 全系统共享仍需 Broadcast Upload Extension + App Group | 基础，系统屏幕录制权限 | 基础，待 Windows 构建/实机 |
| Agora | 初步，屏幕选择/取消/恢复摄像头已修复；已能接收原生端共享状态，但 Web 发送端缺可靠跨平台信令 | **初步，MediaProjection Capture + 共享发布/远端共享信令与轨道映射已有**，真实双设备待验收 | 未接 ReplayKit Broadcast Extension | **初步，本轮补官方共享显示器枚举 + 自动选择主屏幕**，待实机验证 | **初步，本轮补官方共享显示器枚举 + 自动选择主屏幕**，待 Windows 构建和实机 |
| 腾讯 TRTC | 初步，JS 辅路采集与播放 | 基础，原生辅路 | 条件，原生 ScreenCapture/ReplayKit 扩展配置需验收 | **初步，本轮实现主显示器自动枚举/选定 + 辅路采集** | **初步，本轮实现主显示器自动枚举/选定 + 辅路采集**，缺 Windows 构建 |
| 阿里 ARTC | 初步，Web 摄像头/屏幕流分流和清理 | **初步，Android MediaProjection 共享 SDK+原生桥已接，独立远端屏幕轨道和撤销回调已接；待真机** | **接收远端共享已接；发送整个系统屏幕仍缺 ReplayKit Broadcast Extension** | **接收远端共享已接；发送端尚缺屏幕源选择；需额外厂商 Framework** | 无默认原生 Driver |
| AWS Chime | 基础，桌面浏览器 Content Share | 未接原生 Content Share 桥 | 未接原生 Content Share/ReplayKit 桥 | 未接 SDK 桌面共享桥 | 无默认 Chime Driver |
| AWS IVS Real-Time | 初步，**单 Token 只发布一路视频**：开始共享替换摄像头，停止后恢复；要同时发布需要第二个 Stage Token，远端区分仍待验收 | 未接原生 Broadcast 屏幕源 | 未接原生 Broadcast/ReplayKit 屏幕源 | 未接桌面共享桥 | 无默认 IVS Driver |

Web 浏览器是否支持 `navigator.mediaDevices.getDisplayMedia` 需运行时检测。桌面 Chrome、Edge、Safari 的实现与权限不同，**移动浏览器不能因为同属 Flutter Web 就宣称能共享系统屏幕**。

## 已完成的 SDK 修复

- **LiveKit iOS 应用内屏幕共享（下一预览版本，尚未发布）：** `livekit_client 2.13.x` 的 `LocalParticipant.setScreenShareEnabled(true)` 在 iOS 上无条件转入 `BroadcastManager.requestActivation()`；即使 `useiOSBroadcastExtension: false` 且宿主没有配置扩展，也可能静默返回而不发布轨道。SDK 现改为显式使用 `LocalVideoTrack.createScreenShareTrack(useiOSBroadcastExtension: false)` 与 `publishVideoTrack`；发布失败时关闭已创建的 ReplayKit 本地轨道，确认实际存在 `screenShareVideo` publication 后才允许业务层提交共享模式。**这是仅共享当前 App 的方案，不能共享切到后台后的其他 App。** 全系统共享仍需在宿主 App 集成 Broadcast Upload Extension、App Group、签名和停止事件闭环。

- **统一 Web 状态**：`provider_web_session_factory.dart` 根据本地共享轨道同步 `localScreenShareEnabled`，避免实际共享成功但 UI 永远显示未开启。
- **Agora Web**：先等待用户选择屏幕再停止原来的摄像头发布；取消选择不影响摄像头。发布失败释放屏幕并恢复摄像头，停止共享后恢复摄像头。
- **TRTC/ARTC Web**：幂等开启、停止和轨道释放；ARTC 根据远端视频 bitmask 区分摄像头和屏幕；发布失败清理。
- **IVS Web**：采集失败释放本地屏幕轨道，避免重复开启；观众角色禁止发起屏幕共享。单 Token 发布限制下，屏幕与摄像头互斥发布、停止后恢复摄像头、共享期间切换摄像头只更新待恢复源；离开房间时释放两者。屏幕分辨率按 IVS 文档约束到 720p。
- **Agora Android**：`startScreenCapture/stopScreenCapture`、`ChannelMediaOptions.publishScreenCaptureVideo`、本地屏幕轨道与退出清理；原生视频失败回调同步清除活动状态。通过 Agora RTC DataStream 私有 topic 向其他客户端通知共享开始/停止、向迟加入用户重发当前状态；远端切换摄像头/共享轨道并在共享者离线时清理；控制消息不进入聊天室。
- **Agora macOS/Windows**：通过 `getScreenCaptureSources` 获取官方可共享显示器列表，优先选择 `primaryMonitor`，调用 `startScreenCaptureByDisplayId` 捕获主屏幕，并复用统一共享发布、远端通知与状态清理。屏幕录制授权和窗口/其他显示器手动选择尚未实机验收。
- **Agora Web 接收端**：能处理原生端发送的共享状态信令，将远端普通视频轨道转换为 `isScreenShare` 轨道，并在停止时恢复显示。
- **TRTC macOS/Windows**：使用 `getScreenCaptureSources` 选择主显示器并 `selectScreenCaptureTarget`，再沿用已存在的辅路编码/远端订阅。
- **ARTC Android / 远端跨平台接收**：`ArtcEngine` 通过 MethodChannel 调用 Android `AliRtcEngine.startScreenShare/stopScreenShare`（视频模式），安卓厂商回调更新共享状态。远端相机与屏幕按官方 Camera=1/Screen=2/Both=3 的掩码分轨；Android、iOS 和可用时的 macOS 使用相应的原生渲染源。业务 SDK 保持同一 `setScreenShareEnabled()` 接口，Demo 不承载供应商适配。厂商接受 API 调用与真实屏幕出帧不同，仍须实机验证 MediaProjection 授权、系统停止与录屏前台服务。

## 仍未完成的关键闭环

1. **Agora Web 发起共享时的反向信令和端到端验收**：Agora Web 4.24.8 有 `stream-message` 接收事件，但没有可用的 `sendStreamMessage` 发布接口。原生 → Web 的 DataStream 控制消息已接通代码层；Web → 原生需另设 provider-neutral 信令服务/IM 通道或合法的屏幕子 UID/Token，不能用视频宽高猜测屏幕类型。所有方向都还需要实机确认。
2. **ARTC/Chime/IVS 剩余原生平台适配**：ARTC Android 的共享接入已新增，但尚需实机媒体验收；ARTC iOS/桌面发送端、Chime/IVS 原生采集仍需实现。尤其 Chime Android/iOS 官方 SDK **有** Content Share 能力，但当前 Flutter 适配尚未实现。
   IVS **同时发布摄像头和屏幕**按 [AWS 官方说明](https://docs.aws.amazon.com/ivs/latest/RealTimeUserGuide/web-publish-subscribe.html) 需要额外的共享 Stage Token 和独立参与者；目前 Demo 的单 Token 模式采用暂停摄像头视频并共享屏幕的策略，而非双路并行。
3. **iOS 跨 App 全屏共享**：ReplayKit Broadcast Upload Extension 和 App Group、原生 SDK 的广播上传桥须由示例 Host App 正确安装并签名；Flutter 单一入口无法省掉扩展。当前 LiveKit iOS 仅应用内捕获，不是整机屏幕。
4. **原生桌面多显示器与窗口共享**：TRTC 和 Agora 都已接主显示器自动选择；但还没有 SDK 级共享源列表 UI / 手动选择其他显示器或窗口，也没有桌面真机播放验收。AWS 桌面仍未接入。
5. **运行时权限和系统停止事件**：Android 前台 MediaProjection 服务，macOS 屏幕录制权限，iOS 广播停止、浏览器 `track.ended`、销毁和重连；真实场景均需端到端确认。
6. **多供应商/多平台验收**：每个组合至少用双设备测试本地采集 → 发布 → 远端订阅 → 坐标与画面比例 → 主动停止/权限拒绝/意外停止 → 重连与退出。自动化 Mock 测试不等于真实 SDK 通过。

官方资料：[Agora Flutter Screen Sharing 示例](https://github.com/AgoraIO-Extensions/Agora-Flutter-SDK/blob/main/example/lib/examples/advanced/screen_sharing/screen_sharing.dart)、[腾讯 TRTC 屏幕共享](https://trtc.io/zh/document/39859?platform=flutter)、[AWS Chime 移动屏幕共享](https://aws.amazon.com/about-aws/whats-new/2021/01/amazon-chime-sdk-ios-android-support-screen-share/)。
