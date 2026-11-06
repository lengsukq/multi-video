import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import '../flutter_realtime_sdk_ui.dart';
import 'prepare_room_page.dart';

/// Responsive broadcast page shared by the Demo and SDK integrations.
class RealtimeLivePage extends StatefulWidget {
  const RealtimeLivePage({
    super.key,
    required this.room,
    this.initialSettings,
    this.imagePresets = const [],
    this.loadImagePresets,
    this.onLeft,
    this.confirmBeforeLeave = true,
    this.header,
    this.showChat = true,
    this.showLiveInteractions = true,
    this.showProvider = false,
  });

  final RealtimeRoom room;
  final MediaLocalPreviewSettings? initialSettings;
  final List<MediaBackgroundImagePreset> imagePresets;
  final Future<List<MediaBackgroundImagePreset>> Function()? loadImagePresets;
  final VoidCallback? onLeft;
  final bool confirmBeforeLeave;
  final Widget? header;
  final bool showChat;
  final bool showLiveInteractions;
  final bool showProvider;

  @override
  State<RealtimeLivePage> createState() => _RealtimeLivePageState();
}

enum _LiveSidePanel { none, chat, members }

class _RealtimeLivePageState extends State<RealtimeLivePage> {
  late Future<void> _preparing;
  StreamSubscription<RealtimeEvent>? _roomEndSubscription;
  bool _remoteEndHandled = false;
  int _preparationRevision = 0;
  late Future<List<MediaBackgroundImagePreset>> _presets;
  _LiveSidePanel _sidePanel = _LiveSidePanel.none;
  bool _cleanScreen = false;
  BoxFit? _liveVideoFitOverride;
  late DateTime _enteredAt;

  @override
  void initState() {
    super.initState();
    _watchRoomEnd();
    _enteredAt = DateTime.now();
    _preparing = _prepare();
    _presets =
        widget.loadImagePresets?.call() ?? Future.value(widget.imagePresets);
  }

  void _watchRoomEnd() {
    final room = widget.room;
    _remoteEndHandled = false;
    _roomEndSubscription = room.events.listen((event) {
      if (event is! RealtimeBackendFailure ||
          event.error.code != RealtimeErrorCode.roomNotFound ||
          event.error.operation != 'room.presence.heartbeat' ||
          !mounted ||
          _remoteEndHandled) {
        return;
      }
      _remoteEndHandled = true;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            RealtimeStrings.of(context).isZh
                ? '主播已结束直播'
                : 'The host ended the livestream.',
          ),
        ),
      );
      if (widget.onLeft != null) {
        widget.onLeft!();
      } else {
        if (Navigator.canPop(context)) Navigator.pop(context);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(room.dispose());
        });
      }
    });
  }

  @override
  void dispose() {
    unawaited(_roomEndSubscription?.cancel());
    super.dispose();
  }

  void _showActionError(RealtimeException error) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(RealtimeStrings.of(context).displayRealtimeError(error)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant RealtimeLivePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.room, widget.room)) {
      unawaited(_roomEndSubscription?.cancel());
      _watchRoomEnd();
    }
    if (!identical(oldWidget.room, widget.room) ||
        oldWidget.initialSettings != widget.initialSettings) {
      _enteredAt = DateTime.now();
      _preparing = _prepare();
      _presets =
          widget.loadImagePresets?.call() ?? Future.value(widget.imagePresets);
      _sidePanel = _LiveSidePanel.none;
    }
  }

  Future<void> _prepare() async {
    final revision = ++_preparationRevision;
    final room = widget.room;
    final settings = widget.initialSettings;
    bool isCurrent() =>
        mounted &&
        revision == _preparationRevision &&
        identical(widget.room, room) &&
        identical(widget.initialSettings, settings);
    await prepareRoomPageWithDeadline(room, settings, isCurrent: isCurrent);
  }

  Future<bool> _confirmLeave(BuildContext context) async {
    if (!widget.confirmBeforeLeave) return true;
    final strings = RealtimeStrings.of(context);
    final host = widget.room.media.isLogicalOwner;
    final recordingMayBeActive = {
      RecordingStatus.starting,
      RecordingStatus.recording,
      RecordingStatus.stopping,
      RecordingStatus.unknown,
    }.contains(widget.room.recordingStatus);
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => RealtimeGlassDialog(
            title: Text(host ? strings.endLive : strings.leaveRoomTitle),
            content: Text(
              host
                  ? recordingMayBeActive
                        ? '${strings.endLiveConfirmation}\n\n${strings.isZh ? "当前云录制仍在进行或状态未确认。结束直播前会尝试停止录制；如需下载，请先停止录制并保存 MP4。" : "Cloud recording may still be running. Ending the live will first attempt to stop it. To keep the MP4, stop and download before leaving."}'
                        : strings.endLiveConfirmation
                  : strings.leaveRoomConfirmation,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(strings.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(host ? strings.endLive : strings.leave),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _openMobileSheet(
    _LiveSidePanel panel,
    RealtimeRoomUiController controller,
  ) {
    final strings = RealtimeStrings.of(context);
    unawaited(
      showRealtimeRoomDrawer<void>(
        context,
        title: panel == _LiveSidePanel.chat
            ? strings.chat
            : strings.participants,
        icon: panel == _LiveSidePanel.chat
            ? Icons.chat_bubble_rounded
            : Icons.people_alt_rounded,
        child: RealtimeRoomUiScope(
          room: widget.room,
          controller: controller,
          child: panel == _LiveSidePanel.chat
              ? const RealtimeChatPanel()
              : const RealtimeManagedParticipantList(),
        ),
      ),
    );
  }

  void _openHostToolsSheet(BuildContext context) {
    unawaited(
      showRealtimeHostToolsBottomSheet(
        context,
        room: widget.room,
        imagePresetsFuture: _presets,
        extraTools: [RealtimeRecordingButton(room: widget.room)],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _preparing,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (snapshot.hasError) {
        return Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  RealtimeStrings.of(
                    context,
                  ).displayRealtimeError(snapshot.error!),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _preparing = _prepare();
                  }),
                  child: Text(RealtimeStrings.of(context).runAgain),
                ),
              ],
            ),
          ),
        );
      }
      return RealtimeRoomUiScope(
        room: widget.room,
        onActionError: _showActionError,
        child: Scaffold(
          backgroundColor: RealtimeUiTokens.background,
          body: RealtimeAmbientBackground(
            child: Stack(
              fit: StackFit.expand,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = RealtimeBreakpoints.isWide(
                      context,
                      constraints.maxWidth,
                    );
                    final isHost = RealtimePresentationRole.forLive(
                      widget.room.media.role,
                    ).canShowLiveHostTools;
                    final strings = RealtimeStrings.of(context);
                    final isDark =
                        Theme.of(context).brightness == Brightness.dark;

                    if (_cleanScreen) {
                      return GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () => setState(() => _cleanScreen = false),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            RealtimeLiveVideoStage(fit: _liveVideoFitOverride),
                            if (widget.showLiveInteractions &&
                                widget.room.liveInteractions != null)
                              Positioned(
                                left: 16,
                                right: 16,
                                bottom: 24,
                                child: IgnorePointer(
                                  child: LiveGiftBanner(
                                    session: widget.room.liveInteractions!,
                                  ),
                                ),
                              ),
                            Positioned(
                              top: 16,
                              right: 16,
                              child: SafeArea(
                                child: RealtimePill(
                                  label: strings.exitCleanScreen,
                                  icon: Icons.fullscreen_exit_rounded,
                                  foreground: isDark
                                      ? Colors.white
                                      : RealtimeUiTokens.text,
                                  background: isDark
                                      ? Colors.black.withValues(alpha: 0.65)
                                      : Colors.white.withValues(alpha: 0.85),
                                  borderColor: isDark
                                      ? Colors.white.withValues(alpha: 0.35)
                                      : RealtimeUiTokens.border,
                                  onTap: () =>
                                      setState(() => _cleanScreen = false),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    return RealtimeLiveDesktopStage(
                      showChat: widget.showChat,
                      showLiveInteractions: widget.showLiveInteractions,
                      videoFit: _liveVideoFitOverride,
                      startedAt: _enteredAt,
                      initialTab: _sidePanel == _LiveSidePanel.members ? 1 : 0,
                      onSelectedTab: (index) => setState(
                        () => _sidePanel = index == 1
                            ? _LiveSidePanel.members
                            : _LiveSidePanel.chat,
                      ),
                      onOpenChat: () => _openMobileSheet(
                        _LiveSidePanel.chat,
                        RealtimeRoomUiScope.of(context),
                      ),
                      onViewAudience: wide
                          ? () => setState(
                              () => _sidePanel = _LiveSidePanel.members,
                            )
                          : () => _openMobileSheet(
                              _LiveSidePanel.members,
                              RealtimeRoomUiScope.of(context),
                            ),
                      onToggleVideoFit: () => setState(
                        () => _liveVideoFitOverride =
                            _liveVideoFitOverride == BoxFit.contain
                            ? BoxFit.cover
                            : BoxFit.contain,
                      ),
                      exitAction: RealtimeLeaveButton(
                        iconOnly: !wide,
                        onConfirm: (ctx) => _confirmLeave(ctx),
                        onLeft: () {
                          if (widget.onLeft != null) {
                            widget.onLeft!();
                          } else if (context.mounted &&
                              Navigator.canPop(context)) {
                            Navigator.pop(context);
                          }
                        },
                      ),
                      onToggleCleanScreen: () =>
                          setState(() => _cleanScreen = true),
                      onOpenHostTools: isHost
                          ? () => _openHostToolsSheet(context)
                          : null,
                      topTrailingActions: [
                        if (widget.header != null) widget.header!,
                        if (widget.showProvider && wide)
                          Text(widget.room.providerId),
                      ],
                    );
                  },
                ),
                Positioned(
                  top: 90,
                  left: 12,
                  right: 12,
                  child: SafeArea(
                    child: RealtimeRoomEventOverlay(
                      room: widget.room,
                      showClassroom: false,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
