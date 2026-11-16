import 'package:flutter_realtime_room_ui/flutter_realtime_room_ui.dart'
    show RealtimeRoomUiAction;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'room_ui_controller.dart';
import 'room_control_components.dart';
import 'realtime_host_tools_panel.dart';
import 'realtime_role_presentation.dart';
import 'realtime_desktop_screen_share_picker.dart';

class RoomLiveComponentsRealtimeHostToolsPanelState
    extends State<RealtimeHostToolsPanel> {
  List<MediaBackgroundImagePreset> _presets = const [];
  Object? _error;

  @override
  void initState() {
    super.initState();
    _presets = widget.imagePresets;
    if (widget.imagePresetsFuture != null) {
      unawaited(
        widget.imagePresetsFuture!
            .then((presets) {
              if (mounted) setState(() => _presets = presets);
            })
            .catchError((Object err) {
              if (mounted) setState(() => _error = err);
            }),
      );
    }
  }

  @override
  void didUpdateWidget(covariant RealtimeHostToolsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.imagePresetsFuture != oldWidget.imagePresetsFuture &&
        widget.imagePresetsFuture != null) {
      unawaited(
        widget.imagePresetsFuture!
            .then((presets) {
              if (mounted) setState(() => _presets = presets);
            })
            .catchError((Object err) {
              if (mounted) setState(() => _error = err);
            }),
      );
    } else if (widget.imagePresets != oldWidget.imagePresets) {
      setState(() => _presets = widget.imagePresets);
    }
  }

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    required RealtimeStyle style,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 14, color: style.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: style.textMuted,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _effectDescription(
    MediaBackgroundEffect effect,
    RealtimeStrings strings,
  ) {
    final isZh = strings.isZh;
    return switch (effect.type) {
      MediaBackgroundEffectType.none => isZh ? '未开启特效' : 'None',
      MediaBackgroundEffectType.blur => isZh ? '已开启背景虚化' : 'Blur active',
      MediaBackgroundEffectType.replaceImage =>
        isZh ? '已应用自定义背景' : 'Custom image',
    };
  }

  @override
  Widget build(BuildContext context) {
    final controller = RealtimeRoomUiScope.of(context);
    final strings = RealtimeStrings.of(context);
    final isZh = strings.isZh;
    final style = RealtimeStyle.of(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final snapshot = controller.snapshot;
        final isHost = RealtimePresentationRole.forLive(
          controller.room.media.role,
        ).canShowLiveHostTools;

        // A direct caller may mount this panel independently from the Demo.
        // Do not render broadcaster tools for viewer/participant credentials.
        if (!isHost) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              isZh ? '仅主播可以管理直播工具' : 'Broadcaster tools are host-only',
              style: TextStyle(color: style.textMuted),
            ),
          );
        }

        return Column(
          children: [
            if (widget.showHeader) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 12, 8),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: style.primarySubtle,
                        borderRadius: BorderRadius.circular(
                          RealtimeUiTokens.compactRadius,
                        ),
                        border: Border.all(color: style.primaryBorder),
                      ),
                      child: Icon(
                        Icons.tune_rounded,
                        color: style.text,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          Text(
                            isZh ? '主播工具' : 'Host Tools',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: style.text,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(width: 8),
                          RealtimePill(
                            label: isZh ? '主播控制台' : 'Broadcaster',
                            foreground: isHost ? style.text : style.textMuted,
                            background: isHost
                                ? style.primarySubtle
                                : style.surfaceSubtle,
                            borderColor: isHost
                                ? style.primaryBorder
                                : style.border,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      color: style.textMuted,
                      splashRadius: 18,
                      onPressed:
                          widget.onClose ??
                          () => Navigator.maybeOf(context)?.pop(),
                    ),
                  ],
                ),
              ),
              Divider(color: style.border, height: 1),
            ],
            if (controller.isPending(RealtimeRoomUiAction.backgroundEffect) ||
                controller.isPending(RealtimeRoomUiAction.screenShare) ||
                controller.isPending(RealtimeRoomUiAction.switchCamera) ||
                controller.isPending(RealtimeRoomUiAction.audioOutput))
              LinearProgressIndicator(
                minHeight: 2,
                color: style.text,
                backgroundColor: style.primarySubtle,
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  if (_error != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: style.dangerSubtle,
                        borderRadius: BorderRadius.circular(
                          RealtimeUiTokens.compactRadius,
                        ),
                        border: Border.all(
                          color: style.danger.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline_rounded,
                            size: 18,
                            color: style.danger,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '$_error',
                              style: TextStyle(
                                color: style.danger,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Section 1: Video & Camera
                  _buildSectionHeader(
                    icon: Icons.videocam_outlined,
                    title: isZh ? '画面与镜头' : 'Video & Camera',
                    style: style,
                  ),

                  // 1.1 Camera switch
                  RealtimeCard(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    radius: RealtimeUiTokens.cardRadius,
                    child: _HostToolRow(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: RealtimeUiTokens.iosBlue.withValues(
                              alpha: 0.12,
                            ),
                            borderRadius: BorderRadius.circular(
                              RealtimeUiTokens.compactRadius,
                            ),
                            border: Border.all(
                              color: RealtimeUiTokens.iosBlue.withValues(
                                alpha: 0.25,
                              ),
                            ),
                          ),
                          child: const Icon(
                            Icons.cameraswitch_outlined,
                            size: 19,
                            color: RealtimeUiTokens.text,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isZh ? '翻转摄像头' : 'Switch Camera',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: style.text,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                isZh
                                    ? '切换前置与后置镜头拍摄视角'
                                    : 'Toggle between front and rear cameras',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: style.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: style.text,
                            side: BorderSide(color: style.primaryBorder),
                            backgroundColor: style.primarySubtle,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                RealtimeUiTokens.compactRadius,
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.sync_rounded, size: 16),
                          label: Text(
                            isZh ? '翻转' : 'Switch',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          onPressed:
                              controller.canSwitchCamera &&
                                  !controller.isPending(
                                    RealtimeRoomUiAction.switchCamera,
                                  )
                              ? () async {
                                  try {
                                    await controller.switchCamera();
                                  } catch (err) {
                                    if (mounted) {
                                      setState(() => _error = err);
                                    }
                                  }
                                }
                              : null,
                        ),
                      ],
                    ),
                  ),

                  // 1.2 Screen share
                  RealtimeCard(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    radius: RealtimeUiTokens.cardRadius,
                    child: _HostToolRow(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: RealtimeUiTokens.iosTeal.withValues(
                              alpha: 0.12,
                            ),
                            borderRadius: BorderRadius.circular(
                              RealtimeUiTokens.compactRadius,
                            ),
                            border: Border.all(
                              color: RealtimeUiTokens.iosTeal.withValues(
                                alpha: 0.25,
                              ),
                            ),
                          ),
                          child: Icon(
                            snapshot.localScreenShareEnabled
                                ? Icons.stop_screen_share_rounded
                                : Icons.screen_share_outlined,
                            size: 19,
                            color: RealtimeUiTokens.iosTeal,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  Text(
                                    isZh ? '屏幕共享' : 'Screen Share',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: style.text,
                                    ),
                                  ),
                                  if (snapshot.localScreenShareEnabled) ...[
                                    const SizedBox(width: 6),
                                    RealtimePill(
                                      label: isZh ? '共享中' : 'Sharing',
                                      foreground: RealtimeUiTokens.speakStrong,
                                      background: RealtimeUiTokens.iosGreen
                                          .withValues(alpha: 0.12),
                                      borderColor: RealtimeUiTokens.iosGreen
                                          .withValues(alpha: 0.25),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                snapshot.localScreenShareEnabled
                                    ? (isZh
                                          ? '正在向全场观众共享屏幕内容'
                                          : 'Streaming screen to audience')
                                    : (isZh
                                          ? '将当前屏幕画面推流给观众'
                                          : 'Share your screen with viewers'),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: style.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: snapshot.localScreenShareEnabled
                                ? style.danger
                                : style.text,
                            side: BorderSide(
                              color: snapshot.localScreenShareEnabled
                                  ? style.danger.withValues(alpha: 0.35)
                                  : style.primaryBorder,
                            ),
                            backgroundColor: snapshot.localScreenShareEnabled
                                ? style.dangerSubtle
                                : style.primarySubtle,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                RealtimeUiTokens.compactRadius,
                              ),
                            ),
                          ),
                          icon: Icon(
                            snapshot.localScreenShareEnabled
                                ? Icons.stop_circle_outlined
                                : Icons.play_arrow_rounded,
                            size: 16,
                          ),
                          label: Text(
                            snapshot.localScreenShareEnabled
                                ? (isZh ? '停止' : 'Stop')
                                : (isZh ? '开启' : 'Start'),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          onPressed:
                              controller.canShareScreen &&
                                  !controller.isPending(
                                    RealtimeRoomUiAction.screenShare,
                                  )
                              ? () async {
                                  try {
                                    await toggleScreenShareWithPicker(
                                      context,
                                      controller,
                                    );
                                  } catch (err) {
                                    if (mounted) {
                                      setState(() => _error = err);
                                    }
                                  }
                                }
                              : null,
                        ),
                      ],
                    ),
                  ),

                  // 1.3 Virtual Background Effects
                  if (controller.snapshot.capabilities.canPublishVideo &&
                      !controller.room.backgroundCapabilities.isSupported)
                    RealtimeCard(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.all(14),
                      radius: RealtimeUiTokens.cardRadius,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.blur_off_outlined),
                        title: Text(strings.virtualBackground),
                        subtitle: Text(
                          isZh
                              ? '当前设备、平台或供应商暂不支持，或未配置视频特效服务。'
                              : 'Unavailable for this device, platform or provider, or video effects are not configured.',
                        ),
                        enabled: false,
                      ),
                    ),
                  if (controller.room.backgroundCapabilities.isSupported)
                    RealtimeCard(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.all(14),
                      radius: RealtimeUiTokens.cardRadius,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: RealtimeUiTokens.iosIndigo.withValues(
                                    alpha: 0.12,
                                  ),
                                  borderRadius: BorderRadius.circular(
                                    RealtimeUiTokens.compactRadius,
                                  ),
                                  border: Border.all(
                                    color: RealtimeUiTokens.iosIndigo
                                        .withValues(alpha: 0.25),
                                  ),
                                ),
                                child: const Icon(
                                  Icons.blur_on_rounded,
                                  size: 19,
                                  color: RealtimeUiTokens.text,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      strings.virtualBackground,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        color: style.text,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _effectDescription(
                                        controller.room.backgroundEffect,
                                        strings,
                                      ),
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: style.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          BackgroundEffectSelector(
                            capabilities:
                                controller.room.backgroundCapabilities,
                            effect: controller.room.backgroundEffect,
                            imagePresets: _presets,
                            busy: controller.isPending(
                              RealtimeRoomUiAction.backgroundEffect,
                            ),
                            onChanged: (effect) async {
                              try {
                                await controller.setBackgroundEffect(effect);
                              } catch (err) {
                                if (mounted) setState(() => _error = err);
                              }
                            },
                          ),
                        ],
                      ),
                    ),

                  const SizedBox(height: 4),

                  // Section 2: Audio & Output
                  _buildSectionHeader(
                    icon: Icons.volume_up_outlined,
                    title: isZh ? '音频与设备' : 'Audio & Devices',
                    style: style,
                  ),

                  // 2.1 Audio Output
                  if (controller.canListAudioOutputs)
                    RealtimeCard(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      radius: RealtimeUiTokens.cardRadius,
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: RealtimeUiTokens.iosOrange.withValues(
                                alpha: 0.12,
                              ),
                              borderRadius: BorderRadius.circular(
                                RealtimeUiTokens.compactRadius,
                              ),
                              border: Border.all(
                                color: RealtimeUiTokens.iosOrange.withValues(
                                  alpha: 0.25,
                                ),
                              ),
                            ),
                            child: const Icon(
                              Icons.speaker_outlined,
                              size: 19,
                              color: RealtimeUiTokens.iosOrange,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isZh ? '音频输出' : 'Audio Output',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: style.text,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  isZh
                                      ? '选择扬声器、听筒或蓝牙设备'
                                      : 'Select speaker, earphone or bluetooth',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: style.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          const RealtimeAudioOutputButton(),
                        ],
                      ),
                    ),

                  // 2.2 Microphone devices
                  if (controller.canListMediaDevices(
                    MediaDeviceKind.microphone,
                  ))
                    RealtimeCard(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      radius: RealtimeUiTokens.cardRadius,
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: RealtimeUiTokens.iosTeal.withValues(
                                alpha: 0.12,
                              ),
                              borderRadius: BorderRadius.circular(
                                RealtimeUiTokens.compactRadius,
                              ),
                              border: Border.all(
                                color: RealtimeUiTokens.iosTeal.withValues(
                                  alpha: 0.25,
                                ),
                              ),
                            ),
                            child: const Icon(
                              Icons.mic_none_rounded,
                              size: 19,
                              color: RealtimeUiTokens.iosTeal,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isZh ? '麦克风设备' : 'Microphone Device',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: style.text,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  isZh
                                      ? '切换不同的拾音麦克风设备'
                                      : 'Select microphone input device',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: style.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          const RealtimeMediaDevicePicker(
                            kind: MediaDeviceKind.microphone,
                          ),
                        ],
                      ),
                    ),

                  // Section 3: Extensions / Recording
                  if (widget.extraTools.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _buildSectionHeader(
                      icon: Icons.extension_outlined,
                      title: isZh ? '扩展功能' : 'Extensions',
                      style: style,
                    ),
                    RealtimeCard(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      radius: RealtimeUiTokens.cardRadius,
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: widget.extraTools,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Helper method to open the unified live host tools bottom sheet.
Future<void> showRealtimeHostToolsBottomSheet(
  BuildContext context, {
  RealtimeRoom? room,
  List<MediaBackgroundImagePreset> imagePresets = const [],
  Future<List<MediaBackgroundImagePreset>>? imagePresetsFuture,
  List<Widget> extraTools = const [],
}) {
  final targetRoom = room ?? RealtimeRoomUiScope.maybeOf(context)?.room;
  return showRealtimeGlassBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      final content = RealtimeHostToolsPanel(
        showHeader: true,
        imagePresets: imagePresets,
        imagePresetsFuture: imagePresetsFuture,
        extraTools: extraTools,
        onClose: () => Navigator.maybeOf(sheetContext)?.pop(),
      );
      return Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.76,
            child: targetRoom != null
                ? RealtimeRoomUiScope(room: targetRoom, child: content)
                : content,
          ),
        ),
      );
    },
  );
}

// Keep labels and actions reachable when a tool cannot fit on one line.
class _HostToolRow extends StatelessWidget {
  const _HostToolRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final stack =
          constraints.maxWidth < 430 ||
          MediaQuery.textScalerOf(context).scale(1) > 1.3;
      if (!stack) return Row(children: children);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final child in children)
            if (child is Expanded)
              child.child
            else if (child is SizedBox)
              const SizedBox(height: 8)
            else
              Align(alignment: Alignment.centerLeft, child: child),
        ],
      );
    },
  );
}
