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

## 2026-11-04 P0 根因：未使用 IVS 时插件注册抢占 iOS 音频会话

### 现象与定位证据

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

### 修复及防回归

1. 在 `packages/flutter_realtime_media_ivs/ios/flutter_realtime_media_ivs/Sources/flutter_realtime_media_ivs/FlutterRealtimeMediaIvsPlugin.swift` 中，将 `discovery` 改为可选成员，通过 `deviceDiscovery()` **首次真正需要 IVS 本地发布设备/屏幕源时才创建**；`leave()` 时置空。
2. IVS `probeDevices`（入会前检查）使用 `AVCaptureDevice.devices(for: .video/.audio)` 获取数量，不再为了检查设备就初始化 IVS 音频会话。
3. 通过 `scripts/tests/test_ios_ivs_audio_session_lifecycle.py` 限制注册、预检查不得提前创建 `IVSDeviceDiscovery`；`scripts/tests/test_ios_vendor_conflict_isolation.py` 同时保护 CocoaPods `exclude_files` setter 兼容性。
4. 追踪 setter 的临时 Objective-C swizzle 已从最终 Demo 删除，**不可将全局音频拦截作为生产修复方案**。其他供应商仍会注册 Flutter MethodChannel，但不应在插件注册阶段占用共享音频会话。

### 结果与边界

| 测量项 | 修复前（完整插件宿主） | 修复后（完整插件注册、Chime/ARTC 暂隔离时） |
| --- | --- | --- |
| 原生 PCM 采集跨度 | 约 0.28 秒 | **约 2.88 秒** |
| 采集缓冲区 | 5 | **31** |
| 采样帧数 | 24,000 | **148,800** |
| 诊断结束时引擎 | 停止 | **运行中** |
| AVAudioSession mode | `Default` | **`Measurement`** |

另以 LiveKit 自动创建两个参与者，已验证开麦、静音、再次开麦和对端收到**未静音音轨的发布信息**。此结果**不等于**对端扬声器实际出声、PCM/RTP 数据持续发送，也不等于六厂商双向通话全部通过；LiveKit `inputMixer` 入会前配置曾出现 Audio Device Module 尚不可用的日志，仍需用引擎/RTP 统计和两台设备复核。

**正式发布**：`flutter_realtime_sdk 0.1.0-dev.24` 已上传 pub.dev；Demo 已改为从 pub.dev 获取该版本，而非本地 `path` 覆盖。之后恢复 Chime、ARTC 默认启用的完整 iOS 宿主，CocoaPods 安装和无签名编译通过；**由于测试 iPhone 锁屏，恢复后的原生 PCM 和真实双向音频尚未复测**，不能把全供应商共存标为运行时验收成功。

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

SDK 架构/发行工具 94 项测试、44 个内部包逐包检查、Edge 浏览器回归、`0.1.0-dev.24` 发布包分析及 pub.dev dry-run 均已通过。Demo 使用正式 dev.24 依赖完成 iOS 全供应商无签名构建。尚未完成六家供应商在所有目标平台上的双设备音量、扬声器、PCM/RTP 与录制实测；新发布包不会替代这些运行时验收。
