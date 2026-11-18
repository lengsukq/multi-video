import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'RealtimeRoomView displays Chinese blocking alert on external capture, '
    'exempts local screen sharing, and auto-dismisses when stopped',
    (tester) async {
      final protection = _TestProtection();
      final media = _TestMediaSession();
      final room = RealtimeRoom(
        media: MediaRoomSession.direct(
          roomCode: 'guard-meeting',
          participantId: 'u1',
          session: media,
        ),
        renderer: const _ProbeOcclusionRenderer(),
        preventScreenCapture: true,
        screenCaptureProtection: protection,
        disposeClients: () {},
      );
      addTearDown(() {
        if (!room.isDisposed) return room.dispose();
      });

      var left = false;
      await tester.pumpWidget(
        MaterialApp(
          home: RealtimeStringsScope(
            strings: const RealtimeStrings.zh(),
            child: RealtimeRoomView(room: room, onLeave: () => left = true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially not captured -> no alert.
      expect(
        find.byKey(const ValueKey('realtime-screen-capture-alert')),
        findsNothing,
      );

      // External screen recording starts -> blocking alert appears immediately.
      protection.setCaptured(true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('realtime-screen-capture-alert')),
        findsOneWidget,
      );
      expect(find.text('检测到录屏或投屏'), findsOneWidget);
      expect(find.text('请关闭录屏或投屏功能后继续使用。'), findsOneWidget);

      // Local in-room screen share turns on -> alert suppresses automatically.
      media.setLocalScreenShare(true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('realtime-screen-capture-alert')),
        findsNothing,
      );

      // OS screen recording stops -> alert stays dismissed.
      protection.setCaptured(false);
      media.setLocalScreenShare(false);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('realtime-screen-capture-alert')),
        findsNothing,
      );
      expect(left, isFalse);

      // Leaving from the blocking alert disposes the room and triggers onLeave.
      protection.setCaptured(true);
      await tester.pumpAndSettle();
      await _tapLeaveAndDrain(tester, () => left);
      expect(room.isDisposed, isTrue);
      expect(left, isTrue);
    },
  );

  testWidgets(
    'RealtimeLivePage respects SDK preventScreenCapture parameter and occludes stage',
    (tester) async {
      final protection = _TestProtection(initiallyCaptured: true);
      final media = _TestMediaSession(role: MediaRole.viewer);
      final room = RealtimeRoom(
        media: MediaRoomSession.direct(
          roomCode: 'guard-live',
          participantId: 'viewer-1',
          session: media,
        ),
        renderer: const _ProbeOcclusionRenderer(),
        preventScreenCapture: true,
        screenCaptureProtection: protection,
        disposeClients: () {},
      );
      addTearDown(() {
        if (!room.isDisposed) return room.dispose();
      });

      await tester.pumpWidget(MaterialApp(home: RealtimeLivePage(room: room)));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('realtime-screen-capture-alert')),
        findsOneWidget,
      );
      expect(
        find.text('Screen Recording or Mirroring Detected'),
        findsOneWidget,
      );

      protection.setCaptured(false);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('realtime-screen-capture-alert')),
        findsNothing,
      );
      await tester.runAsync(room.dispose);
    },
  );

  testWidgets(
    'RealtimeChatPage displays blocking alert when standalone chat room detects external capture',
    (tester) async {
      final protection = _TestProtection(initiallyCaptured: false);
      final chatRoom = RealtimeChatRoom(
        room: ChatRoomSession(
          roomCode: 'guard-chat',
          participantId: 'u1',
          userId: 'u1',
          role: ChatRole.participant,
          session: _TestChatSession(),
        ),
        disposeClient: () {},
        preventScreenCapture: true,
        screenCaptureProtection: protection,
      );
      addTearDown(() {
        if (!chatRoom.isDisposed) return chatRoom.dispose();
      });

      var backedOut = false;
      await tester.pumpWidget(
        MaterialApp(
          home: RealtimeStringsScope(
            strings: const RealtimeStrings.zh(),
            child: RealtimeChatPage(
              chatRoom: chatRoom,
              onBack: () => backedOut = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('realtime-screen-capture-alert')),
        findsNothing,
      );

      protection.setCaptured(true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('realtime-screen-capture-alert')),
        findsOneWidget,
      );
      expect(find.text('检测到录屏或投屏'), findsOneWidget);

      protection.setCaptured(false);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('realtime-screen-capture-alert')),
        findsNothing,
      );

      protection.setCaptured(true);
      await tester.pumpAndSettle();
      await _tapLeaveAndDrain(tester, () => backedOut);
      expect(chatRoom.isDisposed, isTrue);
      expect(backedOut, isTrue);
    },
  );
}

Future<void> _tapLeaveAndDrain(
  WidgetTester tester,
  bool Function() isDone,
) async {
  await tester.tap(find.byKey(const ValueKey('realtime-screen-capture-leave')));
  // Broadcast stream subscription cancellations settle on the real event loop
  // rather than FakeAsync alone, so interleave short real waits with pumps.
  for (var i = 0; i < 15 && !isDone(); i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await tester.pumpAndSettle();
}

final class _TestProtection implements ScreenCaptureProtectionService {
  _TestProtection({bool initiallyCaptured = false})
    : _captured = initiallyCaptured;

  bool _captured;
  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  @override
  bool get isSupportedPlatform => true;

  void setCaptured(bool value) {
    _captured = value;
    _changes.add(value);
  }

  @override
  Future<ScreenCaptureProtectionLease> acquire({
    bool suspendSecureWindow = false,
  }) async => _TestLease(this);
}

final class _TestLease implements ScreenCaptureProtectionLease {
  _TestLease(this.owner);
  final _TestProtection owner;
  bool _released = false;

  @override
  bool get isCaptured => !_released && owner._captured;

  @override
  Stream<bool> get changes => owner._changes.stream.where((_) => !_released);

  @override
  Future<bool> refresh() async => isCaptured;

  @override
  Future<void> setSuspendSecureWindow(bool suspend) async {}

  @override
  Future<void> release() async {
    _released = true;
  }
}

final class _TestMediaSession extends Fake implements InteractiveMediaSession {
  _TestMediaSession({this.role = MediaRole.participant});

  @override
  final MediaRole role;

  final StreamController<MediaSnapshot> _snapshots =
      StreamController<MediaSnapshot>.broadcast();
  bool _localScreenSharing = false;

  void setLocalScreenShare(bool value) {
    _localScreenSharing = value;
    _snapshots.add(snapshot);
  }

  @override
  String get providerId => 'test';

  @override
  MediaSessionState get state => MediaSessionState.connected;

  @override
  MediaCapabilities get capabilities => const MediaCapabilities.meeting();

  @override
  MediaSnapshot get snapshot => MediaSnapshot(
    state: MediaSessionState.connected,
    capabilities: capabilities,
    localScreenShareEnabled: _localScreenSharing,
  );

  @override
  Stream<MediaEvent> get events => const Stream<MediaEvent>.empty();

  @override
  Stream<MediaSessionState> get states =>
      const Stream<MediaSessionState>.empty();

  @override
  Stream<MediaSnapshot> get snapshots => _snapshots.stream;

  @override
  Future<void> leave() async {}

  @override
  Future<void> dispose() async {
    await _snapshots.close();
  }
}

final class _TestChatSession extends Fake implements ChatSession {
  @override
  String get providerId => 'test-chat';

  @override
  ChatRole get role => ChatRole.participant;

  @override
  ChatConnectionState get state => ChatConnectionState.connected;

  @override
  ChatCapabilities get capabilities => const ChatCapabilities();

  @override
  List<ChatMessage> get messages => const <ChatMessage>[];

  @override
  Stream<ChatConnectionState> get states =>
      const Stream<ChatConnectionState>.empty();

  @override
  Stream<List<ChatMessage>> get messageSnapshots =>
      const Stream<List<ChatMessage>>.empty();

  @override
  Stream<ChatEvent> get events => const Stream<ChatEvent>.empty();

  @override
  Future<void> dispose() async {}
}

final class _ProbeOcclusionRenderer extends MediaTrackRenderer {
  const _ProbeOcclusionRenderer();

  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      const SizedBox.shrink();
}
