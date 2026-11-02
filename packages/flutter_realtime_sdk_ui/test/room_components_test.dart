import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';

void main() {
  testWidgets(
    'standard page applies Pre-Join devices and enabled media before rendering controls',
    (tester) async {
      final media = _DeviceMediaSession();
      final room = _room(media);
      addTearDown(room.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: RealtimeRoomView(
            room: room,
            config: const RealtimeRoomViewConfig(
              initialMediaSettings: MediaLocalPreviewSettings(
                microphoneEnabled: true,
                cameraEnabled: true,
                microphone: MediaDevice(
                  id: 'mic-usb',
                  label: 'USB microphone',
                  kind: MediaDeviceKind.microphone,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(media.selected.single.id, 'mic-usb');
      expect(media.muteCalls, 1);
      expect(media.cameraCalls, 1);
      expect(find.byType(RealtimeMeetingPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'default room view renders the complete meeting UI without taking room ownership',
    (tester) async {
      final media = _FakeMediaSession();
      final room = _room(media);
      addTearDown(room.dispose);
      for (final width in [390.0, 768.0, 1280.0]) {
        await tester.binding.setSurfaceSize(Size(width, 850));
        await tester.pumpWidget(
          MaterialApp(home: RealtimeRoomView(room: room)),
        );
        await tester.pump();
        expect(find.byType(RealtimeMeetingPage), findsOneWidget);
        expect(find.byType(RealtimeMeetingTopBar), findsOneWidget);
        expect(find.byType(RealtimeMeetingDock), findsOneWidget);
        expect(find.byType(RealtimeMeetingStage), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(media.disposeCalls, 0);
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets(
    'backend mode wins over the default page hint and hides optional live UI',
    (tester) async {
      final room = RealtimeRoom(
        media: MediaRoomSession.direct(
          roomCode: 'broadcast',
          participantId: 'self',
          session: _FakeMediaSession(role: MediaRole.viewer),
          backendMetadata: const {'roomMode': 'broadcast'},
        ),
        renderer: const _FakeRenderer(),
        disposeClients: () {},
      );
      addTearDown(room.dispose);
      for (final width in [390.0, 1280.0]) {
        await tester.binding.setSurfaceSize(Size(width, 850));
        await tester.pumpWidget(
          MaterialApp(
            home: RealtimeRoomView(
              room: room,
              config: const RealtimeRoomViewConfig(
                roomMode: MediaRoomMode.meeting,
                showChat: false,
              ),
              showLiveInteractions: false,
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(RealtimeLivePage), findsOneWidget);
        expect(find.byType(RealtimeMeetingPage), findsNothing);
        expect(find.byType(RealtimeChatComposer), findsNothing);
        expect(find.byType(RealtimeLiveChatFeed), findsNothing);
        expect(find.byType(RealtimeLiveLikeButton), findsNothing);
        expect(tester.takeException(), isNull);
      }
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets(
    'standard meeting page preserves custom participant rendering and extension overlays',
    (tester) async {
      final room = _room(_FakeMediaSession());
      addTearDown(room.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: RealtimeRoomView(
            room: room,
            header: const Text('Host header'),
            participantBuilder: (_, member, _) =>
                Text('Custom tile: ${member.id}'),
            stageOverlayBuilder: (_) =>
                const Align(child: Text('Host overlay')),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Host header'), findsOneWidget);
      expect(find.text('Custom tile: self'), findsOneWidget);
      expect(find.text('Host overlay'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'meeting duration survives replacement of its compact presentation',
    (tester) async {
      final started = DateTime.now().subtract(const Duration(minutes: 5));
      await tester.pumpWidget(
        MaterialApp(home: RealtimeMeetingTimerBadge(startedAt: started)),
      );
      expect(find.text('05:00'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(home: RealtimeMeetingTimerBadge(startedAt: started)),
      );
      expect(find.text('05:00'), findsOneWidget);
    },
  );

  testWidgets('background controls explain unavailable platform support', (
    tester,
  ) async {
    final room = _room(_FakeMediaSession());
    addTearDown(room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeRoomUiScope(
          room: room,
          child: const Scaffold(
            body: Column(
              children: [
                RealtimeBackgroundEffectsButton(),
                RealtimeRoomActionButton(
                  action: RealtimeRoomUiAction.backgroundEffect,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Background effects are unavailable'),
      findsOneWidget,
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(RealtimeRoomActionButton));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Background effects are unavailable'),
      findsOneWidget,
    );
  });

  testWidgets('background effects are hidden from viewer media roles', (
    tester,
  ) async {
    final media = _FakeMediaSession(role: MediaRole.viewer);
    media._emit(
      media.snapshot.copyWith(
        capabilities: const MediaCapabilities.broadcastViewer(),
      ),
    );
    final room = _room(media);
    addTearDown(room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeRoomUiScope(
          room: room,
          child: const Scaffold(body: RealtimeBackgroundEffectsButton()),
        ),
      ),
    );
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('background selector applies blur via SDK shared controller', (
    tester,
  ) async {
    final media = _FakeMediaSession();
    final effects = _FakeRealtimeVideoEffects();
    final room = _room(
      media,
      videoEffects: effects,
      effectsCapabilities: const MediaBackgroundCapabilities(canBlur: true),
    );
    addTearDown(room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeRoomUiScope(
          room: room,
          child: const Scaffold(body: RealtimeBackgroundEffectsButton()),
        ),
      ),
    );
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(BackgroundEffectSelector),
        matching: find.text('Virtual background'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Background blur'));
    await tester.pumpAndSettle();
    expect(
      effects.controller.backgroundEffect.type,
      MediaBackgroundEffectType.blur,
    );
  });

  testWidgets('broadcast controls toggle media and disappear for viewers', (
    tester,
  ) async {
    for (final role in [MediaRole.host, MediaRole.viewer]) {
      final media = _FakeMediaSession(role: role);
      final room = _room(media);
      await tester.pumpWidget(
        MaterialApp(
          theme: RealtimeUiTheme.light(),
          home: RealtimeRoomUiScope(
            room: room,
            child: const Scaffold(
              body: Center(child: RealtimeLiveMediaControls()),
            ),
          ),
        ),
      );
      expect(media.muteCalls, 0);
      expect(media.cameraCalls, 0);
      if (role == MediaRole.host) {
        await tester.tap(find.byTooltip('Turn on microphone'));
        await tester.pumpAndSettle();
        expect(media.muteCalls, 1);
        expect(find.byTooltip('Turn off microphone'), findsOneWidget);
        await tester.tap(find.byTooltip('Turn on camera'));
        await tester.pumpAndSettle();
        expect(media.cameraCalls, 1);
        expect(find.byTooltip('Turn off camera'), findsOneWidget);
      } else {
        expect(find.byType(RealtimeRoomActionButton), findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(room.dispose);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'live page adapts across small, tablet, landscape and desktop sizes',
    (tester) async {
      final room = _room(_FakeMediaSession(role: MediaRole.host));
      addTearDown(room.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final viewports = const [
        Size(320, 640),
        Size(390, 844),
        Size(600, 850),
        Size(768, 960),
        Size(1024, 850),
        Size(1280, 900),
        Size(1440, 900),
        Size(740, 390),
      ];
      for (final viewport in viewports) {
        for (final scale in [1.0, 2.0]) {
          await tester.binding.setSurfaceSize(viewport);
          await tester.pumpWidget(
            MaterialApp(
              theme: RealtimeUiTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: RealtimeLivePage(room: room),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(RealtimeLivePage), findsOneWidget);
          expect(
            find.byType(RealtimeLiveDesktopStage),
            findsOneWidget,
            reason: 'layout at $viewport with text scale $scale',
          );
          expect(find.byType(RealtimeRoomShell), findsOneWidget);
          expect(find.byType(RealtimeMeetingTopBar), findsOneWidget);
          expect(find.byType(RealtimeMeetingDock), findsOneWidget);
          expect(find.byType(RealtimeLiveMobileOverlay), findsNothing);
          expect(
            tester.takeException(),
            isNull,
            reason: 'at $viewport with text scale $scale',
          );
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('desktop live shares meeting shell and navigates to members', (
    tester,
  ) async {
    final room = _room(_FakeMediaSession(role: MediaRole.host));
    addTearDown(room.dispose);
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: RealtimeLivePage(room: room),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RealtimeMeetingTopBar), findsOneWidget);
    expect(find.byType(RealtimeMeetingDock), findsOneWidget);
    expect(find.byType(RealtimeMeetingRail), findsOneWidget);
    expect(find.byType(RealtimeMeetingSidebar), findsOneWidget);
    expect(find.byType(RealtimeLiveVideoStage), findsOneWidget);
    expect(find.byType(RealtimeLiveMediaControls), findsNothing);
    expect(find.byType(RealtimeDockMoreButton), findsNothing);
    expect(
      find.descendant(
        of: find.byType(RealtimeMeetingDock),
        matching: find.byTooltip('Host tools'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(RealtimeMeetingRail),
        matching: find.byTooltip('Host tools'),
      ),
      findsOneWidget,
    );

    final rail = find.byType(RealtimeMeetingRail);
    await tester.tap(
      find.descendant(of: rail, matching: find.byTooltip('Participants')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RealtimeManagedParticipantList), findsOneWidget);
    await tester.tap(
      find.descendant(of: rail, matching: find.byTooltip('Chat')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RealtimeManagedParticipantList), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('tablet live uses the meeting horizontal rail', (tester) async {
    final room = _room(_FakeMediaSession(role: MediaRole.host));
    addTearDown(room.dispose);
    await tester.binding.setSurfaceSize(const Size(720, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: RealtimeLivePage(room: room),
      ),
    );
    await tester.pumpAndSettle();
    final rail = find.byType(RealtimeMeetingRail);
    expect(rail, findsOneWidget);
    expect(tester.widget<RealtimeMeetingRail>(rail).horizontal, isTrue);
    expect(find.byType(RealtimeMeetingSidebar), findsNothing);
    final header = tester.getRect(find.byType(RealtimeMeetingTopBar));
    final navigation = tester.getRect(rail);
    expect(navigation.top, closeTo(header.bottom, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mobile viewer has a meeting-style dock without host tools', (
    tester,
  ) async {
    final room = _room(_FakeMediaSession(role: MediaRole.viewer));
    addTearDown(room.dispose);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: RealtimeLivePage(room: room),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RealtimeRoomShell), findsOneWidget);
    expect(find.byType(RealtimeMeetingRail), findsOneWidget);
    expect(
      tester
          .widget<RealtimeMeetingRail>(find.byType(RealtimeMeetingRail))
          .horizontal,
      isTrue,
    );
    expect(find.byType(RealtimeMeetingSidebar), findsNothing);
    expect(find.byType(RealtimeDockMicrophoneButton), findsNothing);
    expect(find.byType(RealtimeDockCameraButton), findsNothing);
    expect(find.byTooltip('Host tools'), findsNothing);
    final people = find.descendant(
      of: find.byType(RealtimeMeetingRail),
      matching: find.byTooltip('Participants'),
    );
    final pageController = RealtimeRoomUiScope.of(
      tester.element(find.byType(RealtimeRoomShell)),
    );
    await tester.ensureVisible(people);
    await tester.tap(people);
    await tester.pumpAndSettle();
    expect(find.byType(RealtimeManagedParticipantList), findsOneWidget);
    final drawerController = RealtimeRoomUiScope.of(
      tester.element(find.byType(RealtimeManagedParticipantList)),
    );
    expect(identical(pageController, drawerController), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'large text keeps live host tools reachable from secondary rail',
    (tester) async {
      final hostRoom = _room(_FakeMediaSession(role: MediaRole.host));
      addTearDown(hostRoom.dispose);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: RealtimeUiTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: RealtimeLivePage(room: hostRoom),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byTooltip('Display options'), findsNothing);
      final hostTools = find.descendant(
        of: find.byType(RealtimeMeetingRail),
        matching: find.byTooltip('Host tools'),
      );
      expect(hostTools, findsOneWidget);
      await tester.ensureVisible(hostTools);
      await tester.pumpAndSettle();
      await tester.tap(hostTools);
      await tester.pumpAndSettle();
      expect(find.byType(RealtimeHostToolsPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'live discussion remains scrollable with many messages and large text',
    (tester) async {
      final chat = _BufferedChatSession();
      final room = RealtimeRoom(
        media: MediaRoomSession.direct(
          roomCode: 'live',
          participantId: 'self',
          session: _FakeMediaSession(),
        ),
        chat: chat,
        renderer: const _FakeRenderer(),
        disposeClients: () {},
      );
      addTearDown(room.dispose);
      for (final scale in [1.0, 2.0]) {
        for (final height in [180.0, 420.0]) {
          await tester.pumpWidget(
            MaterialApp(
              home: RealtimeRoomUiScope(
                room: room,
                child: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: Scaffold(
                    body: Center(
                      child: SizedBox(
                        width: 320,
                        height: height,
                        child: Align(
                          alignment: Alignment.bottomLeft,
                          child: RealtimeLiveChatFeed(
                            key: ValueKey('$scale/$height'),
                            maxMessages: 20,
                            onVideo: false,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          final scrollable = tester.state<ScrollableState>(
            find.descendant(
              of: find.byType(RealtimeLiveChatFeed),
              matching: find.byType(Scrollable),
            ),
          );
          expect(scrollable.position.maxScrollExtent, greaterThan(0));
          expect(scrollable.position.pixels, 0);
          scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
      }
    },
  );

  testWidgets('independently mounted live host panel rejects a guest role', (
    tester,
  ) async {
    final room = _room(_FakeMediaSession(role: MediaRole.participant));
    addTearDown(room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeRoomUiScope(
          room: room,
          child: const Scaffold(body: RealtimeHostToolsPanel(showHeader: true)),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Broadcaster tools are host-only'), findsOneWidget);
    expect(find.text('Switch Camera'), findsNothing);
    expect(find.text('Screen Share'), findsNothing);
  });
  testWidgets('host can place the same leave widget at the top right', (
    tester,
  ) async {
    final media = _FakeMediaSession();
    final room = _room(media);
    addTearDown(room.dispose);

    for (final width in [390.0, 768.0, 1280.0, 1440.0]) {
      await tester.binding.setSurfaceSize(Size(width, 850));
      await tester.pumpWidget(
        MaterialApp(
          home: RealtimeRoomUiScope(
            room: room,
            child: Scaffold(
              body: Column(
                children: [
                  const Row(
                    children: [
                      RealtimeRoomInfo(),
                      Spacer(),
                      RealtimeLeaveButton(),
                    ],
                  ),
                  const Expanded(child: RealtimeVideoGrid()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final rect = tester.getRect(find.byType(RealtimeLeaveButton));
      expect(width - rect.right, lessThanOrEqualTo(8));
      expect(rect.top, lessThan(80));
      expect(tester.takeException(), isNull);
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('managed roster shows RTC members and IM-only members together', (
    tester,
  ) async {
    final media = _FakeMediaSession(role: MediaRole.host);
    media._emit(
      media.snapshot.copyWith(
        participants: const [
          MediaParticipant(id: 'self', displayName: 'Host', isLocal: true),
          MediaParticipant(id: 'remote', displayName: 'Video Guest'),
        ],
      ),
    );
    final chat = _HostChatSession();
    final room = RealtimeRoom(
      media: MediaRoomSession.direct(
        roomCode: 'room-123',
        participantId: 'self',
        session: media,
      ),
      chat: chat,
      productChatRoom: ChatRoomSession(
        roomCode: 'room-123',
        participantId: 'self',
        userId: 'host',
        role: ChatRole.host,
        session: chat,
        moderation: _RosterModeration(),
      ),
      renderer: const _FakeRenderer(),
      disposeClients: () {},
    );
    addTearDown(room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeRoomUiScope(
          room: room,
          child: const Scaffold(body: RealtimeManagedParticipantList()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Video Guest'), findsOneWidget);
    expect(find.text('Chat Member'), findsOneWidget);
    expect(find.text('Participants (3)'), findsOneWidget);
    expect(find.textContaining('Chat online'), findsOneWidget);
    expect(find.byTooltip('Manage member'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('composable bulk mute retries only failed remote members', (
    tester,
  ) async {
    final media = _BulkMuteMediaSession();
    final room = _room(media);
    addTearDown(room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeRoomUiScope(
          room: room,
          child: const Scaffold(body: RealtimeBulkMuteButton()),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Mute all participants'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mute all'));
    await tester.pumpAndSettle();
    expect(media.muteTargets, ['a', 'b']);
    expect(find.byTooltip('Retry failed mutes'), findsOneWidget);
    await tester.tap(find.byTooltip('Retry failed mutes'));
    await tester.pumpAndSettle();
    expect(media.muteTargets, ['a', 'b', 'b']);
    expect(find.byTooltip('Retry failed mutes'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'composable actions share room snapshots and do not own session',
    (tester) async {
      final media = _FakeMediaSession();
      final room = _room(media);
      addTearDown(room.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: RealtimeRoomUiScope(
            room: room,
            child: const Scaffold(
              body: Column(
                children: [RealtimeMicrophoneButton(), RealtimeCameraButton()],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(RealtimeMicrophoneButton));
      await tester.pump();
      expect(media.muteCalls, 1);
      expect(media.snapshot.localMuted, false);
      await tester.tap(find.byType(RealtimeCameraButton));
      await tester.pump();
      expect(media.cameraCalls, 1);
      expect(media.snapshot.localVideoEnabled, true);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(media.disposeCalls, 0, reason: 'UI unmount must not end the call');
    },
  );

  testWidgets('broadcast stage renders the host, not audience members', (
    tester,
  ) async {
    final media = _FakeMediaSession(role: MediaRole.viewer);
    media._emit(
      media.snapshot.copyWith(
        participants: const [
          MediaParticipant(id: 'self', displayName: 'Viewer', isLocal: true),
          MediaParticipant(
            id: 'host',
            displayName: 'Broadcaster',
            isVideoEnabled: true,
          ),
          MediaParticipant(id: 'other', displayName: 'Another viewer'),
        ],
      ),
    );
    final room = _room(media);
    addTearDown(room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeRoomUiScope(
          room: room,
          child: const Scaffold(body: RealtimeLiveVideoStage()),
        ),
      ),
    );
    expect(find.byType(RealtimeVideoTile), findsOneWidget);
    final tile = tester.widget<RealtimeVideoTile>(
      find.byType(RealtimeVideoTile),
    );
    expect(tile.participant.id, 'host');
    expect(tile.showNameTag, isFalse);
    expect(tile.borderless, isTrue);
    expect(find.text('Broadcaster'), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeRoomUiScope(
          room: room,
          child: const Scaffold(
            body: RealtimeLiveVideoStage(showNameTag: true),
          ),
        ),
      ),
    );
    expect(find.text('Broadcaster'), findsOneWidget);
  });

  testWidgets('RealtimeHostToolsPanel renders host tools and extra tools', (
    tester,
  ) async {
    final media = _FakeMediaSession(role: MediaRole.host);
    final room = _room(media);
    addTearDown(room.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeRoomUiScope(
          room: room,
          child: const Scaffold(
            body: RealtimeHostToolsPanel(
              showHeader: true,
              extraTools: [Text('CustomRecordingTool')],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(RealtimeHostToolsPanel), findsOneWidget);
    expect(find.text('Host Tools'), findsOneWidget);
    expect(find.text('Switch Camera'), findsOneWidget);
    expect(find.text('Screen Share'), findsOneWidget);
    expect(find.text('Audio Output'), findsOneWidget);
    expect(find.text('CustomRecordingTool'), findsOneWidget);
  });

  testWidgets(
    'showRealtimeHostToolsBottomSheet opens and closes bottom sheet',
    (tester) async {
      final media = _FakeMediaSession(role: MediaRole.host);
      final room = _room(media);
      addTearDown(room.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showRealtimeHostToolsBottomSheet(
                  context,
                  room: room,
                  extraTools: const [Text('SheetExtraTool')],
                ),
                child: const Text('OpenHostTools'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('OpenHostTools'));
      await tester.pumpAndSettle();

      expect(find.byType(RealtimeHostToolsPanel), findsOneWidget);
      // Background capability guidance adds an item above extra tools.
      // Verify that host controls remain reachable through normal scrolling
      // rather than assuming every section fits the initial viewport.
      await tester.scrollUntilVisible(
        find.text('SheetExtraTool'),
        220,
        scrollable: find.descendant(
          of: find.byType(RealtimeHostToolsPanel),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('SheetExtraTool'), findsOneWidget);

      // Tap close button in header
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(RealtimeHostToolsPanel), findsNothing);
    },
  );

  testWidgets('chat widgets inside a media room share one chat subscription', (
    tester,
  ) async {
    final media = _FakeMediaSession();
    final chat = _FakeChatSession();
    final room = RealtimeRoom(
      media: MediaRoomSession.direct(
        roomCode: 'room-123',
        participantId: 'self',
        session: media,
      ),
      chat: chat,
      renderer: const _FakeRenderer(),
      disposeClients: () {},
    );
    addTearDown(room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeRoomUiScope(
          room: room,
          child: const Scaffold(
            body: Column(
              children: [
                Expanded(child: RealtimeChatPanel()),
                SizedBox(height: 65, child: RealtimeChatMessageList()),
              ],
            ),
          ),
        ),
      ),
    );
    expect(chat.listeners, 1);
    // Room chat names the audience above the composer like the reference.
    expect(find.text('To Everyone'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(chat.listeners, 0);
    expect(
      chat.disposed,
      isFalse,
      reason: 'Removing the UI must not dispose the chat session',
    );
  });

  testWidgets(
    'camera switches front/back and audio picker shows capabilities',
    (tester) async {
      final media = _FakeMediaSession();
      final room = _room(media);
      addTearDown(room.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: RealtimeRoomUiScope(
            room: room,
            child: const Scaffold(
              body: Column(
                children: [
                  RealtimeSwitchCameraButton(),
                  RealtimeAudioOutputButton(),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(RealtimeSwitchCameraButton));
      await tester.pump();
      await tester.tap(find.byType(RealtimeSwitchCameraButton));
      await tester.pump();
      expect(media.cameraPositions, [
        MediaCameraPosition.back,
        MediaCameraPosition.front,
      ]);
      await tester.tap(find.byType(RealtimeAudioOutputButton));
      await tester.pumpAndSettle();
      expect(find.text('Speaker'), findsOneWidget);
      expect(find.text('Selection unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('independent microphone/camera pickers select a device by kind', (
    tester,
  ) async {
    final media = _DeviceMediaSession();
    final room = _room(media);
    addTearDown(room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeRoomUiScope(
          room: room,
          child: const Scaffold(
            body: Column(
              children: [
                RealtimeMediaDevicePicker(kind: MediaDeviceKind.microphone),
                RealtimeMediaDevicePicker(kind: MediaDeviceKind.camera),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Microphone devices'));
    await tester.pumpAndSettle();
    expect(find.text('USB microphone'), findsOneWidget);
    await tester.tap(find.text('USB microphone'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Camera devices'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Front camera'));
    await tester.pumpAndSettle();
    expect(media.selected.map((device) => device.kind), [
      MediaDeviceKind.microphone,
      MediaDeviceKind.camera,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('connection indicator renders localized status pill', (
    tester,
  ) async {
    final media = _FakeMediaSession();
    final room = _room(media);
    addTearDown(room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeRoomUiScope(
          room: room,
          child: const Scaffold(body: RealtimeConnectionIndicator()),
        ),
      ),
    );
    await tester.pump();
    // Default fake session is connected; the pill must not use raw enum names.
    expect(find.text('Connected'), findsOneWidget);
    expect(find.byType(Chip), findsNothing);
    expect(find.byType(RealtimePill), findsOneWidget);

    media._emit(media.snapshot.copyWith(state: MediaSessionState.reconnecting));
    await tester.pump();
    await tester.pump();
    expect(find.text('Reconnecting'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('connection indicator localizes status in Chinese', (
    tester,
  ) async {
    final media = _FakeMediaSession();
    final room = _room(media);
    addTearDown(room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: RealtimeStrings.supportedLocales,
        localizationsDelegates: RealtimeStrings.localizationsDelegates,
        home: RealtimeRoomUiScope(
          room: room,
          child: const Scaffold(body: RealtimeConnectionIndicator()),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('已连接'), findsOneWidget);

    media._emit(media.snapshot.copyWith(state: MediaSessionState.reconnecting));
    await tester.pump();
    await tester.pump();
    expect(find.text('正在重新连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scope switches rooms without closing provider sessions', (
    tester,
  ) async {
    final firstMedia = _FakeMediaSession();
    final secondMedia = _FakeMediaSession();
    final first = _room(firstMedia);
    final second = _room(secondMedia);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    Widget page(RealtimeRoom room) => MaterialApp(
      home: RealtimeRoomUiScope(
        room: room,
        child: const Scaffold(body: RealtimeRoomInfo()),
      ),
    );
    await tester.pumpWidget(page(first));
    expect(firstMedia._snapshots.hasListener, isTrue);
    await tester.pumpWidget(page(second));
    await tester.pump();
    expect(firstMedia._snapshots.hasListener, isFalse);
    expect(firstMedia.disposeCalls, 0);
    expect(secondMedia._snapshots.hasListener, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(secondMedia._snapshots.hasListener, isFalse);
    expect(secondMedia.disposeCalls, 0);
  });

  test('pending microphone command coalesces duplicate calls', () async {
    final media = _DeferredMuteSession();
    final room = _room(media);
    addTearDown(room.dispose);
    final controller = RealtimeRoomUiController(room);
    final first = controller.toggleMicrophone();
    final duplicate = controller.toggleMicrophone();
    expect(controller.isPending(RealtimeRoomUiAction.microphone), isTrue);
    expect(media.muteCalls, 1);
    var duplicateDone = false;
    unawaited(duplicate.then((_) => duplicateDone = true));
    await pumpEventQueue();
    expect(
      duplicateDone,
      isFalse,
      reason: 'duplicate caller must wait for the in-flight provider action',
    );
    media.complete();
    await Future.wait([first, duplicate]);
    expect(duplicateDone, isTrue);
    expect(controller.isPending(RealtimeRoomUiAction.microphone), isFalse);
    controller.dispose();
    expect(media.disposeCalls, 0);
  });
}

class _FakeRealtimeVideoEffects implements RealtimeVideoEffects {
  final controller = _FakeVideoEffectsController();

  @override
  Future<bool> isSupported() async => true;
  @override
  Future<MediaLocalPreviewSession> createPreview({
    required String providerId,
    required MediaRole role,
  }) => throw UnimplementedError();
  @override
  RealtimeVideoEffectsController createController({
    required MediaRoomSession media,
    required MediaBackgroundCapabilities capabilities,
    required void Function(RealtimeException) reportError,
  }) => controller;
}

class _FakeVideoEffectsController implements RealtimeVideoEffectsController {
  MediaBackgroundEffect _effect = const MediaBackgroundEffect.none();

  @override
  MediaBackgroundCapabilities get backgroundCapabilities =>
      const MediaBackgroundCapabilities(canBlur: true);

  @override
  MediaBackgroundEffect get backgroundEffect => _effect;

  @override
  Future<void> setBackgroundEffect(MediaBackgroundEffect effect) async {
    _effect = effect;
  }

  @override
  Future<void> prepareVideoEffects(MediaLocalPreviewSettings settings) async {}
  @override
  Future<void> release() async {}
  @override
  void beginDisposal() {}
  @override
  Future<void> dispose() async {}
}

class _DeferredMuteSession extends _FakeMediaSession {
  final Completer<void> _ready = Completer<void>();
  void complete() => _ready.complete();
  @override
  Future<void> toggleMute() async {
    muteCalls++;
    await _ready.future;
    _emit(snapshot.copyWith(localMuted: !snapshot.localMuted));
  }
}

class _DeviceMediaSession extends _FakeMediaSession
    implements MediaDeviceController {
  _DeviceMediaSession() {
    _emit(
      snapshot.copyWith(
        capabilities: snapshot.capabilities.copyWith(
          canEnumerateMicrophones: true,
          canSelectMicrophone: true,
          canEnumerateCameras: true,
          canSelectCamera: true,
        ),
      ),
    );
  }
  final selected = <MediaDevice>[];
  @override
  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async => [
    if (kinds?.contains(MediaDeviceKind.microphone) ?? true)
      const MediaDevice(
        id: 'mic-usb',
        label: 'USB microphone',
        kind: MediaDeviceKind.microphone,
      ),
    if (kinds?.contains(MediaDeviceKind.camera) ?? true)
      const MediaDevice(
        id: 'cam-front',
        label: 'Front camera',
        kind: MediaDeviceKind.camera,
      ),
  ];
  @override
  Future<void> selectMediaDevice(MediaDevice device) async =>
      selected.add(device);
}

class _BulkMuteMediaSession extends _FakeMediaSession
    implements MediaRoomModeration {
  _BulkMuteMediaSession() : super(role: MediaRole.host) {
    _emit(
      snapshot.copyWith(
        capabilities: const MediaCapabilities(
          management: MediaManagementCapabilities(
            muteParticipant: ManagementCapability.client(),
          ),
        ),
        participants: const [
          MediaParticipant(id: 'self', displayName: 'Host', isLocal: true),
          MediaParticipant(id: 'a', displayName: 'A'),
          MediaParticipant(id: 'b', displayName: 'B'),
        ],
      ),
    );
  }
  final muteTargets = <String>[];
  bool _failBOnce = true;

  @override
  Future<void> muteParticipant(
    String roomCode, {
    required String requesterParticipantId,
    required String targetParticipantId,
    String? participantCredential,
    String? roomOwnerCredential,
  }) async {
    muteTargets.add(targetParticipantId);
    if (targetParticipantId == 'b' && _failBOnce) {
      _failBOnce = false;
      throw StateError('provider temporary failure');
    }
  }

  @override
  Future<List<MediaRoomParticipantSummary>> listParticipants(
    String roomCode, {
    required String requesterParticipantId,
    String? participantCredential,
    String? roomOwnerCredential,
  }) async => const [];

  @override
  Future<void> removeParticipant(
    String roomCode, {
    required String requesterParticipantId,
    required String targetParticipantId,
    String? participantCredential,
    String? roomOwnerCredential,
  }) async {}

  @override
  Future<void> stopParticipantVideo(
    String roomCode, {
    required String requesterParticipantId,
    required String targetParticipantId,
    String? participantCredential,
    String? roomOwnerCredential,
  }) async {}

  @override
  Future<void> changeParticipantRole(
    String roomCode, {
    required String requesterParticipantId,
    required String targetParticipantId,
    required MediaRole role,
    String? participantCredential,
    String? roomOwnerCredential,
  }) async {}

  @override
  Future<void> closeRoomManaged(
    String roomCode, {
    required String requesterParticipantId,
    String? participantCredential,
    String? roomOwnerCredential,
  }) async {}
}

class _BufferedChatSession extends _FakeChatSession {
  @override
  List<ChatMessage> get messages => List.generate(
    20,
    (index) => ChatMessage(
      id: '$index',
      userId: 'guest',
      message:
          'Live discussion message $index with enough text to use two lines',
      timestamp: DateTime(2026),
    ),
  );
}

class _HostChatSession extends _FakeChatSession {
  @override
  ChatRole get role => ChatRole.host;
}

class _RosterModeration extends Fake
    implements ChatModeration, ChatModerationCapabilitySource {
  @override
  ChatManagementCapabilities get moderationCapabilities =>
      const ChatManagementCapabilities(
        listMembers: ChatManagementCapability.backend(),
        removeMember: ChatManagementCapability.backend(),
      );
  @override
  Future<List<ChatMember>> listMembers() async => const [
    ChatMember(userId: 'chat-member', displayName: 'Chat Member'),
  ];
  @override
  Future<void> removeMember(String userId) async {}
}

RealtimeRoom _room(
  _FakeMediaSession media, {
  RealtimeVideoEffects? videoEffects,
  MediaBackgroundCapabilities effectsCapabilities =
      const MediaBackgroundCapabilities.none(),
}) => RealtimeRoom(
  media: MediaRoomSession.direct(
    roomCode: 'room-123',
    participantId: 'self',
    session: media,
  ),
  renderer: const _FakeRenderer(),
  videoEffects: videoEffects,
  effectsCapabilities: effectsCapabilities,
  disposeClients: () {},
);

class _FakeRenderer extends MediaTrackRenderer {
  const _FakeRenderer();
  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      const SizedBox.expand();
}

class _FakeMediaSession extends InteractiveMediaSession {
  _FakeMediaSession({this.role = MediaRole.participant});
  @override
  final MediaRole role;
  final _snapshots = StreamController<MediaSnapshot>.broadcast();
  final _states = StreamController<MediaSessionState>.broadcast();
  final _events = StreamController<MediaEvent>.broadcast();
  MediaSnapshot _snapshot = MediaSnapshot(
    state: MediaSessionState.connected,
    localMuted: true,
    capabilities: const MediaCapabilities.meeting(),
    participants: const [
      MediaParticipant(id: 'self', displayName: 'Local', isLocal: true),
    ],
  );
  int muteCalls = 0;
  int cameraCalls = 0;
  final cameraPositions = <MediaCameraPosition>[];
  int disposeCalls = 0;

  @override
  String get providerId => 'fake';
  @override
  @override
  MediaCapabilities get capabilities => snapshot.capabilities;
  @override
  MediaSessionState get state => snapshot.state;
  @override
  MediaSnapshot get snapshot => _snapshot;
  @override
  Stream<MediaSessionState> get states => _states.stream;
  @override
  Stream<MediaSnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<MediaEvent> get events => _events.stream;

  void _emit(MediaSnapshot snapshot) {
    _snapshot = snapshot;
    _snapshots.add(snapshot);
    _states.add(snapshot.state);
  }

  @override
  Future<void> join(MediaJoinInfo joinInfo) async {}
  @override
  Future<void> leave() async {}
  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _snapshots.close();
    await _states.close();
    await _events.close();
  }

  @override
  Future<void> setMuted(bool muted) async {
    muteCalls++;
    _emit(snapshot.copyWith(localMuted: muted));
  }

  @override
  Future<void> toggleMute() => setMuted(!snapshot.localMuted);
  @override
  Future<void> setVideoEnabled(bool enabled) async {
    cameraCalls++;
    _emit(snapshot.copyWith(localVideoEnabled: enabled));
  }

  @override
  Future<void> setScreenShareEnabled(bool enabled) async {
    _emit(snapshot.copyWith(localScreenShareEnabled: enabled));
  }

  @override
  Future<void> switchCamera(MediaCameraPosition position) async =>
      cameraPositions.add(position);
  @override
  Future<List<MediaAudioDevice>> listAudioDevices() async => const [
    MediaAudioDevice(label: 'Speaker', type: MediaAudioDeviceType.speaker),
  ];
  @override
  Future<void> selectAudioDevice(MediaAudioDevice device) async {}
  @override
  Future<void> sendMessage(String message, {String topic = 'chat'}) async {}
}

class _FakeChatSession extends Fake implements ChatSession {
  final _snapshots = StreamController<List<ChatMessage>>.broadcast();
  int listeners = 0;
  bool disposed = false;

  @override
  String get providerId => 'fake';
  @override
  ChatRole get role => ChatRole.participant;
  @override
  ChatConnectionState get state => ChatConnectionState.connected;
  @override
  ChatCapabilities get capabilities =>
      const ChatCapabilities(canSendMessage: true);
  @override
  List<ChatMessage> get messages => const [];
  @override
  Stream<List<ChatMessage>> get messageSnapshots => Stream.multi((controller) {
    listeners++;
    final subscription = _snapshots.stream.listen(controller.add);
    controller.onCancel = () async {
      listeners--;
      await subscription.cancel();
    };
  }, isBroadcast: true);
  @override
  Stream<ChatConnectionState> get states => const Stream.empty();
  @override
  Stream<ChatEvent> get events => const Stream.empty();
  @override
  Future<void> sendMessage(String message) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async {
    disposed = true;
    await _snapshots.close();
  }
}
