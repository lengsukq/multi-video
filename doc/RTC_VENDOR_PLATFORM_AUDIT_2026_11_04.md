# 六家 RTC 供应商 × 五个平台：官方文档与 SDK 实现审查

审查日期：2026-11-04。范围：`flutter_multi_livestream_video` 的 LiveKit、Agora、腾讯 TRTC、阿里 ARTC、Amazon Chime、Amazon IVS Real-Time，及 Web / iOS / Android / macOS / Windows。以下是**源码核对与自动化测试**结果，并非所有供应商的设备或真实账号验收。

## 审查口径

- **实现**：能找到 SDK 内部 Adapter、原生桥或 Web 驱动，不表示真实远端已经正确收到音视频。
- **回归**：有模拟/单元/静态分析或编译证据，仅证明受测行为；真机、真实供应商 Token、多设备、耳机/蓝牙音频路由另行验收。
- **缺口**：仓库未实现所需 Driver、SDK 被平台限制或依赖官方额外 Token/权限时，不能把它标为已支持。
- **2026-11-04 更新**：聚合 SDK 的 `0.1.0-dev.24` 已发布并由独立 Demo 从 pub.dev 成功解析。该版本包含 IVS 在插件注册阶段抢占 `AVAudioSession` 的修复；发行包通过静态与编译检查不等于六家厂商全量设备运行时验收。

## 六家供应商跨端实现矩阵

| RTC | Web | iOS | Android | macOS | Windows |
|---|---|---|---|---|---|
| LiveKit | Flutter/WebRTC 订阅、发布；浏览器音频自动播放仍受用户交互策略限制 | iOS 27+ ScreenCaptureKit 全屏共享；旧版 ReplayKit Extension 回退；默认扬声器偏好；真机待验收 | 原生 WebRTC / MediaProjection 适配；真机待验收 | 原生 WebRTC / 共享屏幕，需系统授权 | Windows WebRTC 桌面能力依赖宿主/插件构建；真机待验收 |
| Agora | 音轨按需发布，远端 `subscribe` + `audioTrack.play`；屏幕共享回传原生端的类型信令仍有缺口 | 原生 RTC + iOS 27 ScreenCaptureKit 适配；真机待验收 | 原生 RTC + MediaProjection，真实共享、权限待验收 | SDK 枚举屏幕源，自动主屏共享 | SDK 枚举屏幕源，Windows 构建和屏幕权限待验收 |
| TRTC | 已改为显式开麦、正确 `startScreenShare`/ `stopScreenShare`，远端视频用真实 HTMLElement | 原生按需开麦、音量评估和发言事件、ScreenCaptureKit；真机待验收 | 原生按需开麦、音量评估、MediaProjection；真机待验收 | 原生音量回调、选择主屏幕共享 | 原生音量回调、选择主屏幕共享；Windows 构建待验收 |
| ARTC | 校验媒体控制返回码，不再把失败发布误报成功 | 原生音视频 / iOS 27+ 屏幕轨道，真机待验收 | 原生音视频 / 屏幕共享桥，真机待验收 | 有条件：宿主需额外厂商 Framework；发送端屏幕源选择尚缺 | 无默认完整原生 Driver |
| AWS Chime | 已绑定远端 AudioElement；开麦/开摄像头才采集，关摄像头释放采集；浏览器自动播放可重试 | 原生会议音频 / iOS 27 Content Share 适配；真机 Content Tile 待验收 | 原生会议音频，屏幕 Content Share 桥尚缺 | 宿主能力和 WebKit 权限因集成方式而异；无完整原生桌面屏幕共享桥 | 无默认完整原生 Driver |
| AWS IVS Real-Time | Stage 入会无权限提示；显式启动音频/视频，设备切换失败回滚，远端音频和静音事件清理 | **修复插件注册时抢占 AVAudioSession：IVSDeviceDiscovery 按需创建，预入会检查不初始化 IVS**；Stage 单 Token 仅一路视频；iOS 27 屏幕替换摄像头 | Android 原生屏幕共享未接通 | 桌面共享 Driver 未接通 | 无默认完整原生 Driver |

## 本轮已修复的可确认问题

| 优先级 | 供应商/平台 | 原问题 | 实施修复和回归 |
|---|---|---|---|
| P0 | Amazon IVS / iOS 聚合宿主 | 旧 `FlutterRealtimeMediaIvsPlugin` 成员 `IVSDeviceDiscovery()` 在插件注册时立刻构造，间接修改进程共享 `AVAudioSession`；未选 IVS 的 LiveKit/原生录音也可能被中断。排除 Chime/ARTC 后仍复现 | 延迟初始化 IVS 设备发现、预检查改 `AVCaptureDevice`、`leave` 清理；新增源码回归。真机 PCM 采集由约 0.28 秒/5 缓冲恢复至 2.88 秒/31 缓冲；两参与者 LiveKit 音轨发布与开麦/静音操作通过，**实际远端声音和重新启用 Chime/ARTC 后音频仍待验收**，详见 [音频专项记录](MICROPHONE_CROSS_PLATFORM_AUDIT.md) |
| P0 | TRTC Web | 使用不存在于固定版本 `trtc-sdk-v5 5.19.2` 的 `startLocalScreen/stopLocalScreen`，屏幕共享会报错 | 改用官方 `startScreenShare/stopScreenShare`，共享轨道缺失则回滚，离会停止；新增 API、远端 DOM 和失败回归 |
| P0 | TRTC Web + iOS/Android/桌面 | 入会即启动麦克风再静音，提前申请权限、可能在静音前发布音频 | 改为显式取消静音时启动，凭证刷新时仅恢复此前未静音的采集；增加回归 |
| P1 | TRTC 原生 | `onUserVoiceVolume` 未转换为统一 `isSpeaking` / `MediaSpeakingChanged`，发言图标不变 | 按官方 API 启用音量评估，监听本地空 userId 和远端音量，静音/无声时复位，离会关闭；增加 Flutter 回归 |
| P1 | Chime Web | 静音入会和选设备时仍可能先申请麦克风/摄像头权限；关闭摄像头只关视频 Tile 不释放采集 | 设备选择仅保存偏好，开麦/开摄像头时真实采集；关闭供应商摄像头时 stopVideoInput；远端声音仍使用 `bindAudioElement` |
| P1 | IVS Web | 入会即触发 getUserMedia，开视频没有实际 Track 仍可成功；设备切换先停原设备，失败后黑屏/无声 | 延迟采集；按需创建 LocalStageStream 并刷新 StageStrategy；先交换后释放旧轨道，异常回滚；新增回归 |
| P1 | IVS Web | 远端离会不一定触发逐流移除事件，音频标签和自动播放重试监听残留；远端静音不更新 | 在远端 LEFT / STREAMS_REMOVED / 本地 leave/ dispose 中清理 DOM；接入 `STAGE_STREAM_MUTE_CHANGED`、首帧初始 mute 状态 |
| P1 | ARTC Web | 供应商返回非零错误码未必抛 Promise 异常，导致 UI 将音频/视频/屏幕发布视作成功 | 媒体控制显式检查数值返回码，屏幕发布失败恢复预览资源；新增错误码回归 |
| P0 | ARTC Web 观众角色 | 官方文档指出默认入会会发布音频；旧代码仅在非 viewer 角色关闭麦克风发布，观众可能在入会时错误触发音频采集 | 所有角色均在 `joinChannel` 前执行 `publishLocalAudioStream(false)`，观众仍禁止开麦；新增 viewer 回归测试 |
| P1 | Chime Web 屏幕共享 | 调用浏览器屏幕选择器后并没有监听本地 `ContentShareObserver`，UI 可能不知道已成功共享/系统已停止，且本地缺可显示的共享轨道 | 只有 `contentShareDidStart` 与真实 MediaStreamTrack 同时存在时才上报本地共享，系统停止、离会后释放视频轨道和观察者；加入回归 |
| P1 | IVS Web 离会 | `stage.leave()` 未等待 Promise 完成，离会请求还在进行就关闭底层采集；异常时原麦克风可能继续被占用 | `await stage.leave()` 并用 `finally` 统一清理本地、远端音频与屏幕源；加入成功/失败回归 |

## 已核对、未盲目改动的部分

- **Agora Web**：`user-published` 后先 `subscribe`，音频调用 `audioTrack.play`；已有音轨和摄像头切换回归。跨端屏幕共享类型的 Web → 原生信令还未形成完整闭环，不要仅靠分辨率猜测屏幕流。
- **LiveKit**：保留现有 ScreenCaptureKit / ReplayKit 分平台逻辑，保留先验证真音轨发布才展示成功的保护。iOS 说话状态/扬声器修复已在前一轮完成。本轮没有修改核心 LiveKit 媒体实现。
- **IVS 的多路视频限制**：当前单 Stage Token 只能以替换摄像头的方式共享屏幕；同时推送两路视频必须使用单独 Token/参与者方案，不能修改普通 Track 数组伪装成双路。
- **TRTC 官方屏幕限制**：同一房间的辅路屏幕共享存在并发限制，SDK 的回调中必须向用户显式展示厂商拒绝原因；尚无多账号真实冲突验收。

## 尚未解决、需要单独治理的风险

1. **iOS Objective-C `RTC*` 类重名（高）**：同一宿主并入 `WebRTC.framework`、`AmazonChimeSDKMedia.framework`、`AliVCSDK_ARTC.framework` 会报类实现重复警告，可能损害音频路由或稳定性。这是与本次**已确定的 IVS 初始化抢占**不同的独立风险，不能混为同一根因。Podspec 保留 `FRSDK_IOS_DISABLE_CHIME=1` / `FRSDK_IOS_DISABLE_ARTC=1` 原生二进制排除与对应 Swift 注册条件；此时被排除厂商在 iOS 不可用。**dev.24 的 Demo 已恢复两家默认启用**：29 个 Pods 安装成功、iOS 无签名目标编译成功，但真机因锁屏未完成完整厂商组合的 PCM/RTP 和双向声音检查；默认全部启用并不等于二进制冲突已根治。不得直接篡改官方 Framework。
2. **跨端真实媒体（高）**：六家分别测试 Web↔iOS、iOS↔Android，以及实际支持的桌面组合；逐项确认音频双向、发言者指示、屏幕共享切 App、权限拒绝、重连、退出、麦克风/摄像头灯熄灭。
3. **Web 自动播放与 Safari 手势（中）**：实际播放可能仍被浏览器策略拒绝；SDK 已对 Chime/IVS 报错/重试，但真实 Safari/Chrome/Edge 和 WebKit 要分别验收。
4. **跨端功能缺口（中）**：Agora 反向屏幕状态信令、ARTC 原生桌面源选择、Chime Android 和桌面原生 Content Share、IVS Android 与桌面共享等，仍不能宣称完成。
5. **版本发布（中）**：`0.1.0-dev.24` 已发布，44 包质量检查、浏览器回归、Web 资源校验、pub.dev dry-run（0 警告）及独立 Demo 全供应商 iOS 编译通过。**发布成功不代表真实用户音视频已验收**；未来继续发布须选择新版本并重复检查。

## 官方参考资料

- [LiveKit Flutter SDK 参考](https://docs.livekit.io/reference/client-sdk-flutter/)
- [Agora Web RTC 发布订阅教程](https://docs.agora.io/en/realtime-media/rtc/get-started-sdk/web)
- [Tencent TRTCCloud Flutter API（开麦、音量评估）](https://trtc.io/document/50762)
- [Tencent Web 屏幕共享 API](https://trtc.io/document/59651?menulabel=sdk&platform=web&product=rtcengine)
- [Alibaba AliRtcEngine 发布控制/返回码](https://help.aliyun.com/en/document_detail/213528.html)
- [Amazon Chime SDK JS 官方使用指南](https://aws.github.io/amazon-chime-sdk-js/)
- [Amazon IVS Web Stage/Strategy、流静音事件](https://docs.aws.amazon.com/ivs/latest/RealTimeUserGuide/web-publish-subscribe.html)
- [已有的屏幕共享能力矩阵](SCREEN_SHARING_PROVIDER_STATUS.md)、[音频专项审查](MICROPHONE_CROSS_PLATFORM_AUDIT.md)
