import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';

void main() {
  test(
    'RealtimeRoom unifies microphone, camera, screen-share, device and RTC data controls',
    () async {
      final session = _FakeInteractiveSession();
      final room = RealtimeRoom(
        media: MediaRoomSession.direct(
          roomCode: 'unified-room',
          participantId: 'user-1',
          session: session,
        ),
        renderer: const _NoopRenderer(),
        disposeClients: () {},
      );
      await room.initialize();

      expect(room.canUseMicrophone, isTrue);
      expect(room.canUseCamera, isTrue);
      expect(room.canShareScreen, isTrue);
      expect(room.canSelectScreenShareSource, isTrue);
      expect(room.canSwitchCamera, isTrue);
      expect(room.canSendRtcData, isTrue);

      await room.toggleMicrophone();
      expect(room.snapshot.localMuted, isFalse);

      await room.toggleCamera();
      expect(room.snapshot.localVideoEnabled, isTrue);

      final sources = await room.listScreenShareSources();
      expect(sources, hasLength(1));
      await room.toggleScreenShare(source: sources.single);
      expect(session.selectedSourceId, 'display-1');
      expect(room.snapshot.localScreenShareEnabled, isTrue);

      await room.switchCamera(MediaCameraPosition.back);
      expect(session.cameraPositions, [MediaCameraPosition.back]);

      final mics = await room.listMediaDevices(
        kinds: {MediaDeviceKind.microphone},
      );
      expect(mics, hasLength(1));
      await room.selectMediaDevice(mics.single);
      expect(session.selectedDeviceId, 'mic-1');

      await room.sendRtcData(
        'hello',
        options: const MediaSendOptions(topic: 'custom'),
      );
      expect(session.sentMessages, [('custom', 'hello')]);

      await room.leaveRoom(closeForEveryone: false);
      expect(room.isDisposed, isTrue);
    },
  );

  test(
    'RealtimeRoom screen-share rejects remote occupancy and unconfirmed provider state',
    () async {
      final session = _FakeInteractiveSession();
      final room = RealtimeRoom(
        media: MediaRoomSession.direct(
          roomCode: 'conflict-room',
          participantId: 'user-1',
          session: session,
        ),
        renderer: const _NoopRenderer(),
        disposeClients: () {},
      );
      await room.initialize();

      session.emit(
        session.snapshot.copyWith(
          participants: const [
            MediaParticipant(id: 'user-1', displayName: 'Self', isLocal: true),
            MediaParticipant(
              id: 'user-2',
              displayName: 'Remote',
              isLocal: false,
            ),
          ],
          contentShareTrack: const _FakeVideoTrack(
            id: 'screen-remote',
            participantId: 'user-2',
            isLocal: false,
            isScreenShare: true,
          ),
        ),
      );

      await expectLater(
        room.setScreenShareEnabled(true),
        throwsA(
          isA<RealtimeException>().having(
            (e) => e.code,
            'code',
            RealtimeErrorCode.roomConflict,
          ),
        ),
      );

      session.emit(
        session.snapshot.copyWith(
          participants: const [
            MediaParticipant(id: 'user-1', displayName: 'Self', isLocal: true),
          ],
          clearContentShareTrack: true,
        ),
      );
      session.ignoreScreenShareMutation = true;
      await expectLater(
        room.setScreenShareEnabled(true),
        throwsA(
          isA<RealtimeException>().having(
            (e) => e.code,
            'code',
            RealtimeErrorCode.providerError,
          ),
        ),
      );

      await room.dispose();
    },
  );

  test(
    'RealtimeRoom.leaveRoom stops active cloud recording before owner room close',
    () async {
      final session = _FakeInteractiveSession(role: MediaRole.host);
      final management = _FakeManagement();
      final cloud = _FakeCloudRecording();
      final room = RealtimeRoom(
        media: MediaRoomSession.attach(
          roomCode: 'recorded-room',
          participantId: 'host-1',
          session: session,
          management: management,
          presence: _FakePresence(),
          heartbeatInterval: Duration.zero,
        ),
        renderer: const _NoopRenderer(),
        cloudRecordingSession: cloud,
        disposeClients: () {},
      );
      await room.initialize();
      await room.startRecording();
      expect(room.recordingStatus, RecordingStatus.recording);

      await room.leaveRoom();
      expect(cloud.stopOrder, lessThan(management.closeOrder));
      expect(management.closeCalls, 1);
      expect(room.isDisposed, isTrue);
    },
  );

  test(
    'RealtimeRoom disables media controls in ended state and leaves idempotently even if backend returned 404',
    () async {
      final session = _FakeInteractiveSession(role: MediaRole.host);
      final management = _NotFoundManagement();
      final room = RealtimeRoom(
        media: MediaRoomSession.attach(
          roomCode: 'ended-room',
          participantId: 'host-1',
          session: session,
          management: management,
          presence: _FakePresence(),
          heartbeatInterval: Duration.zero,
        ),
        renderer: const _NoopRenderer(),
        disposeClients: () {},
      );
      await room.initialize();
      expect(room.canUseMicrophone, isTrue);
      expect(room.canUseCamera, isTrue);
      expect(room.canShareScreen, isTrue);

      session.emit(session.snapshot.copyWith(state: MediaSessionState.ended));
      expect(room.canUseMicrophone, isFalse);
      expect(room.canUseCamera, isFalse);
      expect(room.canShareScreen, isFalse);
      expect(room.canSendRtcData, isFalse);

      await room.leaveRoom();
      expect(room.isDisposed, isTrue);
    },
  );
}

class _NotFoundManagement extends _FakeManagement {
  @override
  Future<void> closeRoomManaged(
    String roomCode, {
    required String requesterParticipantId,
    String? participantCredential,
    String? roomOwnerCredential,
  }) async {
    throw const RealtimeException(
      code: RealtimeErrorCode.roomNotFound,
      statusCode: 404,
      message: 'Room already closed.',
    );
  }
}

int _orderSeq = 0;

class _FakeVideoTrack extends MediaVideoTrack {
  const _FakeVideoTrack({
    required this.id,
    required this.participantId,
    required this.isLocal,
    required this.isScreenShare,
  });

  @override
  final String id;

  @override
  final String participantId;

  @override
  final bool isLocal;

  @override
  final bool isScreenShare;

  @override
  int get width => 1280;

  @override
  int get height => 720;
}

class _NoopRenderer extends MediaTrackRenderer {
  const _NoopRenderer();
  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      const SizedBox.shrink();
}

class _FakePresence implements MediaRoomPresence {
  @override
  Future<void> heartbeat(String roomCode, {String? participantId}) async {}
  @override
  Future<void> leave(String roomCode, {String? participantId}) async {}
}

class _FakeManagement implements MediaRoomManagement {
  int closeCalls = 0;
  int closeOrder = 0;

  @override
  Future<void> closeRoomManaged(
    String roomCode, {
    required String requesterParticipantId,
    String? participantCredential,
    String? roomOwnerCredential,
  }) async {
    closeCalls++;
    closeOrder = ++_orderSeq;
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
}

class _FakeCloudRecording implements MediaCloudRecordingSession {
  int stopOrder = 0;

  @override
  Future<RecordingResult> startCloudRecording(RecordingOptions options) async =>
      RecordingResult(
        mode: RecordingMode.cloud,
        recordingId: 'rec-1',
        taskState: RecordingTaskState.recording,
      );

  @override
  Future<RecordingResult> stopCloudRecording() async {
    stopOrder = ++_orderSeq;
    return RecordingResult(
      mode: RecordingMode.cloud,
      recordingId: 'rec-1',
      taskState: RecordingTaskState.processing,
    );
  }

  @override
  Future<RecordingResult> queryCloudRecording() async => RecordingResult(
    mode: RecordingMode.cloud,
    recordingId: 'rec-1',
    taskState: RecordingTaskState.completed,
  );

  @override
  Future<Uri> cloudRecordingDownloadUrl() async =>
      Uri.parse('https://example.invalid/rec.mp4');

  @override
  void dispose() {}
}

class _FakeInteractiveSession extends InteractiveMediaSession
    implements MediaScreenShareSourceSelector, MediaDeviceController {
  _FakeInteractiveSession({this.role = MediaRole.participant});

  @override
  final MediaRole role;
  final _snapshots = StreamController<MediaSnapshot>.broadcast();
  final _states = StreamController<MediaSessionState>.broadcast();
  final _events = StreamController<MediaEvent>.broadcast();

  MediaSnapshot _snapshot = MediaSnapshot(
    state: MediaSessionState.connected,
    localMuted: true,
    capabilities: const MediaCapabilities.meeting().copyWith(
      canScreenShare: true,
      canEnumerateMicrophones: true,
      canSelectMicrophone: true,
    ),
    participants: const [
      MediaParticipant(id: 'user-1', displayName: 'Self', isLocal: true),
    ],
  );

  bool ignoreScreenShareMutation = false;
  String? selectedSourceId;
  String? selectedDeviceId;
  final cameraPositions = <MediaCameraPosition>[];
  final sentMessages = <(String, String)>[];

  @override
  String get providerId => 'fake';
  @override
  MediaCapabilities get capabilities => _snapshot.capabilities;
  @override
  MediaSessionState get state => _snapshot.state;
  @override
  MediaSnapshot get snapshot => _snapshot;
  @override
  Stream<MediaSessionState> get states => _states.stream;
  @override
  Stream<MediaSnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<MediaEvent> get events => _events.stream;

  void emit(MediaSnapshot next) {
    _snapshot = next;
    _snapshots.add(next);
    _states.add(next.state);
  }

  @override
  Future<void> join(MediaJoinInfo joinInfo) async {}
  @override
  Future<void> leave() async {}
  @override
  Future<void> dispose() async {
    await _snapshots.close();
    await _states.close();
    await _events.close();
  }

  @override
  Future<void> setMuted(bool muted) async =>
      emit(_snapshot.copyWith(localMuted: muted));

  @override
  Future<void> toggleMute() => setMuted(!_snapshot.localMuted);

  @override
  Future<void> setVideoEnabled(bool enabled) async =>
      emit(_snapshot.copyWith(localVideoEnabled: enabled));

  @override
  Future<void> setScreenShareEnabled(bool enabled) async {
    if (ignoreScreenShareMutation) return;
    emit(_snapshot.copyWith(localScreenShareEnabled: enabled));
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
  Future<void> sendMessage(String message, {String topic = 'chat'}) async =>
      sentMessages.add((topic, message));

  @override
  Future<List<MediaScreenShareSource>> listScreenShareSources() async => const [
    MediaScreenShareSource(
      id: 'display-1',
      name: 'Main Display',
      kind: MediaScreenShareSourceKind.display,
      primary: true,
    ),
  ];

  @override
  Future<void> selectScreenShareSource(MediaScreenShareSource source) async =>
      selectedSourceId = source.id;

  @override
  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async => const [
    MediaDevice(
      id: 'mic-1',
      label: 'Built-in Mic',
      kind: MediaDeviceKind.microphone,
    ),
  ];

  @override
  Future<void> selectMediaDevice(MediaDevice device) async =>
      selectedDeviceId = device.id;
}
