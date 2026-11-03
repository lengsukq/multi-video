import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

/// Lightweight localization surface for the built-in SDK UI.
///
/// The SDK does not own a global locale. It follows the host application's
/// locale and can be wired into [MaterialApp] through [localizationsDelegates]
/// Scope widget allowing host applications or Demo to override SDK UI strings.
class RealtimeStringsScope extends InheritedWidget {
  const RealtimeStringsScope({
    super.key,
    required this.strings,
    required super.child,
  });

  final RealtimeStrings strings;

  @override
  bool updateShouldNotify(RealtimeStringsScope oldWidget) =>
      strings != oldWidget.strings;
}

/// Lightweight localization surface for the built-in SDK UI.
///
/// By default, the SDK presents standard English UI copy and does not impose
/// a global localization bundle. Host applications or Demo can wire in custom
/// strings using [RealtimeStringsScope] or standard [localizationsDelegates].
class RealtimeStrings {
  const RealtimeStrings([this.locale = const Locale('en')]);

  const RealtimeStrings.en() : this(const Locale('en'));
  const RealtimeStrings.zh() : this(const Locale('zh', 'CN'));

  final Locale locale;

  bool get isZh => locale.languageCode.toLowerCase() == 'zh';

  static const supportedLocales = <Locale>[Locale('en'), Locale('zh', 'CN')];

  static const localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];

  static const delegate = _RealtimeStringsDelegate();

  static RealtimeStrings of(BuildContext context) {
    final scoped = context
        .dependOnInheritedWidgetOfExactType<RealtimeStringsScope>();
    if (scoped != null) return scoped.strings;
    return Localizations.of<RealtimeStrings>(context, RealtimeStrings) ??
        RealtimeStrings(Localizations.localeOf(context));
  }

  String get back => isZh ? '返回' : 'Back';
  String get conversation => isZh ? '聊天消息' : 'Conversation';
  String get preJoinTitle => isZh ? '入会前准备' : 'Ready to join';
  String get cameraPreview => isZh ? '画面预览' : 'Video preview';
  String get viewerPreviewHelp => isZh
      ? '作为观众，无需开启摄像头和麦克风'
      : 'As a viewer, no camera or microphone is needed';
  String get previewDisabledHelp => isZh
      ? '摄像头默认关闭，可在设备设置中开启预览'
      : 'Camera is off by default. Enable it in audio & video settings';
  String get cloudRecording => isZh ? '云录制' : 'Cloud recording';
  String get stopCloudRecording => isZh ? '停止云录制' : 'Stop cloud recording';
  String get viewRecordingResult => isZh ? '查看录制结果' : 'View recording result';
  String get cloudRecordingUnsupported => isZh
      ? '当前供应商未配置云录制执行器'
      : 'Cloud recording requires a supported provider and configured backend';

  String displayRealtimeError(Object error) {
    if (error is! RealtimeException) {
      return isZh ? '操作失败，请重试。' : 'The action failed. Please retry.';
    }
    if (error.suggestedAction == 'reload-web-runtime') {
      return isZh
          ? '网页资源版本不一致。请完整重启应用或刷新页面后重试。'
          : 'Web resources are incompatible. Restart the app or reload the page and retry.';
    }
    // A failed shared-content commit may wrap the original HTTP failure.
    // Do not show internal identifiers or mislabel an expired room as an
    // arbitrary invalidState. Inspect only the bounded exception chain.
    final failures = <RealtimeException>[];
    Object? current = error;
    for (var depth = 0; depth < 6 && current is RealtimeException; depth++) {
      if (failures.any((item) => identical(item, current))) break;
      failures.add(current);
      current = current.cause;
    }
    final isSharedContentFailure = failures.any(
      (item) =>
          item.message.startsWith('sharedContent.') ||
          item.domain == 'sharedContent' ||
          item.operation == 'commitAfterCaptureStop',
    );
    if (isSharedContentFailure) {
      if (failures.any(
        (item) =>
            item.code == RealtimeErrorCode.roomNotFound ||
            item.statusCode == 404,
      )) {
        return isZh
            ? '会议已失效或已结束，请退出并重新创建或加入会议。'
            : 'This room has expired or ended. Leave and create or join a room again.';
      }
      if (failures.any(
        (item) =>
            item.code == RealtimeErrorCode.forbidden ||
            item.code == RealtimeErrorCode.unauthorized ||
            item.statusCode == 401 ||
            item.statusCode == 403,
      )) {
        return isZh
            ? '没有切换白板或共享内容的权限，请检查主持人身份。'
            : 'You do not have permission to change the whiteboard or shared content.';
      }
      if (failures.any(
        (item) =>
            item.code == RealtimeErrorCode.roomConflict ||
            item.statusCode == 409,
      )) {
        return isZh
            ? '共享内容状态已被其他操作更新，请重试。'
            : 'Shared content changed during this action. Please retry.';
      }
      if (failures.any(
        (item) =>
            item.code == RealtimeErrorCode.network ||
            item.code == RealtimeErrorCode.timeout,
      )) {
        return isZh
            ? '无法同步白板状态，请检查后端连接后重试。'
            : 'Could not sync the whiteboard. Check the backend connection and retry.';
      }
      return isZh
          ? '切换白板或共享内容失败，请重试；如持续出现请检查后端日志。'
          : 'Unable to change shared content. Retry or check the backend logs.';
    }
    return switch (error.code) {
      RealtimeErrorCode.network =>
        isZh
            ? '无法连接音视频服务。请检查网络或代理设置后重试。'
            : 'Cannot connect to the media service. Check your network or proxy settings and retry.',
      RealtimeErrorCode.timeout =>
        isZh
            ? '连接或准备房间超时。请检查网络后重试。'
            : 'Connecting or preparing the room timed out. Check your network and retry.',
      _ => [
        error.message,
        if (error.suggestedAction == 'retry') isZh ? '请重试。' : 'Please retry.',
      ].join('\n'),
    };
  }

  String get chat => isZh ? '聊天' : 'Chat';
  String get standaloneChat => isZh ? '独立聊天' : 'Standalone Chat';
  String get independentProductChat =>
      isZh ? '独立产品聊天' : 'Independent product chat';
  String get independentProductChatDescription => isZh
      ? '聊天可以独立于 Meeting / Live 使用，也会在与音视频组合时复用同一套 ChatSession UI。'
      : 'Chat works independently from Meeting / Live and uses the same ChatSession UI when embedded with media.';
  String get roomCode => isZh ? '房间码' : 'Room code';
  String roomLabel(String code) => isZh ? '房间 $code' : 'Room $code';
  String get displayName => isZh ? '显示名称' : 'Display name';
  String get createChatRoom => isZh ? '创建聊天室' : 'Create chat room';
  String get joinChatRoom => isZh ? '加入聊天室' : 'Join chat room';
  String get chatUser => isZh ? '聊天用户' : 'Chat user';
  String get enterChatRoomCode =>
      isZh ? '请输入聊天室房间码。' : 'Enter a chat room code.';

  String get manageRoom => isZh ? '管理房间' : 'Manage room';
  String get roomManagement => isZh ? '房间管理' : 'Room management';
  String roomManagementSubtitle(String provider, String role) =>
      isZh ? '服务商：$provider · 角色：$role' : 'Provider: $provider · Role: $role';
  String get participant => isZh ? '参与者' : 'Participant';
  String get removeParticipant => isZh ? '移除参与者' : 'Remove participant';
  String get roomMembers => isZh ? '房间成员' : 'Room members';
  String get you => isZh ? '你' : 'You';
  String get mediaOnline => isZh ? '音视频在线' : 'Media online';
  String get chatOnline => isZh ? 'Chat 在线' : 'Chat online';
  String get removeFromMedia => isZh ? '移出音视频' : 'Remove from media';
  String get removeFromChat => isZh ? '移出 Chat' : 'Remove from Chat';
  String get muteParticipant => isZh ? '静音' : 'Mute';
  String get stopParticipantVideo => isZh ? '关闭视频' : 'Stop video';
  String get unsupported => isZh ? '不支持' : 'Unsupported';
  String get noManagedMembers =>
      isZh ? '当前没有可管理的成员。' : 'No manageable members are currently present.';
  String get chatManagementUnavailable => isZh
      ? '当前 Chat Provider 不支持此管理操作。'
      : 'The current Chat provider does not support this management action.';
  String get closeRoomForEveryone =>
      isZh ? '为所有人关闭房间' : 'Close room for everyone';
  String get closeRoom => isZh ? '关闭房间' : 'Close room';

  String get leaveRoomTitle => isZh ? '离开房间？' : 'Leave room?';
  String get leaveRoomConfirmation =>
      isZh ? '确定要断开连接并离开吗？' : 'Are you sure you want to disconnect?';
  String get cancel => isZh ? '取消' : 'Cancel';
  String get close => isZh ? '关闭' : 'Close';
  String get leave => isZh ? '离开' : 'Leave';
  String get continueLabel => isZh ? '继续' : 'Continue';
  String get runAgain => isZh ? '重新检查' : 'Run again';
  String get refresh => isZh ? '刷新' : 'Refresh';
  String get microphone => isZh ? '麦克风' : 'Microphone';
  String get camera => isZh ? '摄像头' : 'Camera';
  String get virtualBackground => isZh ? '虚拟背景' : 'Virtual background';
  String get noVirtualBackground => isZh ? '无' : 'None';
  String get backgroundBlur => isZh ? '背景虚化' : 'Background blur';
  String get backgroundImage => isZh ? '背景图片' : 'Background image';
  String get blurStrength => isZh ? '模糊强度' : 'Blur strength';
  String get invalidBackgroundImage =>
      isZh ? '无法读取背景图片' : 'Unable to read the background image';
  String backgroundBlurStrength(MediaBackgroundBlurStrength strength) =>
      switch (strength) {
        MediaBackgroundBlurStrength.low => isZh ? '低' : 'Low',
        MediaBackgroundBlurStrength.medium => isZh ? '中' : 'Medium',
        MediaBackgroundBlurStrength.high => isZh ? '高' : 'High',
      };
  String get backgroundBlurPreviewDescription => isZh
      ? '立即应用到本地预览画面。'
      : 'Apply the effect to the local preview immediately.';
  String get backgroundBlurJoinDescription => isZh
      ? '当前服务商不支持独立特效预览；效果会在摄像头画面发布前应用。'
      : 'This provider cannot preview the effect independently; it will be applied before the camera is published.';
  String get speaker => isZh ? '扬声器' : 'Speaker';
  String get deviceSetup => isZh ? '设备设置' : 'Device setup';
  String get cameraPreviewUnavailable => isZh
      ? '当前服务商不支持本地摄像头预览'
      : 'Local camera preview is not supported by this provider';
  String get previewStartFailed => isZh
      ? '无法启动预览，仍可继续加入。'
      : 'Preview could not start. You can still continue.';
  String get deviceListUnavailable =>
      isZh ? '设备列表暂不可用' : 'Device list is unavailable';
  String get noDevicesFound =>
      isZh ? '没有检测到可用的音视频设备' : 'No audio or video devices were found';
  String get deviceSelectionUnsupported => isZh
      ? '当前服务商不支持选择设备，可继续入会。'
      : 'Device selection is not supported by this provider. You can continue.';
  String get joinMeeting => isZh ? '加入会议' : 'Join meeting';
  String get enterLiveRoom => isZh ? '进入直播间' : 'Enter live room';
  String get enteringRoom => isZh ? '正在进入房间…' : 'Entering room…';
  String get enteringRoomDetail => isZh
      ? '正在建立连接，成功后会直接进入房间。'
      : 'Connecting now. You will enter the room automatically.';
  String get connecting => isZh ? '连接中' : 'Connecting';
  String get joining => isZh ? '正在加入' : 'Joining';
  String get leaving => isZh ? '正在离开' : 'Leaving';
  String get idleLabel => isZh ? '未开始' : 'Idle';
  String get disposedLabel => isZh ? '已结束' : 'Ended';
  String get reconnecting => isZh ? '正在重新连接' : 'Reconnecting';
  String get reconnectingDetail => isZh
      ? '正在尝试恢复音视频连接，请稍候。'
      : 'Trying to restore audio and video. Please wait.';
  String get connectionFailed => isZh ? '连接失败' : 'Connection failed';
  String get ended => isZh ? '房间已结束' : 'Room ended';
  String mediaConnectionState(MediaSessionState state) => switch (state) {
    MediaSessionState.idle => idleLabel,
    MediaSessionState.joining => joining,
    MediaSessionState.connecting => connecting,
    MediaSessionState.connected => connected,
    MediaSessionState.reconnecting => reconnecting,
    MediaSessionState.leaving => leaving,
    MediaSessionState.ended => ended,
    MediaSessionState.failed => connectionFailed,
    MediaSessionState.disposed => disposedLabel,
  };
  String get participants => isZh ? '成员' : 'Participants';
  String get switchCamera => isZh ? '切换摄像头' : 'Switch camera';
  String get speakerView => isZh ? '发言人' : 'Speaker';
  String get connected => isZh ? '已连接' : 'Connected';
  String get leaveLiveRoom => isZh ? '离开直播间' : 'Leave live room';
  String get endLiveRoom => isZh ? '结束直播' : 'End live';
  String get closeLiveRoomConfirmation => isZh
      ? '结束直播会关闭房间并断开所有观众。'
      : 'Ending the live stream closes the room and disconnects all viewers.';

  String get onlyOneHere => isZh ? '现在只有你一个人' : "You're the only one here";
  String get shareRoomCode =>
      isZh ? '分享房间码即可邀请其他人加入' : 'Share the room code to start streaming';
  String get copied => isZh ? '已复制' : 'Copied';
  String copyRoom(String code) => isZh ? '复制 $code' : 'Copy $code';
  String get youSuffix => isZh ? '（你）' : ' (you)';

  String get closeChat => isZh ? '关闭聊天' : 'Close chat';
  String get noMessagesYet => isZh ? '还没有消息' : 'No messages yet';
  String messageCount(int count) => isZh ? '$count 条消息' : '$count messages';
  String get startConversation => isZh ? '开始聊天吧' : 'Start the conversation';
  String get messageHint => isZh ? '输入消息…' : 'Message…';
  String get readOnly => isZh ? '只读' : 'Read only';
  String chatState(String state) => isZh ? '聊天状态：$state' : 'Chat is $state';
  String chatConnectionState(String state) {
    if (!isZh) return state;
    return switch (state) {
      'disconnected' => '已断开',
      'connecting' => '连接中',
      'connected' => '已连接',
      'reconnecting' => '重连中',
      'failed' => '连接失败',
      'disposed' => '已结束',
      _ => state,
    };
  }

  String roleLabel(String role) {
    if (!isZh) return role;
    return switch (role) {
      'host' => '房主',
      'viewer' => '观众',
      'participant' => '参与者',
      _ => role,
    };
  }

  String get manageChat => isZh ? '管理聊天' : 'Manage chat';
  String get messageActions => isZh ? '消息操作' : 'Message actions';
  String get capabilityDependentActions => isZh
      ? '可用操作取决于当前服务商能力。'
      : 'Available actions depend on provider capabilities.';
  String get deleteMessage => isZh ? '删除消息' : 'Delete message';
  String removeUser(String name) => isZh ? '移除 $name' : 'Remove $name';
  String get chatManagement => isZh ? '聊天管理' : 'Chat management';
  String get hostOnlyActions =>
      isZh ? '仅房主可使用的管理操作' : 'Host-only control plane actions';
  String get closeChatRoom => isZh ? '关闭聊天室' : 'Close chat room';

  String get rtcData => 'RTC Data';
  String get debugDataPayload => isZh ? '调试数据内容…' : 'Debug data payload…';
  String get screenShare => isZh ? '屏幕共享' : 'Screen Share';
  String get expandStage => isZh ? '放大聚焦' : 'Expand stage';
  String get compactStage => isZh ? '紧凑模式' : 'Compact view';
  String get focusParticipant => isZh ? '置顶聚焦' : 'Spotlight';
  String get gridView => isZh ? '网格视图' : 'Grid view';
  String get randomCode => isZh ? '随机' : 'Random';
  String get paste => isZh ? '粘贴' : 'Paste';
  String get clear => isZh ? '清空' : 'Clear';

  String get preJoinCheck => isZh ? '加入前检查' : 'Pre-Join Check';
  String get runningPreJoinChecks =>
      isZh ? '正在检测设备、权限与网络连通性…' : 'Checking devices, permissions & network…';
  String get unableToRunPreJoin =>
      isZh ? '无法执行加入前检查。' : 'Unable to run the pre-join check.';
  String get readyToContinue => isZh ? '可以继续' : 'Ready to continue';
  String get resolveBlockingIssues =>
      isZh ? '请先处理阻止加入的问题' : 'Resolve blocking issues before joining';
  String get backend => isZh ? '后端' : 'Backend';
  String backendProviderLabel(String provider) =>
      isZh ? '后端服务商：$provider' : 'Backend provider: $provider';
  String get provider => isZh ? '服务商' : 'Provider';
  String get microphonePermission => isZh ? '麦克风权限' : 'Microphone permission';
  String get cameraPermission => isZh ? '摄像头权限' : 'Camera permission';
  String get requestPermission => isZh ? '获取权限' : 'Grant access';
  String get requiredLabel => isZh ? '必需' : 'Required';
  String permissionStateLabel(MediaPermissionState state) => switch (state) {
    MediaPermissionState.granted => isZh ? '已授权' : 'Allowed',
    MediaPermissionState.denied => isZh ? '未授权' : 'Not allowed',
    MediaPermissionState.permanentlyDenied => isZh ? '已阻止' : 'Blocked',
    MediaPermissionState.restricted => isZh ? '受限制' : 'Restricted',
    MediaPermissionState.unsupported => isZh ? '无法检测' : 'Cannot check',
    _ => isZh ? '待检测' : 'Not checked',
  };

  /// SDK checks contain provider-authored diagnostic strings. Display
  /// localized user-facing summaries instead of mixing raw English diagnostics
  /// into an otherwise Chinese Pre-Join page.
  String preJoinCheckDescription(MediaPreJoinCheck check) {
    final name = switch (check.type) {
      MediaPreJoinCheckType.backend => isZh ? '后端连接' : 'Backend connection',
      MediaPreJoinCheckType.provider => isZh ? '服务商适配' : 'Provider support',
      MediaPreJoinCheckType.microphonePermission => microphonePermission,
      MediaPreJoinCheckType.cameraPermission => cameraPermission,
      MediaPreJoinCheckType.microphoneDevice => microphoneDevice,
      MediaPreJoinCheckType.cameraDevice => cameraDevice,
      MediaPreJoinCheckType.network => isZh ? '网络连通性' : 'Network connectivity',
      MediaPreJoinCheckType.providerNetwork =>
        isZh ? '服务商网络探测' : 'Provider network probe',
    };
    final state = switch (check.status) {
      MediaPreJoinStatus.passed => isZh ? '正常' : 'Ready',
      MediaPreJoinStatus.failed => isZh ? '检测失败' : 'Check failed',
      MediaPreJoinStatus.unsupported =>
        isZh
            ? '此平台无法提前验证，不代表设备不可用'
            : 'Cannot pre-check on this platform; device may still work',
      MediaPreJoinStatus.unknown =>
        isZh ? '暂无法确认，仍可尝试加入' : 'Not confirmed yet; you can still try joining',
    };
    return '$name · $state';
  }

  String get openAppSettings => isZh ? '前往系统设置' : 'Open app settings';
  String get browserPermissionSettings => isZh ? '查看浏览器设置' : 'Browser settings';
  String get permissionHelpTitle =>
      isZh ? '请在浏览器中允许权限' : 'Allow access in your browser';
  String get permissionSettingsUnavailable => isZh
      ? '无法打开系统设置，请手动为应用开启权限。'
      : 'Could not open system settings. Enable this permission for the app manually.';
  String get permissionRequestFailed =>
      isZh ? '权限请求失败，请稍后重试。' : 'Permission request failed. Try again.';
  String permissionGranted(String label) =>
      isZh ? '已获得$label权限。' : '$label permission is granted.';
  String permissionDenied(String label) => isZh
      ? '尚未获得$label权限，可以点击获取权限。'
      : '$label permission is not granted. Tap to request access.';
  String permissionPermanentlyDenied(String label) => isZh
      ? '$label权限已被拒绝，请前往系统设置开启。'
      : '$label permission is blocked. Open app settings to enable it.';
  String permissionRestricted(String label) => isZh
      ? '$label权限受到系统限制。'
      : '$label permission is restricted by the system.';
  String permissionBrowserHelp(String label) => isZh
      ? '浏览器已阻止$label。请打开地址栏旁的网站权限设置并允许访问，然后返回此页重新检查。'
      : 'Your browser blocked $label. Allow it in the site permissions menu near the address bar, then return and run the check again.';
  String get microphoneDevice => isZh ? '麦克风设备' : 'Microphone device';
  String get cameraDevice => isZh ? '摄像头设备' : 'Camera device';
  String get network => isZh ? '网络' : 'Network';
  String get providerNetwork => isZh ? '服务商网络' : 'Provider network';
  String preJoinStatus(String status) {
    if (!isZh) return status.toUpperCase();
    return switch (status) {
      'passed' => '通过',
      'failed' => '失败',
      'unsupported' => '不支持',
      'unknown' => '未知',
      _ => status,
    };
  }

  String get english => 'English';
  String get chinese => '中文';
  String get language => isZh ? '语言' : 'Language';

  String get meeting => isZh ? '会议' : 'Meeting';
  String get live => isZh ? '直播' : 'Live';
  String get meetingModeSubtitle =>
      isZh ? '参与者共同发布音视频' : 'Co-publish audio & video';
  String get liveModeSubtitle => isZh ? '主播与观众' : 'Host stage + viewers';
  String get meetingModeDescription => isZh
      ? '所有人以参与者身份加入，并可控制发布音视频。'
      : 'Everyone joins as a participant with publish controls.';
  String get liveModeDescription => isZh
      ? '创建者为主播，其他设备以观众身份加入。'
      : 'The creator is the host; other devices join as viewers.';
  String roomSummary(String mode, String provider, int attendees) => isZh
      ? '$mode · $provider · $attendees 人在线'
      : '$mode · $provider · $attendees online';
  String roomCardSummary(String mode, int attendees) =>
      isZh ? '$mode · $attendees 人在线' : '$mode · $attendees online';
  String get join => isZh ? '加入' : 'Join';

  // --- Extended Chat Strings ---
  String get scrollToBottom => isZh ? '回到底部' : 'Scroll to bottom';
  String get newMessages => isZh ? '新消息' : 'New messages';
  String get quickReactions => isZh ? '快捷表情' : 'Quick reactions';
  String get messageCopied => isZh ? '已复制消息' : 'Message copied';
  String get removeMember => isZh ? '移出成员' : 'Remove member';
  String get copyText => isZh ? '复制文字' : 'Copy text';

  // --- Extended Live Stream Strings ---
  String get liveStream => isZh ? '互动直播' : 'Livestream';
  String get showFullVideo => isZh ? '完整显示' : 'Show full video';
  String get fillLiveScreen => isZh ? '适应屏幕' : 'Fill screen';
  String get liveAudience => isZh ? '人正在看' : 'watching';
  String get watchLive => isZh ? '观看直播' : 'Watch live';
  String get startLive => isZh ? '开始直播' : 'Start live';
  String get cleanScreen => isZh ? '清屏模式' : 'Clean screen';
  String get exitCleanScreen => isZh ? '退出清屏' : 'Exit clean screen';
  String get sendDanmaku => isZh ? '发弹幕' : 'Send';
  String get danmakuHint => isZh ? '聊两句，发个弹幕吧…' : 'Say something in chat…';
  String get applyCoHost => isZh ? '申请连麦' : 'Request co-host';
  String get coHostApplied => isZh ? '连麦申请已发出' : 'Co-host request sent';
  String get coHostRequests => isZh ? '连麦申请' : 'Co-host requests';
  String get approveCoHost => isZh ? '同意连麦' : 'Approve';
  String get rejectCoHost => isZh ? '拒绝' : 'Decline';
  String get endLive => isZh ? '结束直播' : 'End livestream';
  String get endLiveConfirmation => isZh
      ? '确定要结束当前直播吗？所有观众将被断开。'
      : 'End this livestream? All viewers will be disconnected.';
  String get liveSummary => isZh ? '直播小结' : 'Livestream Summary';
  String get liveDuration => isZh ? '直播时长' : 'Live duration';
  String get peakViewers => isZh ? '最高在线' : 'Peak viewers';
  String get totalLikes => isZh ? '直播间点赞' : 'Room likes';
  String get myLikes => isZh ? '我的点赞次数' : 'My likes';
  String get noMuteTargets => isZh ? '暂无可静音成员' : 'No participants to mute';
  String get retryFailed => isZh ? '重试失败成员' : 'Retry failed participants';
  String muteSummary(int success, int failed) =>
      isZh ? '静音成功 $success 人，失败 $failed 人' : 'Muted $success; failed $failed';

  // --- Extended Meeting Strings ---
  String get gridMode => isZh ? '宫格视图' : 'Grid view';
  String get speakerMode => isZh ? '演讲者视图' : 'Speaker view';
  String get presentationMode => isZh ? '演示视图' : 'Presentation view';
  String get layoutMode => isZh ? '切换布局' : 'Layout mode';
  String get raiseHand => isZh ? '举手' : 'Raise hand';
  String get lowerHand => isZh ? '手放下' : 'Lower hand';
  String get handRaised => isZh ? '已举手' : 'Hand raised';
  String get muteAll => isZh ? '全员静音' : 'Mute all';
  String get muteAllConfirmation => isZh
      ? '确定要将除自己外的所有人静音吗？'
      : 'Mute everyone in the meeting except yourself?';
  String get muteAllSuccess => isZh ? '已将所有成员静音' : 'All participants muted';
  String get hostBadge => isZh ? '主持人' : 'Host';
  String get moderatorBadge => isZh ? '管理员' : 'Admin';
  String get grantHost => isZh ? '设为主持人' : 'Grant Host';
  String get endMeetingForAll => isZh ? '全员结束会议' : 'End meeting for all';
  String get endMeetingForAllDesc => isZh
      ? '关闭当前会议房间，所有参会者将被断开。'
      : 'Close the meeting room for everyone; all participants will be disconnected.';
  String get leaveMeetingOnly => isZh ? '仅自己离开' : 'Leave meeting only';
  String get leaveMeetingOnlyDesc => isZh
      ? '会议将继续进行，其他参会者不受影响。'
      : 'The meeting will continue running for other participants.';

  // --- Meeting & Live & Chat Enhancements ---
  String get meetingTimer => isZh ? '会议时长' : 'Duration';
  String get encryptedMeeting => isZh ? '安全加密' : 'Encrypted';
  String get copyMeetingCode => isZh ? '复制会议号' : 'Copy meeting ID';
  String get meetingCodeCopied => isZh ? '会议号已复制' : 'Meeting ID copied';
  String get leaveMeeting => isZh ? '离开会议' : 'Leave meeting';
  String get unmute => isZh ? '解除静音' : 'Unmute';
  String get startVideo => isZh ? '开启视频' : 'Start video';
  String get stopVideo => isZh ? '停止视频' : 'Stop video';
  String get more => isZh ? '更多' : 'More';
  String get speaking => isZh ? '正在发言' : 'Speaking';
  String get meTag => isZh ? '我' : 'Me';
  String get searchMembers => isZh ? '搜索参会者' : 'Search participants';

  String get liveRoom => isZh ? '直播间' : 'Live Room';
  String get liveStatus => isZh ? '直播中' : 'LIVE';
  String viewingCount(int n) => isZh ? '$n 在看' : '$n viewing';
  String get sendComment => isZh ? '说点什么…' : 'Say something…';
  String get sendGift => isZh ? '送礼物' : 'Gift';
  String userJoined(String name) =>
      isZh ? '欢迎 $name 进入直播间' : 'Welcome $name to the stream';
  String get endBroadcast => isZh ? '结束直播' : 'End live';
  String get endBroadcastConfirmation =>
      isZh ? '确定要结束本场直播吗？' : 'Are you sure you want to end this live stream?';
  String get anchorTag => isZh ? '主播' : 'Host';
  String get waitingForHost =>
      isZh ? '等待主播开播…' : 'Waiting for host to broadcast…';
  String get cameraOff => isZh ? '摄像头已关闭' : 'Camera is off';
  String get mute => isZh ? '静音' : 'Mute';

  String get quoteReply => isZh ? '引用回复' : 'Reply';
  String replyTo(String name) => isZh ? '回复 @$name' : 'Reply to @$name';
  String get cancelReply => isZh ? '取消回复' : 'Cancel reply';
  String get copyMessage => isZh ? '复制' : 'Copy';
  String get searchMessages => isZh ? '搜索消息' : 'Search messages';
  String get searchMessagesHint => isZh ? '输入关键词搜索聊天记录…' : 'Search messages…';
  String get noMessagesFound => isZh ? '未找到相关消息' : 'No messages found';
  String get quickReplies => isZh ? '快捷短语' : 'Quick replies';
  String get exploreChatRooms => isZh ? '探索房间' : 'Explore';
  String get quickCreateRoom => isZh ? '快捷建房' : 'Create';
  String get joinByCode => isZh ? '号码加入' : 'Join by code';
  String get delivered => isZh ? '已发送' : 'Sent';

  // --- Dock & Classroom & PreJoin Additions ---
  String get flipCamera => isZh ? '翻转' : 'Flip';
  String get backgroundEffects => isZh ? '背景' : 'Effects';
  String get micOn => isZh ? '麦克风' : 'Mic on';
  String get muted => isZh ? '已静音' : 'Muted';
  String get camOn => isZh ? '摄像头' : 'Cam on';
  String get camOff => isZh ? '已关视频' : 'Cam off';
  String get shareContent => isZh ? '共享内容' : 'Share content';
  String get chooseContentToShare =>
      isZh ? '选择共享内容' : 'Choose content to share';
  String get whiteboard => isZh ? '白板演示' : 'Whiteboard';
  String get whiteboardDescription =>
      isZh ? '打开多人协同互动白板与课件' : 'Open collaborative interactive whiteboard';
  String get shareScreenDescription =>
      isZh ? '共享电脑或手机屏幕给所有参会者' : 'Share your display with all participants';
  String get stopSharing => isZh ? '停止共享' : 'Stop share';
  String get activeSharing => isZh ? '共享中' : 'Sharing';
  String get classroom => isZh ? '课堂管理' : 'Classroom';
  String get classroomActivities => isZh ? '测验' : 'Activities';
  String get classroomQuestions => isZh ? '提问' : 'Questions';
  String get classroomHands => isZh ? '举手' : 'Hands';
  String get classroomRoster => isZh ? '花名册' : 'Roster';
  String get noActivitiesYet => isZh ? '暂无活动' : 'No activities yet';
  String get activitiesUnavailable =>
      isZh ? '活动功能暂不可用' : 'Activities unavailable';
  String get closePanel => isZh ? '关闭面板' : 'Close panel';
  String get systemReady => isZh ? '系统已就绪，可随时加入' : 'All systems ready';
  String get checkAttention => isZh ? '部分检测需要关注' : 'Some checks need attention';
  String get diagnosticDetails => isZh ? '设备与网络检测详情' : 'Diagnostic details';
  String get audioAndVideo => isZh ? '音视频设备' : 'Audio & Video';
  String get deviceSettingsHint =>
      isZh ? '进入房间前，可自由开启麦克风与摄像头' : 'Configure audio and video before entering';
  String get awaitPermissionToSpeak =>
      isZh ? '请先举手，等待允许发言' : 'Raise hand and await permission to speak';
  String get giftFeatureEnabled => isZh ? '送礼物功能已开启' : 'Gift feature enabled';
  String get closeCommentInput => isZh ? '收起评论输入' : 'Close comment input';
  String get shareScreen => screenShare;
  String get classroomFeedback => isZh ? '课堂互动反馈' : 'Classroom feedback';
  String get reactions => isZh ? '互动' : 'Reactions';
  String get wave => isZh ? '挥手' : 'Wave';
  String get classroomTools => isZh ? '课堂工具' : 'Classroom tools';
  String get classroomToolsDescription =>
      isZh ? '课堂工具（公告、作业、倒计时）' : 'Classroom tools (notices, homework, timer)';
  List<String> get quickReplyPhrases => isZh
      ? const ['收到 👍', '好的，明白', '赞同 💯', '稍等一下', '感谢分享!']
      : const [
          'Received 👍',
          'Got it, thanks',
          'Agreed 💯',
          'One moment',
          'Thanks for sharing!',
        ];

  // Classroom sub-features
  String get submit => isZh ? '提交' : 'Submit';
  String get noRaisedHands => isZh ? '暂无举手学生' : 'No raised hands';
  String get noRaisedHandsDesc =>
      isZh ? '学生举手申请发言将在此实时显示' : 'Student requests to speak will appear here';
  String get speakingPermitted => isZh ? '允许发言中' : 'Speaking permitted';
  String get handRaisedStatus => isZh ? '申请发言中' : 'Hand raised';
  String get allow => isZh ? '允许' : 'Allow';
  String get allowSpeaking => isZh ? '允许发言' : 'Allow speaking';
  String get revoke => isZh ? '收回' : 'Revoke';
  String get revokeSpeaking => isZh ? '收回发言' : 'Revoke speaking';
  String get rosterUnavailable => isZh ? '花名册暂不可用' : 'Roster unavailable';
  String get canSpeak => isZh ? '可发言' : 'Can speak';
  String get listening => isZh ? '听课中' : 'Listening';
  String get noQuestionsYet => isZh ? '暂无课堂提问' : 'No questions yet';
  String get noQuestionsDesc =>
      isZh ? '输入问题后点击发送，向老师请教' : 'Type a question below to ask the teacher';
  String get noQuestionsDescTeacher => isZh
      ? '学生提问后将在此展示，可直接在此解答'
      : 'Questions submitted by students will appear here';
  String get askQuestionHint => isZh ? '向老师提问…' : 'Ask a question';
  String get askQuestionTooltip => isZh ? '向老师提问' : 'Ask question';
  String get manageQuestion => isZh ? '管理提问' : 'Manage question';
  String get answer => isZh ? '回答' : 'Answer';
  String get answerQuestion => isZh ? '回答提问' : 'Answer question';
  String get resolve => isZh ? '标记已处理' : 'Resolve';
  String get teacherAnswerBadge => isZh ? '老师解答' : 'Teacher';
  String get questionPending => isZh ? '待解答' : 'Pending';
  String get questionAnswered => isZh ? '已回答' : 'Answered';
  String get questionResolved => isZh ? '已完结' : 'Resolved';
  String activityResponses(int count) =>
      isZh ? '$count 人参与' : '$count responses';
  String get activityClosed => isZh ? '已结束' : 'Closed';
  String get closeActivity => isZh ? '结束活动' : 'Close';

  // Meeting Chat additions
  String get meetingChatEmptyTitle => isZh ? '暂无会议消息' : 'No messages yet';
  String get meetingChatEmptyDesc =>
      isZh ? '发送消息与参会者实时沟通' : 'Send a message to chat with participants';
  String get sendMessage => isZh ? '发送消息' : 'Send message';
  String get replyMessage => isZh ? '回复消息' : 'Reply';
}

class _RealtimeStringsDelegate extends LocalizationsDelegate<RealtimeStrings> {
  const _RealtimeStringsDelegate();

  @override
  bool isSupported(Locale locale) =>
      locale.languageCode == 'en' || locale.languageCode == 'zh';

  @override
  Future<RealtimeStrings> load(Locale locale) =>
      SynchronousFuture<RealtimeStrings>(RealtimeStrings(locale));

  @override
  bool shouldReload(_RealtimeStringsDelegate old) => false;
}
