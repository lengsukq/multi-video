# Flutter Realtime SDK：第三方房间 UI、弹窗与退出生命周期

> 面向把 SDK 嵌入已有 Flutter App 的开发者。说明以本仓库 SDK 源码为准。
> **版本边界：** pub.dev 单包 dev.15 已包含
> `showRealtimeRoomUiBottomSheet`、`showRealtimeRoomUiDialog`
> 与 Scope/退出修复。后续源码修改仍需**单独发布新版本**，
> 第三方 App 才能通过升级获得，不应把本地测试通过等同于已发布。

## 1. 三种接入层次

| 方式 | 何时使用 | 谁管理页面 | 谁管理媒体连接 |
| --- | --- | --- | --- |
| `RealtimeRoomView` | 使用 SDK 成品会议/直播页 | SDK 负责页面内组件，宿主负责 Navigator | SDK 退出按钮执行 leave；宿主负责其他连接生命周期 |
| `RealtimeRoomUiScope` + 组合组件 | 自定义布局、工具栏、中文化 | 宿主 | 宿主协调退出；Scope 本身只管理 UI 控制器 |
| Headless `RealtimeRoom` | 全部 UI 都由宿主实现 | 宿主 | 宿主通过 room/connection 公共 API 显式清理 |

源码开发时，UI 组件从
`package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart` 导入；
**已发布单包**使用 `package:flutter_realtime_sdk/flutter_realtime_sdk.dart`。
已发布接口以具体 pub.dev 版本为准；仓库未发布的后续修改不能直接使用。

## 2. 最小的成品 UI 接入

```dart
// connection = await realtime.open(...);
final room = connection.mediaRoom!;
// 在已经存在 Navigator 的宿主页面（其 BuildContext 为 hostContext）：
RealtimeRoomView(
  room: room,
  onLeave: () {
    // SDK 的退出按钮在离会完成后才调用此回调。
    if (hostContext.mounted) Navigator.of(hostContext).pop();
  },
);
```

- `RealtimeRoomView` 读取后端房间模式，选择会议/直播成品页。
- `onLeave` 是**导航回调**，不是启动离会的操作；不要在此回调中再次
  调用 `controller.leave()`，也不要在用户尚未完成离会时先弹出页面。
- 用户通过宿主 AppBar、系统返回、深链切换或路由替换离开时，
  **仅卸载 Widget 不等于离会**。宿主须根据产品策略先执行
  `controller.leave(...)`，或者在不需要远端房间管理操作时显式清理连接
  `await connection.dispose()`，再完成导航。
- 如果已经成功执行过 leave，`RealtimeRoom` 已进入销毁流程；避免把
  `connection.dispose()` 当成另一次结束全员会议操作。

## 3. 组合式 UI 的 Scope 规则

`RealtimeRoomUiScope.of(context)` 只能访问 **Context 祖先链中确实存在**
的 Scope。以下是常见错误：

```dart
class RoomPageState extends State<RoomPage> {
  // 错误：当前 State.context 是 Scope 的父级。
  void closeRoom() {
    RealtimeRoomUiScope.of(context).leave();
  }
  Widget build(BuildContext context) =>
      RealtimeRoomUiScope(room: room, child: const SizedBox());
}
```

正确做法：在 Scope **内部**的 `Builder` 中获得控制器，并将
`controller` 显式传给事件回调、异步逻辑或弹窗：

```dart
RealtimeRoomUiScope(
  room: room,
  child: Builder(
    builder: (scopedContext) {
      final controller = RealtimeRoomUiScope.of(scopedContext);
      return Scaffold(
        body: Column(
          children: [
            const Expanded(child: RealtimeVideoGrid()),
            const RealtimeMicrophoneButton(),
            RealtimeLeaveButton(
              closeForEveryone: false, // 只离开当前参会者
              onLeft: () {
                if (scopedContext.mounted) {
                  Navigator.of(scopedContext).maybePop();
                }
              },
            ),
          ],
        ),
      );
    },
  ),
);
```

不要通过吞掉 Scope 断言、空 catch 或随意 `maybeOf` 返回 null
来掩盖错误的祖先关系。布局切换时可以注入同一个 Controller；将
Controller 注入新 Scope 时由**调用方**负责最终 `close()`。

## 4. Navigator Overlay：Dialog / BottomSheet

`showDialog`、`showModalBottomSheet`、一些 Drawer/Popup
会在 Navigator 的 Overlay 中建立新路由；它们的 builder 并不是
会议页面 Scope 的子树。直接在弹窗 builder 的 Context 上调用
`RealtimeRoomUiScope.of` 可能报：

```text
RealtimeRoomUiScope is required above this widget
```

**SDK dev.15 已发布 API：**

```dart
// controller 来自会议页面 Scope 内的 Builder，而非 State.context。
await showRealtimeRoomUiBottomSheet<void>(
  scopedContext,
  controller: controller,
  builder: (sheetContext) => RealtimeMediaDevicePicker(
    kind: MediaDeviceKind.microphone,
  ),
);

await showRealtimeRoomUiDialog<void>(
  scopedContext,
  controller: controller,
  builder: (dialogContext) => AlertDialog(
    title: const Text('会议设置'),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: const Text('关闭'),
      ),
    ],
  ),
);
```

两个 helper 都将原 Controller **借给** Overlay，不创建新的媒体房间，
也不会负责销毁借入的 Controller。关闭弹窗时优先使用
其 builder 提供的 `sheetContext`/`dialogContext`，
不要用宿主页面 Context 盲目调用 `Navigator.pop()`。
在关闭整个会议前，先关闭依赖房间状态的弹窗，避免重建已释放资源的组件。
尚未升级到新版本时，宿主必须自行在 Overlay 下方显式传入已有 Controller。

## 5. Leave / Close / Dispose 的责任边界

| 操作 | 含义 | 不能替代的操作 |
| --- | --- | --- |
| `controller.close()` | 释放 UI 订阅、UI 状态；借用的 `room` 保持存在 | 离会、结束会议 |
| `controller.leave(closeForEveryone: false)` | 请求本地离会，并释放相应 Room 资源 | 结束所有人会议 |
| `controller.leave(closeForEveryone: true)` | 请求结束整个房间；权限、录制收尾和后端校验均可能失败 | 无权限情况下强行结束 |
| `controller.leave()` | 按房间所有权自动选择：主持人结束全员会话，其他人仅离开自己 | 后端无法关闭房间时不能视为退出成功 |
| `connection.dispose()` | 释放 Connection/Room 等本地资源 | 后端管理操作或结束全员会议 |
| `Navigator.pop()` | 退出视觉页面 | 任何 RTC/IM 资源清理 |

会议和直播统一使用自动退出策略：
`room.media.isLogicalOwner == true` 时，点击离开会尝试关闭整个房间，
使所有参会者/观众退出；其他用户则只退出本人。不再提供退出方式选择。
SDK 内置页面仅保留单次确认：主持人提示“结束会议/直播”，其他人提示“离开”。
普通会议创建者可能持有 owner 凭证但媒体角色仍是 `participant`，
因此不能只靠 `MediaRole.host` 判断主持人身份。最终关房权限以服务端为准。
若客户端或服务端不支持关房，则返回错误并保留当前连接，避免主持人误以为
全员已经退出。第三方自定义应用也应按 `isLogicalOwner` 处理退出。

**远端结束同步（源码实现，需发布新的单包版本）：**
连接成功后的媒体心跳若获得后端的 `room-not-found`，SDK 将停止重复心跳，
向 `room.events` 发出 `RealtimeBackendFailure`，其中
`error.operation == 'room.presence.heartbeat'`。SDK 内置会议与直播页
由此提示房间结束并触发宿主 `onLeft`。宿主如使用组合式/无头页面，需自己
监听并释放连接。高层 `Realtime` 默认媒体心跳间隔为 5 秒；异常网络连接失败
不视为房间结束。该机制是跨厂商的*最终一致*兜底，不保证即时踢出远端
RTC 连接；如需服务端强制断连，必须使用厂商关房能力并在后端实现授权。

退出过程中不要重复点击，也不要让第二个调用者在首次销毁完成之前
提前导航。近期源码已为并发 `leave()` 提供共享 Future，并防止
等待确认时 Widget 已卸载后继续执行。**已经关闭的 UI Controller**
再次收到 `leave()` 时会抛出 `RealtimeErrorCode.invalidState`，
而不是谎报房间已释放；此时应由仍持有 Connection 的宿主决定如何清理。
错误应提供明确的处理路径，而不是视为离会成功。

## 6. 还需通过的回归场景

开发者可对照以下场景测试 SDK 集成：成品会议/直播页面退出；
组合页面确认/取消；手机 Drawer/弹窗；嵌套 Navigator；
离会连续点击与重复释放；录制正在启动/停止时关房；
网络断线、超时与权限不足；页面被系统返回先卸载；
重新进入同房间；不同用户角色与不同 Provider。

**当前验证状态（2026-11-02 SDK 工作树）：**
SDK UI 和 Room UI 静态分析通过；新加的 SDK 嵌入/Scope/退出测试通过；
SDK UI 全量回归现已通过 151 项测试（其中包括修复后的大字体直播工具栏
Host tools 可达性测试）；Room UI 6 项测试通过，相关静态分析通过。
此外，厂商真实设备、多平台发布构建、聚合单包与第三方 pub 依赖应用
仍未在本次修复中完成验收。只能在维护者手动发布新 SDK 后，
用保持不变的第三方 Demo 做发布后回归。
