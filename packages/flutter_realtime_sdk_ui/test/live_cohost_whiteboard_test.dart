import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'viewer promotes to co-host when approved and steps down cleanly',
    (tester) async {
      final viewerSession = _SwitchableBroadcastSession(
        role: MediaRole.viewer,
        participantId: 'viewer-1',
      );
      final liveRepo = _FakeLiveRepository(
        initialState: LiveInteractionState(
          roomCode: 'live-1',
          revision: 1,
          selfUserId: 'viewer-1',
          recipientId: 'host-1',
          canSendGift: true,
          cohostSupported: true,
        ),
      );
      final sharedRepo = _FakeSharedContentRepository(canManage: false);
      final room = RealtimeRoom(
        media: MediaRoomSession.direct(
          roomCode: 'live-1',
          participantId: 'viewer-1',
          session: viewerSession,
          backendMetadata: const {'roomMode': 'broadcast'},
        ),
        renderer: const _NoopRenderer(),
        disposeClients: () {},
        featurePlugins: [
          LivePreset(
            enableForDirectRooms: true,
            pollInterval: const Duration(hours: 1),
            repositoryFactory: (_) => liveRepo,
          ),
          SharedContentPreset(repositoryFactory: (_) => sharedRepo),
        ],
      );
      addTearDown(room.dispose);

      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: RealtimeLivePage(
            room: room,
            showChat: false,
            preventScreenCapture: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Viewer sees Request mic and no microphone/camera toggles initially.
      expect(find.text('Request mic'), findsOneWidget);
      expect(find.byType(RealtimeDockMicrophoneButton), findsNothing);

      await tester.tap(find.text('Request mic'));
      await tester.pumpAndSettle();
      expect(liveRepo.actions, contains('requestCohost'));
      expect(find.text('Cancel'), findsOneWidget);

      // Simulate host approving co-host request.
      liveRepo.currentState = LiveInteractionState(
        roomCode: 'live-1',
        revision: 2,
        selfUserId: 'viewer-1',
        recipientId: 'host-1',
        canSendGift: true,
        cohostSupported: true,
        selfCohostStatus: LiveCohostStatus.approved,
        activeCohosts: const [
          LiveCohostMember(
            userId: 'viewer-1',
            participantId: 'viewer-1',
            displayName: 'Alice',
          ),
        ],
      );
      await room.liveInteractions!.refresh();
      await tester.pumpAndSettle();

      expect(room.media.role, MediaRole.participant);
      expect(find.text('Leave mic'), findsOneWidget);
      expect(find.byType(RealtimeDockMicrophoneButton), findsOneWidget);
      expect(find.byType(RealtimeDockCameraButton), findsOneWidget);

      // Viewer ends co-hosting and demotes back to viewer.
      await tester.ensureVisible(find.byType(RealtimeLiveCohostButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(RealtimeLiveCohostButton));
      await tester.pumpAndSettle();
      expect(liveRepo.actions, contains('cancelCohost'));
      expect(room.media.role, MediaRole.viewer);
      expect(find.text('Request mic'), findsOneWidget);

      await tester.runAsync(room.dispose);
      await tester.pump();
    },
  );

  testWidgets(
    'host tools manage broadcast whiteboard and co-host approval queue',
    (tester) async {
      final hostSession = _SwitchableBroadcastSession(
        role: MediaRole.host,
        participantId: 'host-1',
      );
      final liveRepo = _FakeLiveRepository(
        initialState: LiveInteractionState(
          roomCode: 'live-1',
          revision: 1,
          selfUserId: 'host-1',
          recipientId: 'host-1',
          canSendGift: false,
          cohostSupported: true,
          cohostRequests: const [
            LiveCohostRequest(
              userId: 'viewer-2',
              participantId: 'viewer-2',
              displayName: 'Bob',
              status: LiveCohostStatus.requested,
              requestedAt: '2026-11-17T00:00:00Z',
            ),
          ],
          activeCohosts: const [
            LiveCohostMember(
              userId: 'viewer-1',
              participantId: 'viewer-1',
              displayName: 'Alice',
            ),
          ],
        ),
      );
      final sharedRepo = _FakeSharedContentRepository(canManage: true);
      final room = RealtimeRoom(
        media: MediaRoomSession.direct(
          roomCode: 'live-1',
          participantId: 'host-1',
          session: hostSession,
          backendMetadata: const {'roomMode': 'broadcast'},
        ),
        renderer: const _NoopRenderer(),
        disposeClients: () {},
        featurePlugins: [
          LivePreset(
            enableForDirectRooms: true,
            pollInterval: const Duration(hours: 1),
            repositoryFactory: (_) => liveRepo,
          ),
          SharedContentPreset(repositoryFactory: (_) => sharedRepo),
        ],
      );
      addTearDown(room.dispose);

      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: RealtimeLivePage(
            room: room,
            showChat: false,
            preventScreenCapture: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open Host Tools bottom sheet from rail button.
      await tester.tap(find.byIcon(Icons.tune_rounded).first);
      await tester.pumpAndSettle();

      expect(find.text('Interactive Whiteboard'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Audience Co-Hosts'), findsOneWidget);
      expect(find.textContaining('Bob'), findsOneWidget);
      expect(find.textContaining('Alice'), findsOneWidget);

      await tester.ensureVisible(find.text('Approve'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect(liveRepo.actions, contains('respondCohost:viewer-2:approve'));

      await tester.ensureVisible(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(room.sharedContent?.content?.mode, SharedContentMode.whiteboard);

      // Dismiss Host Tools sheet and confirm WhiteboardToolRail is rendered on stage.
      Navigator.of(tester.element(find.text('Interactive Whiteboard'))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(WhiteboardToolRail), findsOneWidget);

      await tester.runAsync(room.dispose);
      await tester.pump();
    },
  );
}

class _FakeSharedContentRepository extends SharedContentRepository {
  _FakeSharedContentRepository({required this.canManage});

  final bool canManage;
  int _rev = 1;
  SharedContentMode _mode = SharedContentMode.members;

  SharedContentState _buildState() => SharedContentState(
    mode: _mode,
    whiteboard: WhiteboardState(
      revision: _rev,
      canEdit: canManage,
      pages: [const WhiteboardPage(id: 'page-1', title: 'Page 1')],
      activePageId: 'page-1',
      canvas: AnnotationCanvas(sourceKey: 'page-1'),
    ),
    screen: AnnotationCanvas(sourceKey: 'screen'),
    canManage: canManage,
    snapshotRevision: _rev,
  );

  @override
  Future<SharedContentState?> snapshot() async => _buildState();

  @override
  Future<SharedContentState?> action(SharedContentCommand command) async {
    _rev++;
    if (command.action == SharedContentAction.mode) {
      final raw = command.payload['mode']?.toString();
      if (raw == SharedContentMode.whiteboard.name) {
        _mode = SharedContentMode.whiteboard;
      } else if (raw == SharedContentMode.members.name) {
        _mode = SharedContentMode.members;
      } else if (raw == SharedContentMode.screen.name) {
        _mode = SharedContentMode.screen;
      }
    }
    return _buildState();
  }

  @override
  Future<void> close() async {}
}

class _FakeLiveRepository
    implements LiveInteractionRepository, LiveCohostRepository {
  _FakeLiveRepository({required this.initialState})
    : currentState = initialState;

  final LiveInteractionState initialState;
  LiveInteractionState currentState;
  final List<String> actions = [];

  @override
  Future<LiveInteractionState> snapshot() async => currentState;

  @override
  Future<LiveInteractionState> sendGift(
    String giftId,
    int quantity, {
    required String eventId,
  }) async => currentState;

  @override
  Future<LiveInteractionState> sendLike({required String eventId}) async =>
      currentState;

  @override
  Future<LiveInteractionState> requestCohost() async {
    actions.add('requestCohost');
    currentState = LiveInteractionState(
      roomCode: currentState.roomCode,
      revision: currentState.revision + 1,
      selfUserId: currentState.selfUserId,
      recipientId: currentState.recipientId,
      canSendGift: currentState.canSendGift,
      cohostSupported: true,
      selfCohostStatus: LiveCohostStatus.requested,
    );
    return currentState;
  }

  @override
  Future<LiveInteractionState> cancelCohost() async {
    actions.add('cancelCohost');
    currentState = LiveInteractionState(
      roomCode: currentState.roomCode,
      revision: currentState.revision + 1,
      selfUserId: currentState.selfUserId,
      recipientId: currentState.recipientId,
      canSendGift: currentState.canSendGift,
      cohostSupported: true,
      selfCohostStatus: LiveCohostStatus.none,
    );
    return currentState;
  }

  @override
  Future<LiveInteractionState> respondCohost(
    String userId,
    String action,
  ) async {
    actions.add('respondCohost:$userId:$action');
    return currentState;
  }

  @override
  void close() {}
}

class _SwitchableBroadcastSession extends Fake
    implements
        InteractiveMediaSession,
        BroadcastHostSession,
        BroadcastViewerSession,
        MediaRoleSwitchable {
  _SwitchableBroadcastSession({
    required this.role,
    required this.participantId,
  });

  @override
  final MediaRole role;
  final String participantId;
  final _snapshots = StreamController<MediaSnapshot>.broadcast();
  final _states = StreamController<MediaSessionState>.broadcast();
  final _events = StreamController<MediaEvent>.broadcast();

  @override
  String get providerId => 'ivs';

  @override
  MediaSessionState get state => MediaSessionState.connected;

  @override
  MediaCapabilities get capabilities => role == MediaRole.viewer
      ? const MediaCapabilities(
          canSubscribeVideo: true,
          canEnumerateAudioDevices: true,
          canSelectAudioOutput: true,
        )
      : MediaCapabilities(
          canPublishAudio: true,
          canPublishVideo: true,
          canScreenShare: true,
          canSubscribeVideo: true,
          canListParticipants: role == MediaRole.host,
          canRemoveParticipants: role == MediaRole.host,
          canCloseRoom: role == MediaRole.host,
        );

  @override
  MediaSnapshot get snapshot => MediaSnapshot(
    state: MediaSessionState.connected,
    role: role,
    localParticipantId: participantId,
    participants: [
      MediaParticipant(
        id: participantId,
        displayName: participantId,
        isLocal: true,
      ),
    ],
    capabilities: capabilities,
  );

  @override
  Stream<MediaSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<MediaSessionState> get states => _states.stream;

  @override
  Stream<MediaEvent> get events => _events.stream;

  @override
  void setRoleChangeCallback(MediaRoleChangeCallback? callback) {}

  @override
  Future<MediaSession> switchRole(MediaRole targetRole) async {
    if (targetRole == role) return this;
    return _SwitchableBroadcastSession(
      role: targetRole,
      participantId: participantId,
    );
  }

  @override
  Future<void> dispose() async {
    await _snapshots.close();
    await _states.close();
    await _events.close();
  }
}

class _NoopRenderer extends MediaTrackRenderer {
  const _NoopRenderer();

  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      const SizedBox.shrink();
}
