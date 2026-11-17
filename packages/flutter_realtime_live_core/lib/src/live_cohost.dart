import 'package:flutter_realtime_foundation/flutter_realtime_foundation.dart';

enum LiveCohostStatus { none, requested, approved, active, declined }

class LiveCohostRequest {
  const LiveCohostRequest({
    required this.userId,
    required this.participantId,
    required this.displayName,
    required this.status,
    required this.requestedAt,
  });

  final String userId;
  final String participantId;
  final String displayName;
  final LiveCohostStatus status;
  final String requestedAt;

  factory LiveCohostRequest.fromJson(Map<String, dynamic> value) {
    final reader = JsonReader(value);
    return LiveCohostRequest(
      userId: reader.required<String>('userId'),
      participantId:
          reader.optional<String>('participantId') ??
          reader.required<String>('userId'),
      displayName:
          reader.optional<String>('displayName') ??
          reader.required<String>('userId'),
      status:
          LiveCohostStatus.values
              .where((item) => item.name == reader.optional<String>('status'))
              .firstOrNull ??
          LiveCohostStatus.requested,
      requestedAt: reader.optional<String>('requestedAt') ?? '',
    );
  }
}

class LiveCohostMember {
  const LiveCohostMember({
    required this.userId,
    required this.participantId,
    required this.displayName,
  });

  final String userId;
  final String participantId;
  final String displayName;

  factory LiveCohostMember.fromJson(Map<String, dynamic> value) {
    final reader = JsonReader(value);
    return LiveCohostMember(
      userId: reader.required<String>('userId'),
      participantId:
          reader.optional<String>('participantId') ??
          reader.required<String>('userId'),
      displayName:
          reader.optional<String>('displayName') ??
          reader.required<String>('userId'),
    );
  }
}
