part of 'media_room_session.dart';

typedef _ParticipantProfile = ({String displayName, String? avatarUrl});

/// Presentation-only hints bound to the transport sender, never permissions.
class _RoomParticipantProfiles {
  _RoomParticipantProfiles(
    this.session,
    this.participantId, {
    MediaIdentity? identity,
    required Map<String, dynamic> metadata,
    required this.reportError,
  }) : local = (
         displayName:
             identity?.displayName ?? metadata['displayName']?.toString() ?? '',
         avatarUrl: RealtimeAvatarUrl.tryParse(
           identity?.avatarUrl ?? metadata['avatarUrl']?.toString(),
         ),
       ) {
    final raw = metadata['participantProfiles'];
    if (raw is List<dynamic>) {
      for (final value in raw.take(512)) {
        if (value is! Map<String, dynamic>) continue;
        final id = value['participantId']?.toString().trim() ?? '';
        if (id.isEmpty) continue;
        _profiles[id] = (
          displayName: value['displayName']?.toString() ?? id,
          avatarUrl: RealtimeAvatarUrl.tryParse(value['avatarUrl']?.toString()),
        );
      }
    }
    _enabled =
        local.displayName.isNotEmpty ||
        local.avatarUrl != null ||
        _profiles.isNotEmpty;
    if (!_enabled) return;
    _snapshots = session.snapshots.listen(_onSnapshot);
    _profiles[participantId] = local;
    _events = session.events.listen(_onEvent);
    _schedulePublish();
  }

  static const _topic = 'realtime.profile.v1';
  MediaSession session;
  final String participantId;
  final void Function(RealtimeException) reportError;
  final _ParticipantProfile local;
  final _profiles = <String, _ParticipantProfile>{};
  late final StreamController<MediaSnapshot> _updates =
      StreamController<MediaSnapshot>.broadcast(
        sync: true,
        onListen: _ensureSnapshotSubscription,
        onCancel: _dropSnapshotSubscriptionWhenIdle,
      );
  bool _enabled = false;
  bool _disposed = false;
  String _memberIds = '';
  final _observedMembers = <String>{};
  Timer? _publishTimer;
  StreamSubscription<MediaSnapshot>? _snapshots;
  StreamSubscription<MediaEvent>? _events;
  Future<void>? _publishFuture;
  Future<void>? _disposeFuture;

  void _ensureSnapshotSubscription() {
    if (_disposed || _snapshots != null) return;
    _snapshots = session.snapshots.listen(_onSnapshot);
  }

  void _dropSnapshotSubscriptionWhenIdle() {
    if (_enabled || _updates.hasListener) return;
    unawaited(_snapshots?.cancel());
    _snapshots = null;
  }

  MediaSnapshot get snapshot => _decorate(session.snapshot);
  Stream<MediaSnapshot> get snapshots => _updates.stream;

  void rebindSession(MediaSession next) {
    session = next;
    final hadSnapshotSub = _snapshots != null || _updates.hasListener;
    unawaited(_snapshots?.cancel());
    _snapshots = null;
    unawaited(_events?.cancel());
    _events = null;
    if (_disposed) return;
    if (_enabled || hadSnapshotSub) {
      _snapshots = next.snapshots.listen(_onSnapshot);
    }
    if (_enabled) {
      _events = next.events.listen(_onEvent);
      _schedulePublish();
    }
    if (_updates.hasListener) {
      _updates.add(snapshot);
    }
  }

  MediaSnapshot _decorate(MediaSnapshot value) => !_enabled
      ? value
      : value.copyWith(
          participants: value.participants
              .map((member) {
                final profile =
                    member.isLocal || member.id == value.localParticipantId
                    ? local
                    : _profiles[member.id];
                if (profile == null) return member;
                return member.copyWith(
                  displayName: profile.displayName.trim().isEmpty
                      ? member.displayName
                      : profile.displayName,
                  avatarUrl: profile.avatarUrl ?? member.avatarUrl,
                );
              })
              .toList(growable: false),
        );

  void _onSnapshot(MediaSnapshot value) {
    if (_disposed) return;
    final ids = value.participants.map((p) => p.id).toList()..sort();
    final signature = jsonEncode(ids);
    _profiles.removeWhere(
      (id, _) =>
          id != participantId &&
          _observedMembers.contains(id) &&
          !ids.contains(id),
    );
    _observedMembers
      ..removeWhere((id) => !ids.contains(id))
      ..addAll(ids);
    if (_memberIds != signature) {
      _memberIds = signature;
      _schedulePublish();
    }
    _updates.add(_decorate(value));
  }

  void _onEvent(MediaEvent event) {
    if (_disposed ||
        event is! MediaMessageReceived ||
        event.message.topic != _topic) {
      return;
    }
    final incoming = event.message;
    if (incoming.message.length > 4096 ||
        incoming.participantId.isEmpty ||
        incoming.participantId == participantId) {
      return;
    }
    try {
      final json = jsonDecode(incoming.message);
      if (json is! Map<String, dynamic> ||
          json['v'] != 1 ||
          json['type'] != 'profile') {
        return;
      }
      // A payload cannot choose another participant's profile or role.
      if (!session.snapshot.participants.any(
        (p) => p.id == incoming.participantId,
      )) {
        return;
      }
      final name = json['displayName'];
      if (name is! String || name.length > 128) return;
      final avatar = RealtimeAvatarUrl.tryParse(
        json['avatarUrl'] is String ? json['avatarUrl'] as String : null,
      );
      if (_profiles.length >= 512 &&
          !_profiles.containsKey(incoming.participantId)) {
        return;
      }
      _profiles[incoming.participantId] = (
        displayName: name,
        avatarUrl: avatar,
      );
      _updates.add(snapshot);
    } on FormatException {
      // Untrusted malformed presentation hints do not affect the room.
    }
  }

  void _schedulePublish() {
    if (_disposed ||
        !session.capabilities.canSendData ||
        local.displayName.isEmpty) {
      return;
    }
    _publishTimer?.cancel();
    _publishTimer = Timer(
      const Duration(milliseconds: 100),
      () => unawaited(_publish()),
    );
  }

  Future<void> _publish() => _publishFuture ??= _sendProfile().whenComplete(
    () => _publishFuture = null,
  );
  Future<void> _sendProfile() async {
    if (_disposed || session.state != MediaSessionState.connected) return;
    try {
      await session.sendData(
        jsonEncode({
          'v': 1,
          'type': 'profile',
          'displayName': local.displayName,
          if (local.avatarUrl != null) 'avatarUrl': local.avatarUrl,
        }),
        options: const MediaSendOptions(topic: _topic),
      );
    } catch (error, stack) {
      if (!_disposed) {
        reportError(
          normalizeRealtimeException(
            error,
            domain: 'media.profile',
            operation: 'publish',
            stackTrace: stack,
          ),
        );
      }
    }
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();
  Future<void> _dispose() async {
    _disposed = true;
    _publishTimer?.cancel();
    final cleanup = Cleanup(timeout: const Duration(seconds: 5));
    await cleanup.run('profiles.snapshots', () async => _snapshots?.cancel());
    await cleanup.run('profiles.events', () async => _events?.cancel());
    await cleanup.run('profiles.publish', () async => _publishFuture);
    await cleanup.run('profiles.updates', _updates.close);
    cleanup.finish(domain: 'media.profile');
  }
}
