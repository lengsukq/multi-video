import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_realtime_whiteboard_core/flutter_realtime_whiteboard_core.dart';
import 'package:http/http.dart' as http;

import 'shared_content_command.dart';
import 'shared_content_repository.dart';

/// HTTP control-plane adapter for `/rooms/:code/content/*` (supports both
/// meeting and broadcast rooms without requiring a classroom session).
class HttpSharedContentRepository extends SharedContentRepository {
  HttpSharedContentRepository({
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
  final String roomCode;
  final String participantId;
  final String participantCredential;
  final String? roomOwnerCredential;
  final FutureOr<String?> Function()? tokenProvider;
  final RealtimeHttpExecutor _executor;
  final Duration requestTimeout;
  static final Random _secure = Random.secure();

  Uri _route(String operation) => _baseUri.replace(
    path:
        '${_baseUri.path.replaceFirst(RegExp(r'/$'), '')}/rooms/${Uri.encodeComponent(roomCode)}/content/$operation',
  );

  Future<SharedContentState?> _post(
    String operation,
    Map<String, Object?> data,
  ) async {
    final json = await _executor.request(
      method: 'POST',
      uri: _route(operation),
      timeout: requestTimeout,
      domain: 'sharedContent',
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
    return JsonReader(json).decode(() {
      final rawContent = json['content'];
      if (rawContent is! Map) return null;
      final content = SharedContentState.fromJson(
        Map<String, dynamic>.from(rawContent),
      );
      final topRev = JsonReader(json).optional<int>('revision');
      if (topRev == null || topRev == content.snapshotRevision) return content;
      return SharedContentState(
        mode: content.mode,
        whiteboard: content.whiteboard,
        screen: content.screen,
        canManage: content.canManage,
        canShareScreen: content.canShareScreen,
        canAnnotateScreen: content.canAnnotateScreen,
        revision: content.revision,
        snapshotRevision: topRev,
      );
    });
  }

  @override
  Future<SharedContentState?> snapshot() => _post('snapshot', const {});

  @override
  Future<SharedContentState?> action(SharedContentCommand command) {
    final board = command.whiteboard;
    final wireAction = board != null
        ? 'tool.whiteboard.${board.action.wireName}'
        : 'tool.${command.action!.wireName}';
    final wirePayload = board != null ? board.payload : command.payload;
    final eventId =
        board?.eventId ??
        '${DateTime.now().microsecondsSinceEpoch}-${_secure.nextInt(0x100000000)}';
    return _post('action', {
      'action': wireAction,
      'payload': jsonEncode(wirePayload),
      'eventId': eventId,
    });
  }

  @override
  void close() {
    _executor.close();
  }
}
