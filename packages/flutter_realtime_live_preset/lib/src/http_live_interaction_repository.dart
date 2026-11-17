import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:flutter_realtime_live_core/flutter_realtime_live_core.dart';

class HttpLiveInteractionRepository
    implements LiveInteractionRepository, LiveCohostRepository {
  HttpLiveInteractionRepository({
    required String backendUrl,
    required this.roomCode,
    required this.participantId,
    required this.participantCredential,
    this.tokenProvider,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 10),
  }) : _base = Uri.parse(backendUrl),
       _executor = RealtimeHttpExecutor(client: client);
  final Uri _base;
  final String roomCode, participantId, participantCredential;
  final FutureOr<String?> Function()? tokenProvider;
  final RealtimeHttpExecutor _executor;
  final Duration requestTimeout;
  Future<LiveInteractionState> _post(
    String operation,
    Map<String, Object?> data,
  ) async {
    final json = await _executor.request(
      method: 'POST',
      uri: _base.replace(
        path:
            '${_base.path.replaceFirst(RegExp(r"/$"), "")}/rooms/${Uri.encodeComponent(roomCode)}/live/$operation',
      ),
      timeout: requestTimeout,
      domain: 'live',
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
        ...data,
      },
    );
    return JsonReader(json).decode(() => LiveInteractionState.fromJson(json));
  }

  @override
  Future<LiveInteractionState> snapshot() => _post('snapshot', {});
  @override
  Future<LiveInteractionState> sendGift(
    String giftId,
    int quantity, {
    required String eventId,
  }) => _post('gift', {
    'giftId': giftId,
    'quantity': quantity,
    'eventId': eventId,
  });
  @override
  Future<LiveInteractionState> sendLike({required String eventId}) =>
      _post('like', {'eventId': eventId});
  @override
  Future<LiveInteractionState> requestCohost() => _post('cohost/request', {});
  @override
  Future<LiveInteractionState> cancelCohost() => _post('cohost/cancel', {});
  @override
  Future<LiveInteractionState> respondCohost(String userId, String action) =>
      _post('cohost/respond', {'userId': userId, 'action': action});
  @override
  void close() {
    _executor.close();
  }
}

/// Gifts are demonstration events; this contract does not debit money or points.
