# Flutter Realtime SDK（中文说明）

[English](README.md) · **简体中文**

`flutter_realtime_sdk` 是**一个公开的 Flutter SDK 包**，整合会议、直播、聊天、可选的组合式 UI、课堂和直播互动预设。所有 API 使用**同一个 Dart import**，但仍需显式注册要使用的 Provider。

**当前版本：`@VERSION@`（预览版）。** Android、iOS、macOS、Web 等平台注册能力不代表每一家供应商均完成真机验证。Windows/Linux、长期稳定性和跨供应商共存的部分验收尚未完成。请参阅 [供应商/平台能力矩阵](https://github.com/lengsukq/multi-video/blob/main/doc/SDK_CAPABILITY_MATRIX.zh-CN.md)。

## 一、安装

需要 Flutter ≥ 3.47、Dart ≥ 3.12。原生最低版本：Android API 28、iOS 15、macOS 12。

在应用的 `pubspec.yaml` 中添加：

~~~yaml
dependencies:
  flutter_realtime_sdk: ^@VERSION@
~~~

不需要再依赖 `flutter_realtime_provider_*` 等开发仓库内部包。

## 二、创建会议 / 加入房间

~~~dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';

final realtime = Realtime(
  backendUrl: 'https://your-backend.example',
  providers: [createLivekitProvider()],
  services: const RealtimeRoomServices(
    videoEffectsFactory: DefaultRealtimeVideoEffects.new,
  ),
  featurePlugins: const [
    ClassroomPreset(),
    SharedContentPreset(),
    LivePreset(),
  ],
);

final connection = await realtime.open(
  RealtimeRequest.join(
    type: RealtimeExperience.meeting,
    roomCode: '123456',
    user: const RealtimeUser(id: 'user-1', name: 'Alice'),
  ),
);

final room = connection.mediaRoom!;
// 完全自由的 UI，或使用 RealtimeRoomView(room: room)。
// 真正离开房间时：await connection.dispose();
~~~

也可以调用 `RealtimeRequest.create(...)` 创建房间，选择
`RealtimeExperience.live` 或 `RealtimeExperience.chat` 分别用于直播和独立聊天。
Media Provider 和 Chat Provider 可以独立注册和选择。
课堂/直播预设需要可信后端的权威状态和权限控制；礼物等示例不提供支付结算。

**后端与安全：** 你可以使用仓库 Demo Server 的参考接口，或者用
`RealtimeSource.credentials(...)` 接入自己的短期凭据服务。
供应商 App Certificate、签名密钥、云存储密钥只能放在可信服务端，
不要写入 Flutter 客户端。

## 三、内置 UI 与升级

Demo 直接展示 SDK 提供的 `RealtimeRoomView`（按房间选择会议/直播页面）、
`RealtimeMeetingPage`、`RealtimeLivePage`、`RealtimeChatPage` 和
`RealtimePreJoinPage`。房间页面通过 `RealtimeRoomViewConfig` 配置，
预入会回调使用 `RealtimePreJoinEnter`，麦克风与摄像头默认关闭。
宿主负责路由，在真正离开时显式销毁连接。

此版本已移除旧的 `MediaRoomView`、`MediaPreJoinPage`、`RealtimeChatView`、
`RealtimeComposableRoomTemplate`、`RealtimeComposablePreJoinTemplate` 和
`ChatDefaultPage`；升级时将 `MediaRoomViewConfig` 替换为
`RealtimeRoomViewConfig`。可组合控件与 Headless 接口继续保留。

会议共享屏幕或白板时，底部保留自己和其他人的缩略图。点击人物可放大其画面，
共享内容变成实时只读预览；点击预览或“返回共享内容”可切回。
“隐藏缩略图 / 显示缩略图”仅影响当前房间的本地布局，不启停采集，也不改变
其他参会者的视图。自行组合页面时可使用 `RealtimeMeetingParticipantStrip`
及 `RealtimeMeetingStage.showFilmstrip`。

### 自定义会议 UI：Scope、弹窗和离会

`RealtimeRoomUiScope.of(context)` **只能使用 Scope 子树里的
BuildContext**。创建 Scope 的页面 State 自身位于它的上方；
普通 Dialog/BottomSheet 又构建在 Navigator 的 Overlay 中，
不会自动继承会议页面 Scope。要从子树的 `Builder` 获得
`controller`，并传给 SDK 提供的弹窗 API：

~~~dart
RealtimeRoomUiScope(
  room: room,
  child: Builder(
    builder: (roomContext) {
      final controller = RealtimeRoomUiScope.of(roomContext);
      return Column(
        children: [
          TextButton(
            onPressed: () => showRealtimeRoomUiBottomSheet<void>(
              roomContext,
              controller: controller,
              builder: (_) => RealtimeMediaDevicePicker(
                kind: MediaDeviceKind.microphone,
              ),
            ),
            child: const Text('选择麦克风'),
          ),
          RealtimeLeaveButton(
            closeForEveryone: false,
            onLeft: () {
              if (roomContext.mounted) Navigator.of(roomContext).maybePop();
            },
          ),
        ],
      );
    },
  ),
);
~~~

`showRealtimeRoomUiDialog` 用法相同。两个 helper 只是**借用**
已有 Controller，不另建房间、不会负责销毁 Controller；关闭房间前应先
关闭相关弹窗。`Navigator.pop()`、UI 卸载、`controller.close()`、
`controller.leave()` 和 `connection.dispose()` 的责任不同，
不能混为一谈。SDK 退出按钮等到离会完成后才调用导航回调；
结束所有人会议则必须考虑房主权限及云录制状态，并由可信后端鉴权。

更完整的示例与排错请看
[房间 UI 生命周期指南](https://github.com/lengsukq/multi-video/blob/main/doc/ROOM_UI_LIFECYCLE.zh-CN.md)。

## 四、Headless 模式、虚拟背景与摄像头

宿主应用可以只用 SDK 的数据、媒体与操作接口，自己绘制会议/直播页面。
如果选择虚拟背景，先像上例一样配置 `videoEffectsFactory`。
开启摄像头时请使用 **`room.setCameraEnabled`**，不要直接调用
`room.media.session.setVideoEnabled` 以免绕过摄像头处理源与背景变更的串行协调。

~~~dart
// 入会后，先判断当前供应商和平台是否支持该效果：
if (room.backgroundCapabilities.canBlur) {
  // 关镜头时选择模糊：先准备效果，不应发布未经处理的画面。
  await room.setBackgroundEffect(const MediaBackgroundEffect.blur());
}
// SDK 在发布之前同步开启已附着的处理源：
await room.setCameraEnabled(true);

// 运行中切换效果，也可以再次关闭摄像头：
await room.setBackgroundEffect(const MediaBackgroundEffect.none());
await room.setCameraEnabled(false);
~~~

需要图片背景时还必须提供可用的图片数据和相应能力。
摄像头与虚拟背景依赖平台权限及对应 Provider。若处理源初始化失败，
应向用户提示具体错误，不能悄悄降级为原始摄像头发布。
`prepareVideoEffects(MediaLocalPreviewSettings(...))` 可用于入会后的预设，
但普通开关摄像头应以 SDK 的统一方法为准。

Web 切换效果会等待首个可用的处理帧；摄像头/背景操作失败时会抛出
`RealtimeException`。运行中也可能发生处理故障（例如 GPU 上下文丢失），
请订阅 `room.events` 中的 `RealtimeBackendFailure` 并读取 `event.error`。
SDK 会停止故障发布；显式重设效果成功后才能重新开启摄像头。
即使没有订阅事件，最近的错误也会保留在 `room.diagnostics`。
业务提示与恢复逻辑使用 `code`、`domain`、`operation`、`suggestedAction`；
私有诊断日志可记录 `cause`、`details`、`stackTrace`。
公开 message 刻意不拼接厂商原始载荷与凭证。

房间返回前，`await realtime.open(request)` 会把失败抛给宿主，此时房间组件尚未挂载。
请将异常保留在应用状态中，使用
`RealtimeStrings.of(context).displayRealtimeError(error)` 显示持续可见的提示，
并让用户重新发起原请求。只依赖短暂 SnackBar 容易错过错误。
入会后，成品页面也会通过已有错误回调展示异步房间/媒体故障。

成品会议/直播页的媒体与共享内容准备阶段各有 15 秒等待上限；Web 媒体入会有
20 秒截止时间，随后执行有上限的清理。网络仍须能访问所选供应商的服务端点。
媒体桥与效果桥分别声明协议版本；不兼容资源会提前返回
`webBridge.versionMismatch`，建议动作是 `reload-web-runtime`。
升级 SDK 后请完整重启/重建宿主；热重载无法给旧的已编译 Dart 补上新的检查逻辑。

## 五、iOS 配置（发布单包）

iOS 最低版本为 **15.0**，保留 Flutter 默认的 Swift Package Manager 支持。
合并插件为 ARTC/Chime 和自有桥接使用 CocoaPods；部分第三方插件通过 SwiftPM 集成。

IVS Broadcast 1.47.0 与 IVS Chat 1.0.1 会在 `pod install` 阶段从 AWS
官方 HTTPS 归档下载，通过 `ios/vendor_frameworks.json` 中固定的 SHA-256 校验。
Pub 包**不重新分发这些供应商二进制文件**，首次安装需要可访问官方 AWS 下载地址。

请在 `ios/Podfile` 中设置：

~~~ruby
platform :ios, '15.0'
~~~

然后添加（如果已有同名 hook，请合并其内容）：

~~~ruby
post_integrate do |installer|
  require_relative '.symlinks/plugins/flutter_realtime_sdk/ios/podfile'
  FlutterRealtimeSdk::PodfileIntegration.deduplicate_agora_frameworks!(installer)
end
~~~

这会在 Agora RTC 的 SwiftPM 产品存在时，避免 Agora RTC/Chat 重复嵌入
`aosl.framework`；**并不代表所有设备上的 Agora 共存已经验收通过**。
当前 ARTC 框架仅支持真机，因此该合并包不支持 iOS Simulator。

如需受控或离线安装，可设置 `FLUTTER_REALTIME_SDK_IOS_OFFLINE=1`；
也可以设置 `FLUTTER_REALTIME_SDK_IOS_ARCHIVE_CACHE` 指向包含两个
`<sha256>.zip` 官方缓存包的文件夹。离线模式下缺失或校验失败会直接报错，
不会暗中使用未知版本的供应商 SDK。

宿主应用还必须提供摄像头、麦克风权限用途说明。屏幕共享等能力可能还需要
各平台的独立权限、扩展或其他系统配置。

## 六、发行范围和限制

- **一个 pub.dev 依赖不等于只安装一个供应商的原生 SDK：** 所有发布包声明的原生依赖仍会参与解析/构建。
- Web 可使用常规 JavaScript 构建；当前完整依赖集合的 Wasm 兼容性尚未完成验证。
- Windows/Linux、完整真实供应商 E2E、长期媒体稳定性仍是待验收项目。
- 单元测试与编译通过不能替代真实设备连通性、录制、云文件清理等测试。
- 本项目自有代码使用 MIT 协议；第三方 SDK 仍遵守各自的授权及服务条款。

## 七、相关文档

[英文说明](README.md) ·
[仓库中文首页](https://github.com/lengsukq/multi-video/blob/main/README.zh-CN.md) ·
[首次完整接入](https://github.com/lengsukq/multi-video/blob/main/doc/APP_INTEGRATION_QUICKSTART.zh-CN.md) ·
[Headless / Runtime](https://github.com/lengsukq/multi-video/blob/main/doc/SDK_RUNTIME_INTEGRATION.zh-CN.md) ·
[能力矩阵](https://github.com/lengsukq/multi-video/blob/main/doc/SDK_CAPABILITY_MATRIX.zh-CN.md) ·
[云录制](https://github.com/lengsukq/multi-video/blob/main/doc/CLOUD_RECORDING.md)
