# 麦克风与远端音频：供应商 × 平台审查（2026-11-04）

> 本记录以仓库当前源码为准。**麦克风 UI 显示开启、发言动画、RTC 服务端已收到音轨、远端扬声器有声是四个独立结果**。静态分析、模拟测试、Xcode 无签名编译均不等价于双端实测。

## 代码排查和修复

| 供应商 | Web | iOS | Android / macOS / Windows |
|---|---|---|---|
| LiveKit | Flutter LiveKit 自动订阅远端音频；需浏览器授权播放 | 优先扬声器（保留耳机、蓝牙优先级）；麦克风开启后必须有未静音的真实 publication；发言者状态由 ActiveSpeakersChangedEvent 驱动 | 沿用 LiveKit 原生音频生命周期；未做双端真机验证 |
| Agora | 默认静音；仅明确开启麦克风时创建并发布音轨；订阅后调用 audioTrack.play() | 现有 engine.enableAudio / autoSubscribeAudio / 设备路由 | Android、桌面沿用 SDK 音频，需各平台双端回归 |
| 腾讯 TRTC | 修复入会时主动启动且默认未静音的问题；现在启动后立即静音，明确开启才取消静音；autoReceiveAudio=true | 原生入会 startLocalAudio 后静音；远端按厂商音频模块接收 | Android、桌面原生链路尚需独立验证 |
| 阿里 ARTC | 旧版只调用 muteLocalMic，可能未发布音频；现在入会显式不发布，开启时调用 publishLocalAudioStream(true)，失败则不上报成功 | 原生同样显式 publishLocalAudioStream(true/false) | Android 原生已接，桌面驱动因平台而异；未做跨端验收 |
| AWS Chime | **修复缺少 bindAudioElement 导致混音音频无法播放**；播放权限失败可在下次用户操作重试；未获得音频输入时明确报错 | playAndRecord 使用 defaultToSpeaker，首次连通时同步初始静音；修正取消静音失败消息 | 原生 Android / 桌面实际路由仍需设备回归 |
| AWS IVS Real-Time | 默认静音与原生一致；设备切换保留原静音状态；远端自动播放被浏览器阻断后上报错误，并在用户手势后重试 | IVS Stage 原生麦克风 stream 默认静音，无可用麦克风时拒绝假开启 | 其他平台需检查原生 Stage 实现及音频路由 |

## iOS 多供应商二进制冲突

同一 App 同时链接独立 `WebRTC.framework`、`AmazonChimeSDKMedia.framework`、`AliVCSDK_ARTC.framework` 时，iOS 日志已经报告 `RTCRtpCapabilities`、`RTCAudioSession` 等 Objective-C 类重名。

这不是普通的提示文案问题：**可能因运行时绑定到错误的 WebRTC/AVAudioSession 实现而出现没有声音或崩溃**。应用能显示首页、Xcode 能编译，不代表混用这些二进制时音频链路安全。根治应做原生依赖隔离/厂商兼容性验证，或按发行 Flavor 将真正不使用的原生供应商二进制排除；不可简单删除某一个 WebRTC.framework，否则可能让另一家 SDK 启动失败。本次未尝试未经厂商支持的二进制修改。

## 回归验收（分别在同一供应商、同一房间执行）

1. Web → iPhone、iPhone → Web，双方轮流解除静音。核对真实音轨发布、远端听到声音、发言指示和静音按钮。
2. iPhone ↔ Android、Web ↔ macOS（有对应 Driver 才执行），用有线耳机、蓝牙耳机、听筒和外放分别测试；不能把缺失 Driver 标为通过。
3. 禁止/撤销麦克风权限、无输入设备、在浏览器中拒绝自动播放，均必须产生可定位的失败或手势恢复路径，不能只改变 UI 状态。
4. 共享屏幕和切到后台时，检查麦克风是否按系统/厂商约定继续工作；停止共享、离会、重连后，确认没有遗留采集、播放或静音状态。
5. iOS 全供应商合并宿主与单供应商原生宿主分别测试，用以判断 `RTC*` 类冲突的影响。

## 自动验证边界

当前 SDK Web 桥接测试、LiveKit Flutter 单测、iOS 无签名编译已覆盖本轮修改所涉及的 API 结构。尚未完成六家供应商在所有目标平台上的双设备音量、扬声器和录制实测。已发布的 `0.1.0-dev.21` 不会被 Git 修改自动更新，以上音频修复须在新的预览版本发布后才能被外部 Demo 消费。
