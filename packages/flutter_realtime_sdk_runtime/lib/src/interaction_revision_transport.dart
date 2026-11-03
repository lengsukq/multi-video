import 'dart:convert';
import 'dart:math';

import 'package:flutter_realtime_chat_core/flutter_realtime_chat_core.dart';
import 'package:flutter_realtime_interaction_core/flutter_realtime_interaction_core.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

/// Same bounded system-envelope shape already recognized by Chat adapters.
/// No business command or payload is carried by this invalidation message.
class InteractionRevisionHintCodec {
  const InteractionRevisionHintCodec._();

  static const eventType = 'interaction.state.changed';
  static const mediaTopic = 'realtime.interaction.revision.v1';
  static final _random = Random.secure();

  static String encode(
    String roomCode,
    int revision, {
    String type = eventType,
  }) {
    if (roomCode.isEmpty ||
        roomCode.length > 128 ||
        revision < 0 ||
        revision > 9007199254740991) {
      throw ArgumentError('Invalid revision hint');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    return jsonEncode({
      'v': 1,
      'type': type,
      'roomCode': roomCode,
      'eventId': '$now-${_random.nextInt(0x100000000)}',
      'revision': revision,
      'timestampMs': now,
    });
  }

  /// A hint is untrusted even if it parses successfully. Consumers fetch the
  /// authoritative snapshot and must not apply revision/payload as state.
  static int? decode(
    String raw, {
    required String roomCode,
    String expectedType = eventType,
  }) {
    if (raw.length > 1024) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic> ||
          json['v'] != 1 ||
          json['type'] != expectedType ||
          json['roomCode'] != roomCode ||
          json['eventId'] is! String ||
          (json['eventId'] as String).isEmpty ||
          (json['eventId'] as String).length > 128 ||
          json['revision'] is! int ||
          json['timestampMs'] is! int) {
        return null;
      }
      final revision = json['revision'] as int;
      final now = DateTime.now().millisecondsSinceEpoch;
      final sent = json['timestampMs'] as int;
      if (revision < 0 ||
          revision > 9007199254740991 ||
          (now - sent).abs() > const Duration(minutes: 5).inMilliseconds) {
        return null;
      }
      return revision;
    } on FormatException {
      return null;
    }
  }
}

/// Product IM carries only snapshot invalidation, never arbitrary event data:
/// ChatSystemMessaging deliberately does not expose authenticated sender IDs.
class ChatInteractionRevisionTransport implements InteractionRevisionTransport {
  const ChatInteractionRevisionTransport(
    this.chat, {
    required this.roomCode,
    this.eventType = InteractionRevisionHintCodec.eventType,
  });

  final ChatSystemMessaging chat;
  final String roomCode;
  final String eventType;

  @override
  Stream<int> get revisions => chat.systemMessages
      .map(
        (raw) => InteractionRevisionHintCodec.decode(
          raw,
          roomCode: roomCode,
          expectedType: eventType,
        ),
      )
      .where((revision) => revision != null)
      .cast<int>();

  @override
  Future<void> publish(int revision) => chat.sendSystemMessage(
    InteractionRevisionHintCodec.encode(roomCode, revision, type: eventType),
  );

  @override
  Future<void> dispose() async {}
}

/// RTC Data fallback for snapshot invalidation only. Does not own the session.
class MediaInteractionRevisionTransport
    implements InteractionRevisionTransport {
  const MediaInteractionRevisionTransport(
    this.media, {
    required this.roomCode,
    this.eventType = InteractionRevisionHintCodec.eventType,
    this.topic = InteractionRevisionHintCodec.mediaTopic,
  });

  final MediaSession media;
  final String roomCode;
  final String eventType;
  final String topic;

  @override
  Stream<int> get revisions => media.dataMessages
      .where((message) => message.topic == topic)
      .map(
        (message) => InteractionRevisionHintCodec.decode(
          message.message,
          roomCode: roomCode,
          expectedType: eventType,
        ),
      )
      .where((revision) => revision != null)
      .cast<int>();

  @override
  Future<void> publish(int revision) => media.sendData(
    InteractionRevisionHintCodec.encode(roomCode, revision, type: eventType),
    options: MediaSendOptions(topic: topic),
  );

  @override
  Future<void> dispose() async {}
}
