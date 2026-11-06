import 'demo_server_settings_panel.dart';
import 'demo_identity_settings_panel.dart';
import 'demo_join_coordinator.dart';
import 'demo_realtime_configuration.dart';
import 'demo_meeting_room_page.dart';
import 'demo_classroom_sample.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';

import 'demo_background.dart';
import 'demo_backend_diagnostics.dart';
import 'demo_available_rooms.dart';
import 'demo_room_directory.dart';
import 'demo_home_hero.dart';
import 'demo_identity_store.dart';
import 'demo_strings.dart';
import 'standalone_chat_demo.dart';

const String _configuredBackendUrl = String.fromEnvironment('MEDIA_BACKEND_URL');
String get _defaultBackendUrl {
  if (_configuredBackendUrl.isNotEmpty) return _configuredBackendUrl;
  // The Windows desktop Demo connects to the LAN backend by default.
  // Other platforms retain their existing default and all platforms
  // can still override this using --dart-define=MEDIA_BACKEND_URL=...
  return !kIsWeb && defaultTargetPlatform == TargetPlatform.windows
      ? 'http://10.0.111.99:3000'
      : 'http://192.168.31.2:3000';
}
const String _appToken = String.fromEnvironment('MEDIA_APP_TOKEN');

/// Optional test seam; Demo registers its desired providers explicitly.
typedef DemoRealtimeFactory = Realtime Function(String backendUrl);
typedef DemoRoomPageFactory =
    Widget Function(
      RealtimeConnection connection,
      MediaLocalPreviewSettings settings,
      MediaRoomMode? mode,
    );

/// Adaptive and clean Join Screen directly reusing SDK built-in glass UI.
class JoinScreen extends StatefulWidget {
  const JoinScreen({
    super.key,
    required this.onLocaleChanged,
    this.realtimeFactory,
    this.roomPageFactory,
    this.backgroundPresets,
    this.initialBackendUrl,
    this.permissionRequester,
  });

  final ValueChanged<Locale> onLocaleChanged;
  final DemoRealtimeFactory? realtimeFactory;
  final DemoRoomPageFactory? roomPageFactory;
  final Future<List<MediaBackgroundImagePreset>> Function()? backgroundPresets;
  final String? initialBackendUrl;
  final MediaPermissionRequester? permissionRequester;

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> with TickerProviderStateMixin {
  final _identityStore = DemoIdentityStore();
  final _diagnostics = DemoBackendDiagnostics();
  final _roomDirectory = DemoRoomDirectory();

  late final TabController _demoTabs;
  late final Future<String> _deviceIdFuture;
  final _serverController = TextEditingController();
  final _createCodeController = TextEditingController();
  final _joinCodeController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _avatarUrlController = TextEditingController();

  DemoEntryPhase _entryPhase = DemoEntryPhase.idle;
  bool get _busy => _entryPhase != DemoEntryPhase.idle;
  String? _error;
  DemoJoinFormError? _formError;
  MediaRoomMode _createRoomMode = MediaRoomMode.meeting;
  MediaMeetingMode _createMeetingMode = MediaMeetingMode.standard;
  MediaRoomMode _joinRoomMode = MediaRoomMode.meeting;

  // Backend connection status: null = untested, true = online, false = offline
  bool? get _serverOnline => _diagnostics.online;
  String? get _serverMediaProviderId => _diagnostics.mediaProviderId;
  String? get _serverChatProviderId => _diagnostics.chatProviderId;
  bool get _testingServer => _diagnostics.testing;
  Timer? _serverStatusTimer;
  List<MediaRoomSummary> get _availableRooms => _roomDirectory.rooms;
  String? get _roomListError => _roomDirectory.error;
  late final _entryCoordinator = DemoJoinCoordinator(_identityStore);

  @override
  void initState() {
    super.initState();
    _diagnostics.addListener(_notifyBackendChanged);
    _roomDirectory.addListener(_notifyBackendChanged);
    _demoTabs = TabController(length: 3, vsync: this);
    _deviceIdFuture = _entryCoordinator.deviceId;
    unawaited(_loadDisplayName());
    _serverController.text = widget.initialBackendUrl ?? _defaultBackendUrl;
    unawaited(_testConnection());
    unawaited(_refreshRooms(silent: true));
    _serverStatusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_testConnection(silent: true));
      if (_demoTabs.index == 0 && !_busy) {
        unawaited(_refreshRooms(silent: true));
      }
    });
  }

  Future<void> _joinDiscoveredRoom(MediaRoomSummary room) async {
    _joinCodeController.text = room.roomCode;
    _joinRoomMode = room.roomMode ?? MediaRoomMode.meeting;
    await _joinRoom(
      providerId: room.engineId ?? room.providerId,
      roomMode: room.roomMode,
    );
  }

  Future<void> _refreshRooms({bool silent = false}) => _roomDirectory.refresh(
    url: _server,
    currentUrl: () => _server,
    listRooms: () => _newRealtime().listRooms(),
    displayError: (error) =>
        DemoStrings.of(context).displayRealtimeError(error),
    silent: silent,
  );

  @override
  void dispose() {
    _diagnostics.removeListener(_notifyBackendChanged);
    _diagnostics.dispose();
    _roomDirectory.removeListener(_notifyBackendChanged);
    _roomDirectory.dispose();
    _serverStatusTimer?.cancel();
    _demoTabs.dispose();
    _serverController.dispose();
    _createCodeController.dispose();
    _joinCodeController.dispose();
    _displayNameController.dispose();
    _avatarUrlController.dispose();
    super.dispose();
  }

  String get _server => _serverController.text.trim();
  void _notifyBackendChanged() {
    if (mounted) setState(() {});
  }

  void _showFormError(DemoJoinFormError error) {
    setState(() {
      _formError = error;
      _error = null;
    });
  }

  String? _displayError(BuildContext context) {
    final strings = DemoStrings.of(context);
    return switch (_formError) {
      DemoJoinFormError.backendMissing => strings.enterBackendUrl,
      DemoJoinFormError.roomCodeMissing => strings.enterRoomCode,
      DemoJoinFormError.invalidRoomCode => strings.invalidRoomCode,
      null => _error,
    };
  }

  Future<void> _loadDisplayName() async {
    final id = await _deviceIdFuture;
    final name = await _identityStore.loadDisplayName(id);
    final avatarUrl = await _identityStore.loadAvatarUrl();
    if (!mounted) return;
    _displayNameController.text = name;
    _avatarUrlController.text = avatarUrl;
    setState(() {});
  }

  Future<void> _persistDisplayName(String value) =>
      _identityStore.saveDisplayName(value);

  Future<void> _testConnection({bool silent = false}) => _diagnostics.refresh(
    url: _server,
    currentUrl: () => _server,
    diagnose: () => _newRealtime().diagnoseBackend(),
    silent: silent,
  );

  void _generateRandomCreateCode() {
    final code = '${100000 + (DateTime.now().millisecondsSinceEpoch % 900000)}';
    setState(() {
      _createCodeController.text = code;
    });
  }

  Future<void> _pasteJoinCode() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty && mounted) {
      setState(() => _joinCodeController.text = text);
    }
  }

  Future<void> _createRoom() => _prepareEntry(
    DemoRoomEntryKind.create,
    _createRoomMode,
    _createCodeController.text,
  );
  Future<void> _joinRoom({String? providerId, MediaRoomMode? roomMode}) =>
      _prepareEntry(
        DemoRoomEntryKind.join,
        roomMode ??
            _availableRooms
                .where((r) => r.roomCode == _joinCodeController.text.trim())
                .firstOrNull
                ?.roomMode ??
            _joinRoomMode,
        _joinCodeController.text,
        providerId: providerId,
      );

  Future<void> _prepareEntry(
    DemoRoomEntryKind kind,
    MediaRoomMode mode,
    String code, {
    String? providerId,
  }) async {
    if (_busy) return;
    setState(() => _entryPhase = DemoEntryPhase.preparing);
    try {
      final result = await _entryCoordinator.prepare(
        kind: kind,
        backendUrl: _server,
        code: code,
        displayName: _displayNameController.text,
        avatarUrl: _avatarUrlController.text,
        mode: mode,
        meetingMode:
            kind == DemoRoomEntryKind.create && mode == MediaRoomMode.meeting
            ? _createMeetingMode
            : null,
        createRealtime: (url) =>
            widget.realtimeFactory?.call(url) ??
            createDemoRealtime(url, appToken: _appToken),
      );
      if (!mounted) return;
      switch (result) {
        case DemoJoinRejected(:final reason):
          _showFormError(reason);
        case DemoJoinFailed(:final error):
          setState(() => _error = error.message);
        case DemoJoinPrepared(:final entry):
          _displayNameController.text = entry.user.name;
          await _runPreJoin(
            entry.realtime,
            role: entry.role,
            meetingMode: entry.meetingMode,
            roomMode: entry.mode,
            providerId: providerId,
            roomCode: kind == DemoRoomEntryKind.join ? entry.roomCode : null,
            displayName: entry.user.name,
            avatarUrl: entry.user.avatarUrl,
            roomLabel: entry.roomCode ?? DemoStrings.of(context).createAndJoin,
            onEnter: (preJoinContext, settings) async {
              final connection = await entry.connect();
              await _openMeeting(
                preJoinContext,
                connection,
                initialMediaSettings: settings,
                roomMode: entry.mode,
              );
            },
            onEnterWithIntent: (preJoinContext, settings, intent) async {
              final connection = await entry.connect();
              await _openMeeting(
                preJoinContext,
                connection,
                initialMediaSettings: settings,
                roomMode: entry.mode,
                initialSharedContentMode:
                    intent == RealtimePreJoinJoinIntent.screenShare
                    ? SharedContentMode.screen
                    : null,
              );
            },
          );
      }
    } finally {
      if (mounted) setState(() => _entryPhase = DemoEntryPhase.idle);
    }
  }

  Realtime _newRealtime() =>
      widget.realtimeFactory?.call(_server) ??
      createDemoRealtime(_server, appToken: _appToken);

  Future<void> _runPreJoin(
    Realtime realtime, {
    required MediaRole role,
    MediaMeetingMode? meetingMode,
    MediaRoomMode? roomMode,
    required String displayName,
    String? avatarUrl,
    required String roomLabel,
    required RealtimePreJoinEnter onEnter,
    RealtimePreJoinEnterWithIntent? onEnterWithIntent,
    String? providerId,
    String? roomCode,
  }) async {
    if (_entryPhase == DemoEntryPhase.preJoin) return;
    setState(() => _entryPhase = DemoEntryPhase.preJoin);
    try {
      final backgroundPresets =
          await (widget.backgroundPresets?.call() ?? DemoBackground.presets);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => RealtimePreJoinPage(
            permissionRequester:
                widget.permissionRequester ??
                const DefaultMediaPermissionProbe(),
            onEnter: onEnter,
            meetingMode: meetingMode,
            runCheck: () => realtime.preJoin(
              role: role,
              providerId: providerId,
              roomCode: roomCode,
            ),
            openPreview: (id, previewRole) =>
                realtime.createLocalPreview(providerId: id, role: previewRole),
            displayName: displayName,
            avatarUrl: avatarUrl,
            roomLabel: roomLabel,
            imagePresets: backgroundPresets,
            onEnterWithIntent: onEnterWithIntent,
            brand: DemoClassroomSample.brand,
            sessionInfo: (meetingMode == MediaMeetingMode.classroom)
                ? DemoClassroomSample.sessionInfo()
                : null,
            waitingGuests: (meetingMode == MediaMeetingMode.classroom)
                ? DemoClassroomSample.waitingGuests
                : const [],
            agenda: (meetingMode == MediaMeetingMode.classroom)
                ? DemoClassroomSample.agenda
                : const [],
            materials: (meetingMode == MediaMeetingMode.classroom)
                ? DemoClassroomSample.materials
                : const [],
            title: roomMode == MediaRoomMode.meeting
                ? (meetingMode ?? MediaMeetingMode.standard).label(
                    isZh: DemoStrings.of(context).isZh,
                  )
                : role == MediaRole.viewer
                ? DemoStrings.of(context).live
                : role == MediaRole.host
                ? DemoStrings.of(context).startLive
                : DemoStrings.of(context).meeting,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _entryPhase = DemoEntryPhase.idle);
    }
  }

  Future<void> _openMeeting(
    BuildContext preJoinContext,
    RealtimeConnection connection, {
    required MediaLocalPreviewSettings initialMediaSettings,
    MediaRoomMode? roomMode,
    SharedContentMode? initialSharedContentMode,
  }) async {
    if (!preJoinContext.mounted) {
      await connection.dispose();
      return;
    }

    try {
      final destination =
          widget.roomPageFactory?.call(
            connection,
            initialMediaSettings,
            roomMode,
          ) ??
          MeetingRoomPage(
            room: connection.mediaRoom!,
            initialMediaSettings: initialMediaSettings,
            roomMode: roomMode,
            initialSharedContentMode: initialSharedContentMode,
          );
      await Navigator.of(preJoinContext).pushReplacement<void, void>(
        MaterialPageRoute(builder: (_) => destination),
      );
    } finally {
      await connection.dispose();
    }
  }

  void _selectDestination(int index) {
    _demoTabs.index = index;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final strings = DemoStrings.of(context);
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return RealtimeWorkspaceShell(
      compactNavigation: true,
      header: _buildTopBar(),
      selectedIndex: _demoTabs.index,
      onDestinationSelected: _selectDestination,
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home_rounded),
          label: strings.home,
        ),
        NavigationDestination(
          icon: const Icon(Icons.chat_bubble_outline_rounded),
          selectedIcon: const Icon(Icons.chat_bubble_rounded),
          label: strings.chatTab,
        ),
        NavigationDestination(
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings_rounded),
          label: strings.settings,
        ),
      ],
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + inset),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1240),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_demoTabs.index == 0) ...[
                  _homeHero(compact: MediaQuery.sizeOf(context).width < 600),
                  const SizedBox(height: 24),
                  _buildActionTabsCard(),
                  if (_error != null || _formError != null) ...[
                    const SizedBox(height: 16),
                    _buildErrorBanner(),
                  ],
                ],
                // Keep the embedded chat host mounted when navigating away.
                Offstage(
                  offstage: _demoTabs.index != 1,
                  child: FutureBuilder<String>(
                    future: _deviceIdFuture,
                    builder: (context, snapshot) => snapshot.hasData
                        ? StandaloneChatDemoPage(
                            backendUrl: _server,
                            realtime: _newRealtime(),
                            userId: snapshot.data!,
                            displayName: _displayNameController.text,
                            avatarUrl: _avatarUrlController.text,
                            embedded: true,
                            visible: _demoTabs.index == 1,
                          )
                        : const Center(child: CircularProgressIndicator()),
                  ),
                ),
                if (_demoTabs.index == 2) ...[
                  Text(
                    strings.settings,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 24),
                  _buildIdentitySettingsSection(),
                  const SizedBox(height: 24),
                  _buildServerSettingsSection(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    final strings = DemoStrings.of(context);
    final style = RealtimeStyle.of(context);
    final displayFamily = RealtimeFonts.displayOf(context);
    final bodyFamily = RealtimeFonts.bodyOf(context);
    final width = MediaQuery.sizeOf(context).width;
    final isCompact =
        width < 520 || MediaQuery.textScalerOf(context).scale(14) >= 20;

    return Container(
      key: const ValueKey('demo-main-header'),
      constraints: const BoxConstraints(minHeight: 60),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        color: style.surface,
        border: Border(bottom: BorderSide(color: style.border)),
      ),
      child: Row(
        children: [
          // One product identity for the Demo and SDK. Avoid displaying the
          // reference template's Tandem branding as a second product name.
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: style.accent,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Text(
              'r',
              style: TextStyle(
                fontFamily: displayFamily,
                fontSize: 21,
                fontWeight: FontWeight.w800,
                color: style.onAccent,
                height: 1.0,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'multi-video',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: displayFamily,
                    fontSize: isCompact ? 15 : 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.35,
                    color: style.text,
                  ),
                ),
                if (!isCompact)
                  Text(
                    strings.appSubtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: bodyFamily,
                      fontSize: 11.5,
                      color: style.textMuted,
                    ),
                  ),
              ],
            ),
          ),
          _buildLanguageToggle(),
          const SizedBox(width: 6),
          IconButton(
            tooltip: strings.settings,
            onPressed: () => _selectDestination(2),
            icon: RealtimeAvatar(
              name: _displayNameController.text,
              avatarUrl: _avatarUrlController.text,
              size: 28,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLanguageToggle() {
    final isZh = DemoStrings.of(context).isZh;
    final style = RealtimeStyle.of(context);
    return Tooltip(
      message: isZh ? 'Switch to English' : '切换为中文',
      child: RealtimeGlassSurface(
        radius: RealtimeUiTokens.pillRadius,
        opacity: 0.80,
        shadow: false,
        child: TextButton.icon(
          key: const ValueKey('demo-toggle-language'),
          onPressed: () => widget.onLocaleChanged(
            isZh ? const Locale('en') : const Locale('zh', 'CN'),
          ),
          icon: const Icon(Icons.language_rounded, size: 18),
          label: Text(isZh ? '中' : 'EN'),
          style: TextButton.styleFrom(
            foregroundColor: style.text,
            minimumSize: const Size(70, 44),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(RealtimeUiTokens.pillRadius),
            ),
          ),
        ),
      ),
    );
  }

  Widget _homeHero({required bool compact}) => DemoHomeHero(
    compact: compact,
    mediaProviderId: _serverMediaProviderId,
    chatProviderId: _serverChatProviderId,
    online: _serverOnline,
    testingServer: _testingServer,
  );

  Widget _buildServerSettingsSection() => DemoServerSettingsPanel(
    controller: _serverController,
    diagnostics: _diagnostics,
    defaultBackendUrl: _defaultBackendUrl,
    onTest: _testConnection,
  );
  Widget _buildIdentitySettingsSection() => DemoIdentitySettingsPanel(
    deviceId: _deviceIdFuture,
    displayNameController: _displayNameController,
    avatarUrlController: _avatarUrlController,
    onAvatarChanged: (value) {
      unawaited(_identityStore.saveAvatarUrl(value));
      setState(() {});
    },
    onNameChanged: (value) {
      unawaited(_persistDisplayName(value));
      setState(() {});
    },
  );

  Widget _buildActionTabsCard() {
    final strings = DemoStrings.of(context);
    final style = RealtimeStyle.of(context);
    final displayFamily = RealtimeFonts.displayOf(context);
    final bodyFamily = RealtimeFonts.bodyOf(context);

    final quickActionCards = LayoutBuilder(
      builder: (context, constraints) {
        final stack = constraints.maxWidth < 460;
        final meetingCard = _QuickActionTile(
          key: const ValueKey('demo-create-meeting'),
          title: strings.createMeeting,
          actionLabel: strings.configureMeeting,
          description: strings.meetingDescription,
          icon: Icons.videocam_rounded,
          accentColor: style.text,
          subtleBackground: style.surfaceSubtle,
          buttonIcon: Icons.add_rounded,
          isLive: false,
          busy: _busy,
          fillAvailableHeight: !stack,
          onPressed: () => _showCreateForm(false),
        );
        final liveCard = _QuickActionTile(
          key: const ValueKey('demo-start-live'),
          title: strings.startLive,
          actionLabel: strings.configureLive,
          description: strings.liveDescription,
          icon: Icons.sensors_rounded,
          accentColor: style.live,
          subtleBackground: const Color(0xFFFDECEC),
          buttonIcon: Icons.sensors_rounded,
          isLive: true,
          busy: _busy,
          fillAvailableHeight: !stack,
          onPressed: () => _showCreateForm(true),
        );
        return stack
            ? Column(
                children: [meetingCard, const SizedBox(height: 12), liveCard],
              )
            : IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: meetingCard),
                    const SizedBox(width: 14),
                    Expanded(child: liveCard),
                  ],
                ),
              );
      },
    );

    // Tandem Highlight Dark Card (.class-card)
    final joinCard = Container(
      key: const ValueKey('demo-join-card'),
      decoration: BoxDecoration(
        color: const Color(0xFF18202E),
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [
          BoxShadow(
            color: Color(0x220A101D),
            blurRadius: 28,
            offset: Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFF5C518),
                borderRadius: BorderRadius.circular(99),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.bolt_rounded,
                      size: 13,
                      color: Color(0xFF2A2100),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      strings.quickJoin,
                      style: TextStyle(
                        fontFamily: bodyFamily,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        color: const Color(0xFF2A2100),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            strings.joinRoom,
            style: TextStyle(
              fontFamily: displayFamily,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            strings.joinRoomDescription,
            style: TextStyle(
              fontFamily: bodyFamily,
              fontSize: 13,
              color: Colors.white.withValues(alpha: 0.65),
            ),
          ),
          const SizedBox(height: 18),
          RealtimeCupertinoSegmentedBar<MediaRoomMode>(
            groupValue: _joinRoomMode,
            backgroundColor: Colors.white.withValues(alpha: 0.08),
            thumbColor: Colors.white.withValues(alpha: 0.16),
            onValueChanged: (mode) => setState(() => _joinRoomMode = mode),
            children: {
              MediaRoomMode.meeting: Text(
                strings.joinMeetingParticipant,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              MediaRoomMode.broadcast: Text(
                strings.watchLiveViewer,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            },
          ),
          const SizedBox(height: 18),
          _roomForm(
            code: _joinCodeController,
            codeLabel: strings.roomCode,
            actionLabel: strings.joinRoom,
            action: _joinRoom,
            isCreate: false,
            isDarkCard: true,
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            RealtimeBreakpoints.isWide(
              context,
              MediaQuery.sizeOf(context).width,
            ) &&
            constraints.maxWidth >= 850;
        return wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 135,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        quickActionCards,
                        const SizedBox(height: 20),
                        _buildAvailableRooms(),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    flex: 100,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        joinCard,
                        const SizedBox(height: 20),
                        _buildServiceReadinessCard(),
                      ],
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  joinCard,
                  const SizedBox(height: 20),
                  quickActionCards,
                  const SizedBox(height: 20),
                  _buildAvailableRooms(),
                  const SizedBox(height: 20),
                  _buildServiceReadinessCard(),
                ],
              );
      },
    );
  }

  Widget _buildServiceReadinessCard() {
    final style = RealtimeStyle.of(context);
    final strings = DemoStrings.of(context);
    final displayFamily = RealtimeFonts.displayOf(context);
    final bodyFamily = RealtimeFonts.bodyOf(context);

    final String mediaName = _testingServer
        ? strings.checking
        : _serverMediaProviderId == null
        ? strings.unconfigured
        : mediaProviderDisplayName(_serverMediaProviderId!);
    final String chatName = _testingServer
        ? strings.checking
        : _serverChatProviderId == null
        ? strings.unconfigured
        : strings.chatProviderDisplayName(_serverChatProviderId!);

    return RealtimeCardSurface(
      fillColor: style.surface,
      borderColor: style.border,
      radius: 18,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  strings.serviceReadiness,
                  style: TextStyle(
                    fontFamily: displayFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    color: style.text,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 9,
                  vertical: 3.5,
                ),
                decoration: BoxDecoration(
                  color: _serverOnline == true
                      ? const Color(0xFFEFFAF8)
                      : (_serverOnline == false
                            ? const Color(0xFFFDECEC)
                            : const Color(0xFFFFF6D6)),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(
                    color: _serverOnline == true
                        ? const Color(0xFFAEDFD8)
                        : (_serverOnline == false
                              ? const Color(0xFFF5C2C4)
                              : const Color(0xFFE9CE6A)),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: _serverOnline == true
                            ? const Color(0xFF0E9E8E)
                            : (_serverOnline == false
                                  ? const Color(0xFFD93A3F)
                                  : const Color(0xFFF5C518)),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _serverOnline == true
                          ? 'Online'
                          : (_serverOnline == false ? 'Offline' : 'Checking'),
                      style: TextStyle(
                        fontFamily: bodyFamily,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _serverOnline == true
                            ? const Color(0xFF0B7F72)
                            : (_serverOnline == false
                                  ? const Color(0xFFD93A3F)
                                  : const Color(0xFF2A2100)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _buildReadinessRow(
            icon: Icons.video_camera_front_rounded,
            label: strings.videoProviderLabel,
            value: mediaName,
            statusColor: _serverMediaProviderId != null
                ? const Color(0xFF0E9E8E)
                : null,
            style: style,
            bodyFamily: bodyFamily,
          ),
          Divider(height: 16, thickness: 1, color: style.borderSubtle),
          _buildReadinessRow(
            icon: Icons.chat_bubble_outline_rounded,
            label: strings.chatProviderLabel,
            value: chatName,
            statusColor: _serverChatProviderId != null
                ? const Color(0xFF0E9E8E)
                : null,
            style: style,
            bodyFamily: bodyFamily,
          ),
          Divider(height: 16, thickness: 1, color: style.borderSubtle),
          _buildReadinessRow(
            icon: Icons.dns_outlined,
            label: 'Backend URL',
            value: _server,
            style: style,
            bodyFamily: bodyFamily,
            truncate: true,
          ),
        ],
      ),
    );
  }

  Widget _buildReadinessRow({
    required IconData icon,
    required String label,
    required String value,
    required RealtimeStyle style,
    required String bodyFamily,
    Color? statusColor,
    bool truncate = false,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: style.textMuted),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: bodyFamily,
              fontSize: 12.5,
              color: style.textMuted,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (statusColor != null) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: truncate
                      ? TextOverflow.ellipsis
                      : TextOverflow.clip,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontFamily: bodyFamily,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: style.text,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showCreateForm(bool live) {
    final strings = DemoStrings.of(context);
    final label = live ? strings.startLive : strings.createMeeting;
    unawaited(
      showRealtimeGlassBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) => StatefulBuilder(
          builder: (sheetContext, setSheetState) => SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              24,
              8,
              24,
              24 + MediaQuery.viewInsetsOf(sheetContext).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: RealtimeSheetHeader(title: label)),
                    IconButton(
                      tooltip: RealtimeStrings.of(context).close,
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  live
                      ? strings.liveBannerDescription
                      : strings.meetingBannerDescription,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                if (!live) ...[
                  RealtimeMeetingModeSelector(
                    value: _createMeetingMode,
                    onChanged: (mode) =>
                        setSheetState(() => _createMeetingMode = mode),
                  ),
                  const SizedBox(height: 20),
                ],
                _roomForm(
                  code: _createCodeController,
                  codeLabel: strings.optionalRoomCode,
                  actionLabel: label,
                  isCreate: true,
                  action: () async {
                    _createRoomMode = live
                        ? MediaRoomMode.broadcast
                        : MediaRoomMode.meeting;
                    Navigator.pop(sheetContext);
                    await _createRoom();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _roomForm({
    required TextEditingController code,
    required String codeLabel,
    required String actionLabel,
    required Future<void> Function() action,
    required bool isCreate,
    bool isDarkCard = false,
  }) {
    final strings = DemoStrings.of(context);
    final displayFamily = RealtimeFonts.displayOf(context);

    if (isDarkCard) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: code,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            cursorColor: const Color(0xFFF5C518),
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0xFF222D3E),
              labelText: codeLabel,
              labelStyle: const TextStyle(
                color: Color(0xFF93A1B8),
                fontSize: 13,
              ),
              hintText: strings.roomCodeHelp,
              hintStyle: const TextStyle(
                color: Color(0xFF5B6678),
                fontSize: 13,
              ),
              prefixIcon: const Icon(
                Icons.tag_rounded,
                color: Color(0xFF93A1B8),
                size: 20,
              ),
              suffixIcon: isCreate
                  ? IconButton(
                      tooltip: strings.random,
                      icon: const Icon(
                        Icons.casino_outlined,
                        color: Color(0xFF93A1B8),
                        size: 20,
                      ),
                      onPressed: _busy ? null : _generateRandomCreateCode,
                    )
                  : TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFFF5C518),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      onPressed: _busy
                          ? null
                          : () => unawaited(_pasteJoinCode()),
                      icon: const Icon(Icons.content_paste_rounded, size: 16),
                      label: Text(
                        RealtimeStrings.of(context).paste,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF2E3D56)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF2E3D56)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: Color(0xFFF5C518),
                  width: 1.5,
                ),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 14,
              ),
            ),
          ),
          const SizedBox(height: 18),
          // Signature Tandem .start button
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF5C518),
                foregroundColor: const Color(0xFF2A2100),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: _busy ? null : action,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Color(0xFF2A2100),
                      ),
                    )
                  : FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.arrow_forward_rounded, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            actionLabel,
                            style: TextStyle(
                              fontFamily: displayFamily,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RealtimeGlassTextField(
          controller: code,
          label: codeLabel,
          hintText: strings.roomCodeHelp,
          prefixIcon: Icons.tag_rounded,
          suffix: isCreate
              ? RealtimeFieldAction(
                  label: strings.random,
                  icon: Icons.casino_outlined,
                  onPressed: _busy ? null : _generateRandomCreateCode,
                )
              : RealtimeFieldAction(
                  label: RealtimeStrings.of(context).paste,
                  icon: Icons.content_paste_rounded,
                  onPressed: _busy ? null : () => unawaited(_pasteJoinCode()),
                ),
        ),
        const SizedBox(height: 18),
        RealtimeGlassButton(
          onPressed: _busy ? null : action,
          isLoading: _busy,
          icon: isCreate ? Icons.add_rounded : Icons.arrow_forward_rounded,
          child: Text(actionLabel),
        ),
      ],
    );
  }

  Widget _buildAvailableRooms() => DemoAvailableRooms(
    rooms: _availableRooms,
    error: _roomListError,
    loading: _roomDirectory.loading,
    busy: _busy,
    onRefresh: () => unawaited(_refreshRooms()),
    onJoin: (room) => unawaited(_joinDiscoveredRoom(room)),
  );

  Widget _buildErrorBanner() {
    final style = RealtimeStyle.of(context);
    return RealtimeGlassSurface(
      radius: RealtimeUiTokens.controlRadius,
      padding: const EdgeInsets.all(14),
      fillColor: style.dangerSubtle,
      borderColor: style.isDark
          ? const Color(0xFF7F1D1D)
          : const Color(0xFFFECDD3),
      opacity: 0.94,
      shadow: false,
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: style.danger, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _displayError(context)!,
              style: TextStyle(
                color: style.isDark
                    ? const Color(0xFFFCA5A5)
                    : const Color(0xFFB91C1C),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.close_rounded,
              size: 16,
              color: style.isDark
                  ? const Color(0xFFFCA5A5)
                  : const Color(0xFFB91C1C),
            ),
            onPressed: () => setState(() {
              _error = null;
              _formError = null;
            }),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

class _QuickActionTile extends StatelessWidget {
  const _QuickActionTile({
    super.key,
    required this.title,
    required this.actionLabel,
    required this.description,
    required this.icon,
    required this.accentColor,
    required this.subtleBackground,
    required this.buttonIcon,
    required this.isLive,
    required this.busy,
    required this.fillAvailableHeight,
    required this.onPressed,
  });

  final String title;
  final String actionLabel;
  final String description;
  final IconData icon;
  final Color accentColor;
  final Color subtleBackground;
  final IconData buttonIcon;
  final bool isLive;
  final bool busy;
  final bool fillAvailableHeight;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    final displayFamily = RealtimeFonts.displayOf(context);
    final bodyFamily = RealtimeFonts.bodyOf(context);

    return RealtimeCardSurface(
      fillColor: style.surface,
      borderColor: style.border,
      radius: 18,
      padding: const EdgeInsets.all(20),
      onTap: busy ? null : onPressed,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: subtleBackground,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isLive
                        ? const Color(0xFFF5C2C4)
                        : style.borderSubtle,
                  ),
                ),
                child: Icon(icon, color: accentColor, size: 20),
              ),
              const Spacer(),
              Icon(
                Icons.arrow_outward_rounded,
                size: 18,
                color: style.textMuted.withValues(alpha: 0.6),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: displayFamily,
              fontSize: 16.5,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              color: style.text,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: bodyFamily,
              fontSize: 12.5,
              height: 1.4,
              color: style.textMuted,
            ),
          ),
          const SizedBox(height: 16),
          if (fillAvailableHeight) const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 38,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: isLive ? const Color(0xFFD93A3F) : style.text,
                side: BorderSide(
                  color: isLive ? const Color(0xFFF5C2C4) : style.border,
                ),
                backgroundColor: isLive
                    ? const Color(0xFFFDECEC)
                    : style.surfaceSubtle,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              onPressed: busy ? null : onPressed,
              icon: Icon(buttonIcon, size: 16),
              label: Text(
                actionLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: bodyFamily,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
