import 'dart:async';

import 'package:flutter_aws_chime/flutter_aws_chime.dart' as chime;

class FakeChimeMeetingSession extends chime.ChimeMeetingSession {
  chime.MeetingSnapshot _snapshot = chime.MeetingSnapshot();
  final _snapshotController =
      StreamController<chime.MeetingSnapshot>.broadcast();
  final _stateController = StreamController<chime.MeetingState>.broadcast();
  final _eventController = StreamController<chime.ChimeEvent>.broadcast();

  final List<String> actions = <String>[];
  bool disposed = false;

  @override
  chime.MeetingSnapshot get snapshot => _snapshot;

  @override
  chime.MeetingState get state => _snapshot.state;

  @override
  Stream<chime.MeetingSnapshot> get snapshots => _snapshotController.stream;

  @override
  Stream<chime.MeetingState> get states => _stateController.stream;

  @override
  Stream<chime.ChimeEvent> get events => _eventController.stream;

  @override
  Future<void> join(chime.JoinInfo joinInfo) async {
    actions.add('join');
    _replace(
      chime.MeetingSnapshot(
        state: chime.MeetingState.connected,
        localAttendeeId: joinInfo.attendee.attendeeId,
        attendees: [
          chime.MeetingAttendee(
            attendeeId: joinInfo.attendee.attendeeId,
            externalUserId: joinInfo.attendee.externalUserId,
            isLocal: true,
            isMuted: true,
            joinedAt: DateTime.fromMillisecondsSinceEpoch(1000),
          ),
        ],
      ),
    );
  }

  @override
  Future<void> leave() async {
    actions.add('leave');
    _replace(chime.MeetingSnapshot(state: chime.MeetingState.ended));
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    actions.add('dispose');
    _replace(chime.MeetingSnapshot(state: chime.MeetingState.disposed));
    await _snapshotController.close();
    await _stateController.close();
    await _eventController.close();
  }

  @override
  Future<void> setMuted(bool muted) async {
    actions.add('muted:$muted');
    final attendees = _snapshot.attendees
        .map((item) => item.isLocal ? item.copyWith(isMuted: muted) : item)
        .toList(growable: false);
    _replace(_snapshot.copyWith(localMuted: muted, attendees: attendees));
  }

  @override
  Future<void> toggleMute() => setMuted(!_snapshot.localMuted);

  @override
  Future<void> setVideoEnabled(bool enabled) async {
    actions.add('video:$enabled');
    final attendees = _snapshot.attendees
        .map(
          (item) =>
              item.isLocal ? item.copyWith(isVideoEnabled: enabled) : item,
        )
        .toList(growable: false);
    _replace(
      _snapshot.copyWith(localVideoEnabled: enabled, attendees: attendees),
    );
  }

  @override
  Future<void> switchCamera(chime.CameraPosition position) async {
    actions.add('camera:${position.name}');
  }

  @override
  Future<List<chime.ChimeAudioDevice>> listAudioDevices() async {
    actions.add('listAudioDevices');
    return [chime.ChimeAudioDevice.fromLabel('Speaker')];
  }

  @override
  Future<void> selectAudioDevice(chime.ChimeAudioDevice device) async {
    actions.add('audio:${device.label}');
  }

  @override
  Future<List<Map<String, dynamic>>> listDesktopMediaDevices() async {
    actions.add('listDesktopMediaDevices');
    return const [
      {'id': 'cam-builtin', 'label': 'FaceTime HD Camera', 'kind': 'camera'},
      {'id': 'cam-usb', 'label': 'External 4K Webcam', 'kind': 'camera'},
      {
        'id': 'mic-builtin',
        'label': 'MacBook Pro Microphone',
        'kind': 'microphone',
      },
    ];
  }

  @override
  Future<void> selectDesktopMediaDevice({
    required String id,
    required String label,
    required String kind,
  }) async {
    actions.add('selectDesktopMediaDevice:$kind:$id');
  }

  @override
  Future<List<Map<String, dynamic>>> listScreenShareSources() async {
    actions.add('listScreenShareSources');
    return const [
      {'id': 'display:1', 'name': 'Main Display', 'kind': 'display'},
      {'id': 'window:42', 'name': 'Notes', 'kind': 'window'},
    ];
  }

  @override
  Future<void> selectScreenShareSource({
    required String id,
    required String name,
    required String kind,
  }) async {
    actions.add('selectScreenShareSource:$id');
  }

  @override
  Future<void> setScreenShareEnabled(bool enabled) async {
    actions.add('screen:$enabled');
  }

  @override
  Future<void> sendMessage(
    String message, {
    String topic = 'chat',
    int lifetimeMs = 300000,
  }) async {
    actions.add('message:$topic:$message');
    final local = _snapshot.localAttendee;
    if (local == null) return;
    _replace(
      _snapshot.copyWith(
        messages: [
          ..._snapshot.messages,
          chime.MeetingMessage(
            attendeeId: local.attendeeId,
            externalUserId: local.externalUserId,
            message: message,
            topic: topic,
            timestampMs: 1234,
          ),
        ],
      ),
    );
  }

  void emitRemoteParticipant({
    required String id,
    required String name,
    bool muted = false,
    chime.MeetingVideoTile? videoTile,
  }) {
    final attendees = [
      ..._snapshot.attendees.where((item) => item.attendeeId != id),
      chime.MeetingAttendee(
        attendeeId: id,
        externalUserId: name,
        isMuted: muted,
        isVideoEnabled: videoTile != null,
        videoTile: videoTile,
        joinedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      ),
    ];
    _replace(_snapshot.copyWith(attendees: attendees));
  }

  void removeParticipant(String id) {
    _replace(
      _snapshot.copyWith(
        attendees: _snapshot.attendees
            .where((item) => item.attendeeId != id)
            .toList(growable: false),
      ),
    );
  }

  void emitVolume(String attendeeId, chime.MeetingVolumeLevel level) {
    _eventController.add(
      chime.AttendeeVolumeEvent(
        attendeeId: attendeeId,
        externalUserId: attendeeId,
        volumeLevel: level,
      ),
    );
  }

  void _replace(chime.MeetingSnapshot value) {
    final stateChanged = value.state != _snapshot.state;
    _snapshot = value;
    if (!_snapshotController.isClosed) _snapshotController.add(value);
    if (stateChanged && !_stateController.isClosed) {
      _stateController.add(value.state);
    }
  }
}
