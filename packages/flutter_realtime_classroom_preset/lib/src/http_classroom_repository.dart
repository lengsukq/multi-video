import 'dart:async';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:flutter_realtime_classroom_core/flutter_realtime_classroom_core.dart';

/// This is a control-plane fallback: no websocket infrastructure is required.
/// A future IM/RTC event adapter can call refresh() to deliver updates sooner.
class HttpClassroomRepository implements ClassroomRepository {
  HttpClassroomRepository({
    required String backendUrl,
    required this.roomCode,
    required this.participantId,
    required this.participantCredential,
    this.roomOwnerCredential,
    this.tokenProvider,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 10),
  }) : _baseUri = Uri.parse(backendUrl),
       _executor = RealtimeHttpExecutor(client: client);
  final Uri _baseUri;
  final String roomCode, participantId, participantCredential;
  final String? roomOwnerCredential;
  final FutureOr<String?> Function()? tokenProvider;
  final RealtimeHttpExecutor _executor;
  final Duration requestTimeout;
  static final Random _secure = Random.secure();
  Uri _route(String operation) => _baseUri.replace(
    path:
        '${_baseUri.path.replaceFirst(RegExp(r'/$'), '')}/rooms/${Uri.encodeComponent(roomCode)}/classroom/$operation',
  );
  Future<ClassroomState> _post(
    String operation,
    Map<String, Object?> data,
  ) async {
    final json = await _executor.request(
      method: 'POST',
      uri: _route(operation),
      timeout: requestTimeout,
      domain: 'classroom',
      headers: () async {
        final bearer = await tokenProvider?.call();
        return {
          'Content-Type': 'application/json',
          if (bearer != null && bearer.isNotEmpty)
            'Authorization': 'Bearer $bearer',
        };
      },
      body: {
        'requesterParticipantId': participantId,
        'participantCredential': participantCredential,
        if (roomOwnerCredential != null)
          'roomOwnerCredential': roomOwnerCredential,
        ...data,
      },
    );
    return JsonReader(json).decode(() => ClassroomState.fromJson(json));
  }

  @override
  Future<ClassroomState> snapshot() => _post('snapshot', const {});
  @override
  Future<ClassroomState> action(ClassroomCommand command) => _post('action', {
    'action': command.wireName,
    // A unique id is generated once per logical action, allowing the same
    // HTTP request body to be retried without applying the action twice.
    // Use a literal: Dart Web evaluates (1 << 32) as zero in JavaScript,
    // causing Random.nextInt(0) to throw before the HTTP action is sent.
    'eventId':
        '${DateTime.now().microsecondsSinceEpoch}-${_secure.nextInt(0x100000000)}',
    ...command.toWireData(),
  });
  @override
  void close() {
    _executor.close();
  }
}
