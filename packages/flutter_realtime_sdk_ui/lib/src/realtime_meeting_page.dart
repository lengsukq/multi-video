import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import '../flutter_realtime_sdk_ui.dart';
import 'prepare_room_page.dart';
import 'recording_action.dart';
import 'meeting_shared_content.dart';

/// Responsive meeting page built from independently reusable SDK components.
///
/// Desktop (>=1000): persistent header, vertical tool rail, stage + stage bar
/// and a trailing 340 pt panel. Phones: header, stage and a floating dock; side
/// panels open as a right-hand drawer.
class RealtimeMeetingPage extends StatefulWidget {
  const RealtimeMeetingPage({
    super.key,
    required this.room,
    this.initialSettings,
    this.imagePresets = const [],
    this.loadImagePresets,
    this.onLeft,
    this.confirmBeforeLeave = true,
    this.header,
    this.showChat = true,
    this.showClassroom = true,
    this.showAnnotations = true,
    this.showProvider = false,
    this.showRtcDataMessages = false,
    this.participantBuilder,
    this.onCustomReaction,
    this.stageOverlayBuilder,
    this.sessionInfo,
    this.brand,
    this.pinnedMessage,
    this.classroomNotesPanel,
    this.initialSharedContentMode,
  });

  final RealtimeRoom room;
  final MediaLocalPreviewSettings? initialSettings;
  final List<MediaBackgroundImagePreset> imagePresets;
  final Future<List<MediaBackgroundImagePreset>> Function()? loadImagePresets;
  final VoidCallback? onLeft;
  final bool confirmBeforeLeave;
  final Widget? header;
  final bool showChat;
  final bool showClassroom;
  final bool showAnnotations;
  final bool showProvider;
  final bool showRtcDataMessages;
  final MediaParticipantBuilder? participantBuilder;
  final Future<void> Function(BuildContext context)? onCustomReaction;
  final WidgetBuilder? stageOverlayBuilder;

  /// Host-provided room identity. Falls back to the backend room code.
  final RealtimeMeetingSessionInfo? sessionInfo;

  /// Product mark shown before the room identity on wide headers.
  final Widget? brand;

  /// Host-provided pinned message for the chat panel.
  final String? pinnedMessage;

  /// Optional host-provided persisted classroom notes view. The SDK never
  /// generates or pretends to save notes without a configured data source.
  final Widget? classroomNotesPanel;

  /// Shared-content mode applied once after the room is ready.
  final SharedContentMode? initialSharedContentMode;

  @override
  State<RealtimeMeetingPage> createState() => _RealtimeMeetingPageState();
}

class _RealtimeMeetingPageState extends State<RealtimeMeetingPage> {
  late Future<void> _videoEffectsReady;
  int _preparationRevision = 0;
  RealtimeMeetingPanel _panel = RealtimeMeetingPanel.closed;
  int _classroomTab = 0;
  int _classroomPanelVisit = 0;
  bool _recordingBusy = false;
  bool _useGrid = false;
  bool _showFilmstrip = true;
  bool _openedInitialPanel = false;
  final _stageKey = GlobalKey();
  final _whiteboardTools = WhiteboardToolsController();
  // The stage already listens to shared-content changes. The surrounding
  // room shell must do so too: the desktop tool rail and stage toolbar mode
  // depend on whiteboard start/stop even when media/room UI state is unchanged.
  Stream<Object?>? _sharedContentUpdates;
  late DateTime _enteredAt;

  @override
  void dispose() {
    _whiteboardTools.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _enteredAt = DateTime.now();
    _videoEffectsReady = _prepare();
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

  Future<void> _prepare() async {
    final revision = ++_preparationRevision;
    final room = widget.room;
    final settings = widget.initialSettings;
    bool isCurrent() =>
        mounted &&
        revision == _preparationRevision &&
        identical(widget.room, room) &&
        identical(widget.initialSettings, settings);
    await prepareRoomPageWithDeadline(
      room,
      settings,
      isCurrent: isCurrent,
      startSharedContent: true,
    );
    if (!mounted || !isCurrent()) return;
    // Cache the stream once per prepared room. Recreating stageUpdates on
    // every build would unnecessarily resubscribe to its broadcast source.
    _sharedContentUpdates = room.sharedContent?.stageUpdates;
    final initialMode = widget.initialSharedContentMode;
    if (initialMode != null && initialMode != SharedContentMode.members) {
      try {
        await room.sharedContent?.selectMode(initialMode);
      } catch (error) {
        room.reportLifecycleFailure(
          normalizeRealtimeException(
            error,
            domain: 'roomPage',
            operation: 'initialSharedContent',
            providerId: room.providerId,
            stackTrace: StackTrace.current,
          ),
        );
      }
    }
  }

  @override
  void didUpdateWidget(covariant RealtimeMeetingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.room, widget.room)) _showFilmstrip = true;
    if (!identical(oldWidget.room, widget.room) ||
        oldWidget.initialSettings != widget.initialSettings) {
      _sharedContentUpdates = null;
      _videoEffectsReady = _prepare();
      _panel = RealtimeMeetingPanel.closed;
      _classroomTab = 0;
      _classroomPanelVisit = 0;
      _useGrid = false;
      _openedInitialPanel = false;
      _enteredAt = DateTime.now();
    }
  }

  Future<bool> _confirmLeave(BuildContext context) async {
    if (!widget.confirmBeforeLeave) return true;
    final strings = RealtimeStrings.of(context);
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => RealtimeGlassDialog(
            title: Text(strings.leaveRoomTitle),
            content: Text(strings.leaveRoomConfirmation),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(strings.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(strings.leave),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _onLeft() {
    if (widget.onLeft != null) {
      widget.onLeft!();
    } else if (Navigator.canPop(context)) {
      Navigator.pop(context);
    }
  }

  Future<void> _openEffects(BuildContext context) async {
    await showRealtimeBackgroundEffectsSheet(
      context,
      loadImagePresets: widget.loadImagePresets,
      imagePresets: widget.imagePresets,
    );
  }

  Future<void> _sendWave(BuildContext context) async {
    try {
      await widget.onCustomReaction?.call(context);
    } catch (error) {
      if (context.mounted) {
        RealtimeRoomUiScope.of(context).reportActionError(error);
      }
    }
  }

  void _openClassroomTools(BuildContext context) {
    final classroom = widget.room.classroom;
    if (classroom == null) return;
    unawaited(
      showRealtimeGlassBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) => SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.75,
          child: ClassroomToolsPanel(
            classroom: classroom,
            showHeader: true,
            onClose: () => Navigator.maybeOf(sheetContext)?.pop(),
          ),
        ),
      ),
    );
  }

  /// Opens the real publish dialog for a classroom tool kind.
  Future<void> _openClassroomTool(BuildContext context, String kind) async {
    final classroom = widget.room.classroom;
    if (classroom == null) return;
    final strings = ClassroomStrings.of(context);
    await showDialog<void>(
      context: context,
      builder: (_) => ClassroomPublishToolDialog(
        kind: ClassroomToolKind.values.firstWhere(
          (value) => value.name == kind,
        ),
        classroom: classroom,
        strings: strings,
        onActionError: (RealtimeException error) =>
            RealtimeRoomUiScope.of(context).reportActionError(error),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _videoEffectsReady,
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
                    _videoEffectsReady = _prepare();
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
            child: SafeArea(
              bottom: false,
              child: LayoutBuilder(
                builder: (context, constraints) => StreamBuilder<Object?>(
                  stream: _sharedContentUpdates,
                  builder: (context, _) => ListenableBuilder(
                    listenable: RealtimeRoomUiScope.of(context),
                    builder: (context, _) {
                      final width = constraints.maxWidth;
                      final wide = RealtimeBreakpoints.isWide(context, width);
                      final compact =
                          width < RealtimeBreakpoints.compactMaxWidth;
                      final controller = RealtimeRoomUiScope.of(context);
                      if (wide &&
                          !_openedInitialPanel &&
                          _panel == RealtimeMeetingPanel.closed) {
                        _openedInitialPanel = true;
                        final initialPanel =
                            widget.showChat && widget.room.chat != null
                            ? RealtimeMeetingPanel.chat
                            : widget.showClassroom &&
                                  widget.room.classroom != null
                            ? RealtimeMeetingPanel.participants
                            : RealtimeMeetingPanel.closed;
                        if (initialPanel != RealtimeMeetingPanel.closed) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted &&
                                _panel == RealtimeMeetingPanel.closed) {
                              setState(() => _panel = initialPanel);
                            }
                          });
                        }
                      }
                      final participants = controller.snapshot.participants;
                      final sharedContent = MeetingSharedContent(
                        room: widget.room,
                        snapshot: controller.snapshot,
                        showClassroom: widget.showClassroom,
                      );
                      final sharing = sharedContent.active;
                      // Classroom rooms use the teaching workspace with the
                      // same persistent navigation for chat, people and tools.
                      final classroomWorkspace =
                          widget.showClassroom && widget.room.classroom != null;
                      // Whiteboard controls join the permanent left navigation
                      // rail rather than replacing it or creating a second one.
                      final whiteboardWorkspace =
                          sharing &&
                          sharedContent.mode == SharedContentMode.whiteboard;
                      final dockShowsLabels =
                          wide && width >= RealtimeBreakpoints.largeMinWidth;

                      final stage = RealtimeMeetingStage(
                        key: _stageKey,
                        // The dock owns its own row below the stage (reference
                        // classroom layout), so the stage does not reserve a
                        // floating overlay area.
                        bottomControlsInset: 0,
                        useGrid: _useGrid,
                        showFilmstrip: _showFilmstrip,
                        showClassroom: widget.showClassroom,
                        showAnnotations: widget.showAnnotations,
                        // The local camera is already in the participant strip
                        // (or the grid). Do not render it a second time as an
                        // overlay in the top-right corner of the stage.
                        showSelfView: false,
                        participantBuilder: widget.participantBuilder,
                        overlayBuilder: widget.stageOverlayBuilder,
                        // Only the desktop rail hosts the board's tools. Phones
                        // and tablets keep the board's own pill strip so the
                        // tools stay reachable without a vertical rail.
                        whiteboardToolsController: wide && whiteboardWorkspace
                            ? _whiteboardTools
                            : null,
                        topOverlayInset: 0,
                      );

                      final dock = Padding(
                        padding: EdgeInsets.fromLTRB(
                          compact ? 8 : 12,
                          0,
                          compact ? 8 : 12,
                          compact ? 8 : 10,
                        ),
                        child: RealtimeMeetingDock(
                          showLabels: dockShowsLabels,
                          // Panels and settings live in the vertical rail on
                          // desktop and the upper horizontal rail on small
                          // viewports, rather than crowding the bottom dock.
                          mediaGroup: [
                            RealtimeDockMicrophoneButton(
                              showLabel: dockShowsLabels,
                            ),
                            RealtimeDockCameraButton(
                              showLabel: dockShowsLabels,
                            ),
                            RealtimeDockSharedContentButton(
                              showLabel: dockShowsLabels,
                            ),
                          ],
                          collaborationGroup: [
                            RealtimeDockReactionsButton(
                              showLabel: false,
                              onWave: widget.onCustomReaction != null
                                  ? () => unawaited(_sendWave(context))
                                  : null,
                            ),
                            if (widget.showClassroom)
                              RealtimeDockRaiseHandButton(showLabel: false),
                          ],
                          // Compact rooms use the horizontal tool rail above the
                          // stage for secondary navigation/settings, not More.
                          panelsGroup: const [],
                          // Leaving stays in the persistent header so the fading
                          // dock never becomes the only exit.
                        ),
                      );

                      final header = _buildHeader(
                        context,
                        controller,
                        wide: wide,
                        compact: compact,
                        participants: participants,
                      );

                      return RealtimeRoomShell(
                        compact: compact,
                        header: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.header != null) widget.header!,
                            header,
                          ],
                        ),
                        // On phones the slim horizontal rail replaces the
                        // crowded dock More sheet; desktop uses the left rail.
                        tabletRail: !wide
                            ? RealtimeMeetingRail(
                                horizontal: true,
                                items: _railItems(
                                  context,
                                  controller,
                                  wide: false,
                                  sharing: sharing,
                                ),
                              )
                            : null,
                        topContent: widget.showRtcDataMessages
                            ? _rtcDataPanel(controller)
                            : null,
                        desktopRail: wide
                            ? RealtimeMeetingRail(
                                items: _railItems(
                                  context,
                                  controller,
                                  wide: wide,
                                  sharing: sharing,
                                ),
                                trailing:
                                    whiteboardWorkspace &&
                                        widget
                                                .room
                                                .sharedContent
                                                ?.whiteboard
                                                .state
                                                ?.canEdit ==
                                            true
                                    ? WhiteboardToolRail(
                                        session: widget
                                            .room
                                            .sharedContent!
                                            .whiteboard,
                                        controller: _whiteboardTools,
                                      )
                                    : null,
                              )
                            : null,
                        stage: stage,
                        dock: dock,
                        sidebar: wide && _panel != RealtimeMeetingPanel.closed
                            ? _sidePanel(
                                context,
                                workspaceMode: classroomWorkspace,
                              )
                            : null,
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _buildHeader(
    BuildContext context,
    RealtimeRoomUiController controller, {
    required bool wide,
    required bool compact,
    required List<MediaParticipant> participants,
  }) {
    final strings = RealtimeStrings.of(context);
    final name = widget.room.media.roomCode;
    final role = RealtimePresentationRole.forMeeting(widget.room.media);
    final classroomMode = widget.showClassroom && widget.room.classroom != null;
    final classroomState = controller.classroomState;
    final roleLabel = classroomState == null
        ? role.label(isZh: strings.isZh)
        : classroomState.isTeacher
        ? (strings.isZh ? '老师' : 'Teacher')
        : (strings.isZh ? '学生' : 'Student');
    final info = widget.sessionInfo;
    final modeLabel =
        (widget.room.media.meetingMode ??
                (widget.room.classroom != null
                    ? MediaMeetingMode.classroom
                    : MediaMeetingMode.standard))
            .label(isZh: strings.isZh);
    final names = participants
        .map((p) => p.displayName.isEmpty ? p.id : p.displayName)
        .toList(growable: false);
    void invite() {
      final messenger = ScaffoldMessenger.maybeOf(context);
      unawaited(
        Clipboard.setData(ClipboardData(text: name)).then((_) {
          messenger?.showSnackBar(
            SnackBar(content: Text(strings.meetingCodeCopied)),
          );
        }),
      );
    }

    return RealtimeMeetingTopBar(
      brand: widget.brand,
      title: info?.title ?? name,
      subtitle: wide
          ? info?.subtitle ??
                '$roleLabel · ${participants.length} ${strings.isZh ? "人在线" : "online"}${widget.showProvider ? " · ${widget.room.providerId}" : ""}'
          : '$modeLabel · $roleLabel',
      compact: !wide,
      dense: wide,
      inviteAction: invite,
      statusWidgets: [
        if (wide)
          RealtimePill(
            label:
                (widget.room.media.meetingMode ??
                        (widget.room.classroom != null
                            ? MediaMeetingMode.classroom
                            : MediaMeetingMode.standard))
                    .label(isZh: strings.isZh),
          ),
        if (!classroomMode)
          Tooltip(
            message: roleLabel,
            child: Icon(
              widget.room.media.isLogicalOwner
                  ? Icons.admin_panel_settings_outlined
                  : Icons.person_outline_rounded,
              size: 16,
              color: RealtimeUiTokens.textMuted,
            ),
          ),
        RealtimeMeetingTimerBadge(startedAt: _enteredAt, live: classroomMode),
        RealtimeRecordingBadge(room: widget.room, compact: true),
        if (wide) const RealtimeConnectionIndicator(),
      ],
      audienceNames: compact ? const [] : names,
      audienceCount: compact ? null : participants.length,
      trailingActions: [
        // The labelled invite button only renders on wide headers, so phones
        // and tablets get an icon-only equivalent instead of a second copy
        // action.
        if (!wide)
          IconButton.outlined(
            tooltip: strings.isZh ? '邀请' : 'Invite',
            style: IconButton.styleFrom(
              foregroundColor: RealtimeStyle.of(context).textSecondary,
              side: BorderSide(color: RealtimeStyle.of(context).border),
              minimumSize: const Size(40, 40),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(
                  RealtimeUiTokens.controlRadius,
                ),
              ),
            ),
            icon: const Icon(Icons.person_add_alt_1_outlined, size: 19),
            onPressed: invite,
          ),
        const SizedBox(width: 4),
        RealtimeLeaveButton(
          iconOnly: compact,
          onConfirm: _confirmLeave,
          onLeft: _onLeft,
        ),
      ],
    );
  }

  List<RealtimeMeetingRailItem> _railItems(
    BuildContext context,
    RealtimeRoomUiController controller, {
    required bool wide,
    required bool sharing,
  }) {
    final strings = RealtimeStrings.of(context);
    final participantCount = controller.snapshot.participants.length;
    final canPublishVideo = controller.snapshot.capabilities.canPublishVideo;
    final canManageRecording =
        widget.room.recording.isConfigured && widget.room.media.isLogicalOwner;
    final classroom = controller.classroomState;
    // The tool rail holds occasional room management and view actions.
    // The dock is intentionally reserved for in-call high-frequency controls.
    return [
      if (widget.showChat && widget.room.chat != null)
        RealtimeMeetingRailItem(
          icon: Icons.chat_bubble_outline_rounded,
          tooltip: strings.chat,
          active: wide && _panel == RealtimeMeetingPanel.chat,
          onPressed: () =>
              _toggle(RealtimeMeetingPanel.chat, controller, isWide: wide),
        ),
      RealtimeMeetingRailItem(
        icon: Icons.people_outline_rounded,
        tooltip: strings.participants,
        active: wide && _panel == RealtimeMeetingPanel.participants,
        onPressed: () => _toggle(
          RealtimeMeetingPanel.participants,
          controller,
          isWide: wide,
        ),
      ),
      if (widget.showClassroom && widget.room.classroom != null)
        RealtimeMeetingRailItem(
          icon: Icons.school_outlined,
          tooltip: strings.classroom,
          active: wide && _panel == RealtimeMeetingPanel.classroom,
          onPressed: () =>
              _toggle(RealtimeMeetingPanel.classroom, controller, isWide: wide),
        ),
      if (widget.showClassroom && classroom?.capabilities.canGrantSpeak == true)
        RealtimeMeetingRailItem(
          icon: Icons.pan_tool_alt_outlined,
          tooltip: strings.isZh ? '举手队列' : 'Hand requests',
          badgeCount: classroom!.raisedHands.length,
          onPressed: () => _openClassroomHands(controller, isWide: wide),
        ),
      // Camera layout is one toggle in the rail instead of a tab bar above the
      // stage: the icon shows the view a tap switches to.
      if (!sharing) ...[
        const RealtimeMeetingRailItem.divider(),
        RealtimeMeetingRailItem(
          icon: _useGrid ? Icons.view_agenda_outlined : Icons.grid_view_rounded,
          tooltip: _useGrid ? strings.speakerMode : strings.gridMode,
          onPressed: () => setState(() => _useGrid = !_useGrid),
        ),
        if (!_useGrid && participantCount > 1)
          RealtimeMeetingRailItem(
            icon: _showFilmstrip
                ? Icons.view_carousel_outlined
                : Icons.view_carousel_rounded,
            tooltip: strings.isZh
                ? (_showFilmstrip ? '隐藏缩略图' : '显示缩略图')
                : (_showFilmstrip ? 'Hide thumbnails' : 'Show thumbnails'),
            active: _showFilmstrip,
            onPressed: () => setState(() => _showFilmstrip = !_showFilmstrip),
          ),
      ] else ...[
        const RealtimeMeetingRailItem.divider(),
        RealtimeMeetingRailItem(
          icon: _showFilmstrip
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined,
          tooltip: strings.isZh
              ? (_showFilmstrip ? '隐藏缩略图' : '显示缩略图')
              : (_showFilmstrip ? 'Hide thumbnails' : 'Show thumbnails'),
          onPressed: () => setState(() => _showFilmstrip = !_showFilmstrip),
        ),
      ],
      const RealtimeMeetingRailItem.divider(),
      if (canPublishVideo) ...[
        RealtimeMeetingRailItem(
          icon: Icons.blur_on_outlined,
          tooltip: strings.virtualBackground,
          active: widget.room.backgroundEffect.enabled,
          onPressed: () => unawaited(_openEffects(context)),
        ),
        RealtimeMeetingRailItem(
          icon: Icons.cameraswitch_rounded,
          tooltip: strings.flipCamera,
          onPressed: () => unawaited(controller.switchCamera()),
        ),
      ],
      if (canManageRecording)
        RealtimeMeetingRailItem(
          icon: Icons.fiber_manual_record_rounded,
          tooltip: strings.isZh ? '录制控制' : 'Recording controls',
          active: widget.room.recordingStatus == RecordingStatus.recording,
          onPressed: _recordingBusy
              ? null
              : () => unawaited(_handleRecording(context)),
        ),
      if (widget.room.recording.isConfigured)
        RealtimeMeetingRailItem(
          icon: Icons.cloud_download_outlined,
          tooltip: strings.isZh ? '录制结果' : 'Recording results',
          onPressed: () => _showCloudResultDialog(context),
        ),
      if (widget.showClassroom &&
          classroom?.capabilities.canUseTools == true) ...[
        const RealtimeMeetingRailItem.divider(),
        RealtimeMeetingRailItem(
          icon: Icons.build_outlined,
          tooltip: strings.classroomTools,
          onPressed: () => _openClassroomTools(context),
        ),
        if (classroom?.capabilities.canPublishTools == true) ...[
          RealtimeMeetingRailItem(
            icon: Icons.poll_outlined,
            tooltip: strings.isZh ? '投票' : 'Poll',
            onPressed: () => _openClassroomTool(context, 'poll'),
          ),
          RealtimeMeetingRailItem(
            icon: Icons.timer_outlined,
            tooltip: strings.isZh ? '计时' : 'Timer',
            onPressed: () => _openClassroomTool(context, 'timer'),
          ),
        ],
      ],
    ];
  }

  void _toggle(
    RealtimeMeetingPanel panel,
    RealtimeRoomUiController controller, {
    required bool isWide,
  }) {
    if (!isWide) {
      _openDrawer(panel, controller);
      return;
    }
    setState(() {
      if (panel == RealtimeMeetingPanel.classroom) {
        _classroomTab = 0;
        _classroomPanelVisit++;
      }
      _panel = _panel == panel ? RealtimeMeetingPanel.closed : panel;
    });
  }

  void _openClassroomHands(
    RealtimeRoomUiController controller, {
    required bool isWide,
  }) {
    if (!isWide) {
      _openDrawer(RealtimeMeetingPanel.classroom, controller, classroomTab: 1);
      return;
    }
    setState(() {
      _classroomTab = 1;
      // Reopen on the queue even when the panel already shows another tab.
      _classroomPanelVisit++;
      _panel = RealtimeMeetingPanel.classroom;
    });
  }

  void _openDrawer(
    RealtimeMeetingPanel panel,
    RealtimeRoomUiController controller, {
    int classroomTab = 0,
  }) {
    final strings = RealtimeStrings.of(context);
    unawaited(
      showRealtimeRoomDrawer<void>(
        context,
        title: switch (panel) {
          RealtimeMeetingPanel.chat => strings.chat,
          RealtimeMeetingPanel.classroom => strings.classroom,
          _ => strings.participants,
        },
        icon: switch (panel) {
          RealtimeMeetingPanel.chat => Icons.chat_bubble_outline_rounded,
          RealtimeMeetingPanel.classroom => Icons.school_outlined,
          _ => Icons.people_outline_rounded,
        },
        child: RealtimeRoomUiScope(
          room: widget.room,
          controller: controller,
          child: switch (panel) {
            RealtimeMeetingPanel.chat => const RealtimeChatPanel(),
            RealtimeMeetingPanel.classroom => RealtimeClassroomPanel(
              showHeader: false,
              initialTab: classroomTab,
              onClose: () =>
                  Navigator.maybeOf(context, rootNavigator: true)?.pop(),
            ),
            _ => const RealtimeManagedParticipantList(),
          },
        ),
      ),
    );
  }

  // The State's context lives ABOVE RealtimeRoomUiScope. Keep the controller
  // captured from the descendant builder instead of looking up an ancestor
  // that cannot exist on the State's element.
  Widget _rtcDataPanel(RealtimeRoomUiController controller) => RoomRtcDataPanel(
    session: widget.room.media.session,
    onError: (message) {
      if (message != null) {
        controller.reportActionError(
          RealtimeException(
            code: RealtimeErrorCode.unknown,
            message: 'room.data.send',
          ),
        );
      }
    },
  );

  Widget _sidePanel(BuildContext scopedContext, {bool workspaceMode = false}) =>
      RealtimeMeetingSidePanel(
        panel: _panel,
        classroomTab: _classroomTab,
        classroomPanelVisit: _classroomPanelVisit,
        workspaceMode: workspaceMode,
        pinnedMessage: widget.pinnedMessage,
        notesPanel: widget.classroomNotesPanel,
        recordingPanel:
            workspaceMode &&
                widget.room.recording.isConfigured &&
                widget.room.media.isLogicalOwner
            ? RealtimeRecordingPanel(
                room: widget.room,
                busy: _recordingBusy,
                onToggleRecording: () =>
                    unawaited(_handleRecording(scopedContext)),
                onOpenResult: () => _showCloudResultDialog(scopedContext),
              )
            : null,
        onClose: () => setState(() => _panel = RealtimeMeetingPanel.closed),
      );

  Future<void> _handleRecording(BuildContext context) async {
    if (_recordingBusy || !mounted) return;
    final room = widget.room;
    setState(() => _recordingBusy = true);
    try {
      await toggleRoomRecording(
        context,
        room,
        isCurrent: () => mounted && identical(room, widget.room),
      );
    } catch (error) {
      if (mounted && context.mounted && identical(room, widget.room)) {
        RealtimeRoomUiScope.of(context).reportActionError(error);
      }
    } finally {
      if (mounted) setState(() => _recordingBusy = false);
    }
  }

  void _showCloudResultDialog(BuildContext context) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => RealtimeRecordingResultDialog(room: widget.room),
      ),
    );
  }
}
