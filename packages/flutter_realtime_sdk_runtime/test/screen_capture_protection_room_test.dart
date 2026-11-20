import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'preventScreenCapture defaults to false and acquires no lease',
    () async {
      final protection = _FakeScreenProtection();
      final media = _FakeMediaSession();
      final room = RealtimeRoom(
        media: MediaRoomSession.direct(
          roomCode: 'room-default',
          participantId: 'u1',
          session: media,
        ),
        renderer: const _NoopRenderer(),
        screenCaptureProtection: protection,
        disposeClients: () {},
      );
      await room.initialize();

      expect(room.preventScreenCapture, isFalse);
      expect(room.isScreenCaptured, isFalse);
      expect(protection.activeLeases, isEmpty);

      await room.dispose();
    },
  );

  test('Realtime(preventScreenCapture: true) propagates to room, emits events, '
      'exempts local screen sharing, and releases on dispose', () async {
    final protection = _FakeScreenProtection(initiallyCaptured: false);
    final media = _FakeMediaSession();
    final realtime = Realtime(
      providers: <RealtimeProviderBundle>[
        RealtimeProviderBundle(
          webAssetsLoader:
              ({
                Iterable<String> mediaProviderIds = const [],
                bool includeProductChat = false,
                bool includeAllMediaProviders = false,
              }) async {},
          drivers: <RealtimeProviderDriver>[
            RealtimeProviderDriver(
              platforms: RealtimeRuntimePlatform.values.toSet(),
              publicProviderId: 'fake',
              mediaRoomModes: const {MediaRoomMode.meeting},
              plugin: RealtimeProviderPlugin(
                id: 'fake',
                metadata: const RealtimeProviderMetadata(displayName: 'Fake'),
                mediaFactory: _FakeMediaFactory(media),
                renderer: const _NoopRenderer(),
              ),
            ),
          ],
        ),
      ],
      preventScreenCapture: true,
      services: RealtimeRoomServices(screenCaptureProtection: protection),
    );
    expect(realtime.preventScreenCapture, isTrue);

    final connection = await realtime.open(
      RealtimeRequest.join(
        type: RealtimeExperience.meeting,
        roomCode: 'room-1',
        user: const RealtimeUser(id: 'u1', name: 'Alice'),
        source: RealtimeSource.credentials(
          media: RealtimeCredentials(
            providerId: 'fake',
            payload: const <String, Object?>{},
          ),
        ),
      ),
    );
    final room = connection.mediaRoom!;
    await room.initialize();

    expect(room.preventScreenCapture, isTrue);
    expect(protection.activeLeases, hasLength(1));
    expect(room.isScreenCaptured, isFalse);

    final streamChanges = <bool>[];
    final roomEvents = <RealtimeScreenCaptureChanged>[];
    final sub1 = room.screenCaptureChanges.listen(streamChanges.add);
    final sub2 = room.events.listen((event) {
      if (event is RealtimeScreenCaptureChanged) {
        roomEvents.add(event);
      }
    });

    // External OS screen recording starts -> room reports captured = true.
    protection.setCaptured(true);
    await Future<void>.delayed(Duration.zero);
    expect(room.isScreenCaptured, isTrue);
    expect(streamChanges, <bool>[true]);
    expect(roomEvents.single.isCaptured, isTrue);

    // Local in-app screen share turns on -> suspends secure window and
    // exempts local sharing from external capture alert.
    media.setLocalScreenSharing(true);
    await Future<void>.delayed(Duration.zero);
    expect(protection.activeLeases.single.suspended, isTrue);
    expect(room.isScreenCaptured, isFalse);
    expect(streamChanges, <bool>[true, false]);

    // External OS screen recording stops while local share stops -> clears cleanly.
    protection.setCaptured(false);
    media.setLocalScreenSharing(false);
    await Future<void>.delayed(Duration.zero);
    expect(protection.activeLeases.single.suspended, isFalse);
    expect(room.isScreenCaptured, isFalse);
    expect(streamChanges, <bool>[true, false]);

    await sub1.cancel();
    await sub2.cancel();
    await connection.dispose();
    expect(protection.activeLeases, isEmpty);
  });

  test('in-app screen share picker startup gap and ReplayKit stop tail never '
      'trigger false-positive screen capture alerts', () async {
    final protection = _FakeScreenProtection(initiallyCaptured: false);
    final pickerPublishCompleter = Completer<void>();
    late final _FakeMediaSession media;
    media = _FakeMediaSession(
      onSetScreenShareEnabled: (enabled) async {
        if (enabled) {
          // Simulate Android FLAG_SECURE already suspended BEFORE vendor
          // MediaProjection / ReplayKit picker runs.
          expect(protection.activeLeases.single.suspended, isTrue);
          // Simulate iOS ReplayKit firing UIScreen.isCaptured = true right
          // after user taps "Start Broadcast", BEFORE RTC track publishes.
          protection.setCaptured(true);
          await pickerPublishCompleter.future;
          media.setLocalScreenSharing(true);
        } else {
          // Simulate local track stopping slightly BEFORE OS ReplayKit
          // finishes tearing down UIScreen.isCaptured.
          media.setLocalScreenSharing(false);
        }
      },
    );
    final room = RealtimeRoom(
      media: MediaRoomSession.direct(
        roomCode: 'no-false-positive',
        participantId: 'u1',
        session: media,
      ),
      renderer: const _NoopRenderer(),
      preventScreenCapture: true,
      screenCaptureProtection: protection,
      disposeClients: () {},
    );
    await room.initialize();

    final observedAlerts = <bool>[];
    final sub = room.screenCaptureChanges.listen(observedAlerts.add);

    // Start local screen share: OS capture fires during picker gap.
    final startingFuture = room.setScreenShareEnabled(true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(room.isScreenCaptured, isFalse);
    expect(observedAlerts, isEmpty);

    // Vendor finishes publishing screen track.
    pickerPublishCompleter.complete();
    await startingFuture;
    expect(room.isScreenCaptured, isFalse);
    expect(observedAlerts, isEmpty);

    // Stop local screen share: OS capture lingers 100ms before clearing.
    await room.setScreenShareEnabled(false);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(room.isScreenCaptured, isFalse);
    expect(observedAlerts, isEmpty);

    protection.setCaptured(false);
    await Future<void>.delayed(Duration.zero);
    expect(protection.activeLeases.single.suspended, isFalse);
    expect(room.isScreenCaptured, isFalse);
    expect(observedAlerts, isEmpty);

    await sub.cancel();
    await room.dispose();
  });

  test(
    'RealtimeChatRoom inherits preventScreenCapture and releases on dispose',
    () async {
      final protection = _FakeScreenProtection(initiallyCaptured: false);
      final chatSession = _FakeChatSession();
      final chatRoom = RealtimeChatRoom(
        room: ChatRoomSession(
          roomCode: 'chat-1',
          participantId: 'u1',
          userId: 'u1',
          role: ChatRole.participant,
          session: chatSession,
        ),
        disposeClient: () {},
        preventScreenCapture: true,
        screenCaptureProtection: protection,
      );
      await Future<void>.delayed(Duration.zero);

      expect(chatRoom.preventScreenCapture, isTrue);
      expect(protection.activeLeases, hasLength(1));
      expect(chatRoom.isScreenCaptured, isFalse);

      protection.setCaptured(true);
      await Future<void>.delayed(Duration.zero);
      expect(chatRoom.isScreenCaptured, isTrue);

      await chatRoom.dispose();
      expect(protection.activeLeases, isEmpty);
      expect(chatRoom.isScreenCaptured, isFalse);
    },
  );

  test(
    'RealtimeClient inherits room-wide preventScreenCapture from backend metadata even when local setting is false',
    () async {
      final protection = _FakeScreenProtection(initiallyCaptured: false);
      final session = _FakeMediaSession();
      final client = RealtimeClient(
        mediaAdapters: RealtimeMediaAdapters([
          RealtimeMediaAdapter(
            sessionFactory: _FakeMediaFactory(session),
            renderer: const _NoopRenderer(),
          ),
        ]),
        preventScreenCapture: false,
        screenCaptureProtection: protection,
      );
      final mediaClient = client.newMediaClient();
      final roomSession = MediaRoomSession.direct(
        roomCode: 'sec-room-1',
        participantId: 'u2',
        session: session,
        backendMetadata: const {'preventScreenCapture': true},
      );

      final room = await client.adopt(mediaClient, roomSession);
      await room.initialize();
      expect(room.preventScreenCapture, isTrue);
      expect(protection.activeLeases, hasLength(1));

      await room.dispose();
      expect(protection.activeLeases, isEmpty);
    },
  );
}

final class _FakeScreenProtection implements ScreenCaptureProtectionService {
  _FakeScreenProtection({this.initiallyCaptured = false})
    : _captured = initiallyCaptured;

  final bool initiallyCaptured;
  bool _captured;
  final List<_FakeLease> activeLeases = <_FakeLease>[];
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
  }) async {
    final lease = _FakeLease(this, suspended: suspendSecureWindow);
    activeLeases.add(lease);
    return lease;
  }
}

final class _FakeLease implements ScreenCaptureProtectionLease {
  _FakeLease(this.owner, {required this.suspended});

  final _FakeScreenProtection owner;
  bool suspended;
  bool released = false;

  @override
  bool get isCaptured => !released && owner._captured;

  @override
  Stream<bool> get changes => owner._changes.stream.where((_) => !released);

  @override
  Future<bool> refresh() async => isCaptured;

  @override
  Future<void> setSuspendSecureWindow(bool suspend) async {
    suspended = suspend;
  }

  @override
  Future<void> release() async {
    released = true;
    owner.activeLeases.remove(this);
  }
}

final class _FakeMediaFactory extends Fake implements MediaSessionFactory {
  _FakeMediaFactory(this.session);
  final _FakeMediaSession session;

  @override
  String get providerId => 'fake';

  @override
  Set<MediaRole> get supportedRoles => const {
    MediaRole.participant,
    MediaRole.host,
    MediaRole.viewer,
  };

  @override
  MediaJoinInfo parseJoinInfo(Map<String, dynamic> raw) => _FakeJoinInfo();

  @override
  MediaSession createSession(MediaJoinInfo joinInfo) => session;
}

final class _FakeJoinInfo extends MediaJoinInfo {
  _FakeJoinInfo()
    : super(
        providerId: 'fake',
        roomCode: 'room-1',
        participantId: 'u1',
        role: MediaRole.participant,
      );
}

final class _FakeMediaSession extends Fake implements InteractiveMediaSession {
  _FakeMediaSession({this.onSetScreenShareEnabled});

  final Future<void> Function(bool enabled)? onSetScreenShareEnabled;
  MediaSnapshot _snapshot = MediaSnapshot(
    state: MediaSessionState.connected,
    capabilities: const MediaCapabilities(
      canPublishAudio: true,
      canPublishVideo: true,
      canScreenShare: true,
      canSubscribeVideo: true,
    ),
  );
  final StreamController<MediaSnapshot> _snapshots =
      StreamController<MediaSnapshot>.broadcast();

  void setLocalScreenSharing(bool sharing) {
    _snapshot = MediaSnapshot(
      state: MediaSessionState.connected,
      capabilities: capabilities,
      localScreenShareEnabled: sharing,
    );
    _snapshots.add(_snapshot);
  }

  @override
  Future<void> setScreenShareEnabled(bool enabled) async {
    if (onSetScreenShareEnabled != null) {
      await onSetScreenShareEnabled!(enabled);
      return;
    }
    setLocalScreenSharing(enabled);
  }

  @override
  String get providerId => 'fake';

  @override
  MediaRole get role => MediaRole.participant;

  @override
  MediaSessionState get state => MediaSessionState.connected;

  @override
  MediaCapabilities get capabilities => const MediaCapabilities(
    canPublishAudio: true,
    canPublishVideo: true,
    canScreenShare: true,
    canSubscribeVideo: true,
  );

  @override
  MediaSnapshot get snapshot => _snapshot;

  @override
  Stream<MediaEvent> get events => const Stream<MediaEvent>.empty();

  @override
  Stream<MediaSessionState> get states =>
      const Stream<MediaSessionState>.empty();

  @override
  Stream<MediaSnapshot> get snapshots => _snapshots.stream;

  @override
  Future<void> join(MediaJoinInfo joinInfo) async {}

  @override
  Future<void> leave() async {}

  @override
  Future<void> dispose() async {
    await _snapshots.close();
  }
}

final class _FakeChatSession extends Fake implements ChatSession {
  @override
  String get providerId => 'fake-chat';

  @override
  ChatRole get role => ChatRole.participant;

  @override
  ChatConnectionState get state => ChatConnectionState.connected;

  @override
  ChatCapabilities get capabilities => const ChatCapabilities();

  @override
  Stream<ChatConnectionState> get states =>
      const Stream<ChatConnectionState>.empty();

  @override
  Stream<ChatEvent> get events => const Stream<ChatEvent>.empty();

  @override
  Future<void> dispose() async {}
}

final class _NoopRenderer extends MediaTrackRenderer {
  const _NoopRenderer();

  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      const SizedBox.shrink();
}
