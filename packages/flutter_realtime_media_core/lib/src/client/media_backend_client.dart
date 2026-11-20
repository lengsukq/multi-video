import '../model/media_role.dart';
import '../model/media_room_mode.dart';
import '../model/media_meeting_mode.dart';
import '../model/media_room_participant_summary.dart';
import '../model/media_room_summary.dart';
import 'media_backend_config.dart';
import 'media_backend_error.dart';
import 'media_backend_transport.dart';
import '../session/media_room_extensions.dart';
import 'media_room_services.dart';

/// Contract version implemented by this client.
const int mediaBackendContractVersion = 1;

/// Request header carrying the contract version.
const String mediaBackendContractHeader = 'X-Media-Backend-Contract';

/// Provider id assumed when a backend response omits `provider`.
///
/// Chime backends written against the original v1 contract send `meeting` and
/// `attendee` without a provider field; treating those as `chime` keeps them
/// working unchanged.
const String defaultMediaProviderId = 'chime';

/// Raw join response returned by the backend.
///
/// The provider payload is kept as JSON so the matching adapter can parse it;
/// the core layer only interprets the fields every provider shares.
class MediaRoomJoinResponse {
  const MediaRoomJoinResponse({
    required this.roomCode,
    required this.providerId,
    required this.role,
    required this.json,
  });

  final String roomCode;
  final String providerId;
  final MediaRole role;

  /// Full decoded response body, passed to `MediaSessionFactory.parseJoinInfo`.
  final Map<String, dynamic> json;

  @override
  String toString() =>
      'MediaRoomJoinResponse($providerId, room: $roomCode, '
      'role: ${role.wireName})';
}

/// HTTP implementation of the provider-neutral backend contract.
///
/// See `MEDIA_BACKEND_CONTRACT.md`. A compatible backend may be written in any
/// stack; it only has to implement the documented HTTP endpoints.
class MediaBackendClient
    implements MediaRoomPresence, MediaRoomManagement, MediaRoomDiscovery {
  MediaBackendClient(this.config, {MediaBackendTransport? transport})
    : _transport = transport,
      _executor = RealtimeHttpExecutor(),
      _ownsTransport = transport == null;

  final MediaBackendConfig config;
  final MediaBackendTransport? _transport;
  final RealtimeHttpExecutor _executor;
  final bool _ownsTransport;
  bool _disposed = false;

  /// Whether this client owns (and will close) its transport.
  bool get ownsTransport => _ownsTransport;

  /// Reads the provider-neutral backend health endpoint without creating a room.
  Future<Map<String, dynamic>> health() => _request('GET', '/health');

  /// Returns lightweight discoverable rooms without participant identity data.
  @override
  Future<List<MediaRoomSummary>> listRooms() async {
    final data = await _request('GET', '/rooms/discover');
    final rawRooms = data['rooms'];
    if (rawRooms == null) return const [];
    if (rawRooms is! List) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidResponse,
        message: 'Backend room discovery response has an invalid rooms field.',
      );
    }
    return rawRooms
        .whereType<Map<Object?, Object?>>()
        .map(
          (room) => MediaRoomSummary.fromJson(Map<String, dynamic>.from(room)),
        )
        .where((room) => room.roomCode.isNotEmpty && room.providerId.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<void> closeRoomManaged(
    String roomCode, {
    required String requesterParticipantId,
    String? participantCredential,
    String? roomOwnerCredential,
  }) => closeRoomAsParticipant(
    roomCode,
    requesterParticipantId: requesterParticipantId,
    participantCredential: participantCredential,
    roomOwnerCredential: roomOwnerCredential,
  );

  @override
  Future<void> removeParticipant(
    String roomCode, {
    required String requesterParticipantId,
    required String targetParticipantId,
    String? participantCredential,
    String? roomOwnerCredential,
  }) => removeRoomParticipant(
    roomCode,
    requesterParticipantId: requesterParticipantId,
    targetParticipantId: targetParticipantId,
    participantCredential: participantCredential,
    roomOwnerCredential: roomOwnerCredential,
  );

  @override
  Future<List<MediaRoomParticipantSummary>> listParticipants(
    String roomCode, {
    required String requesterParticipantId,
    String? participantCredential,
    String? roomOwnerCredential,
  }) => listRoomParticipants(
    roomCode,
    requesterParticipantId: requesterParticipantId,
    participantCredential: participantCredential,
    roomOwnerCredential: roomOwnerCredential,
  );

  Future<List<MediaRoomParticipantSummary>> listRoomParticipants(
    String roomCode, {
    required String requesterParticipantId,
    String? participantCredential,
    String? roomOwnerCredential,
  }) async {
    final code = _required(roomCode, 'roomCode');
    final requester = _required(
      requesterParticipantId,
      'requesterParticipantId',
    );
    final data =
        await _post('/rooms/${Uri.encodeComponent(code)}/participants', {
          'requesterParticipantId': requester,
          if (participantCredential != null &&
              participantCredential.trim().isNotEmpty)
            'participantCredential': participantCredential.trim(),
          if (roomOwnerCredential != null &&
              roomOwnerCredential.trim().isNotEmpty)
            'roomOwnerCredential': roomOwnerCredential.trim(),
        });
    final raw = data['participants'];
    if (raw is! List) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidResponse,
        message: 'Backend participant response is malformed.',
      );
    }
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(
          (item) => MediaRoomParticipantSummary.fromJson(
            Map<String, dynamic>.from(item),
          ),
        )
        .where((item) => item.participantId.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> removeRoomParticipant(
    String roomCode, {
    required String requesterParticipantId,
    required String targetParticipantId,
    String? participantCredential,
    String? roomOwnerCredential,
  }) async {
    final code = _required(roomCode, 'roomCode');
    await _post('/rooms/${Uri.encodeComponent(code)}/participants/remove', {
      'requesterParticipantId': _required(
        requesterParticipantId,
        'requesterParticipantId',
      ),
      'targetParticipantId': _required(
        targetParticipantId,
        'targetParticipantId',
      ),
      if (participantCredential != null &&
          participantCredential.trim().isNotEmpty)
        'participantCredential': participantCredential.trim(),
      if (roomOwnerCredential != null && roomOwnerCredential.trim().isNotEmpty)
        'roomOwnerCredential': roomOwnerCredential.trim(),
    });
  }

  Future<void> closeRoomAsParticipant(
    String roomCode, {
    required String requesterParticipantId,
    String? participantCredential,
    String? roomOwnerCredential,
  }) async {
    final code = _required(roomCode, 'roomCode');
    await _post('/rooms/${Uri.encodeComponent(code)}/close', {
      'requesterParticipantId': _required(
        requesterParticipantId,
        'requesterParticipantId',
      ),
      if (participantCredential != null &&
          participantCredential.trim().isNotEmpty)
        'participantCredential': participantCredential.trim(),
      if (roomOwnerCredential != null && roomOwnerCredential.trim().isNotEmpty)
        'roomOwnerCredential': roomOwnerCredential.trim(),
    });
  }

  Future<MediaRoomJoinResponse> createRoom({
    required MediaRole role,
    String? roomCode,
    required String nickname,
    String? deviceId,
  }) async {
    final body = <String, Object?>{
      'nickname': _required(nickname, 'nickname'),
      'role': role.wireName,
    };
    final normalizedDeviceId = deviceId?.trim();
    if (normalizedDeviceId != null && normalizedDeviceId.isNotEmpty) {
      body['deviceId'] = normalizedDeviceId;
    }
    final normalizedCode = roomCode?.trim();
    if (normalizedCode != null && normalizedCode.isNotEmpty) {
      body['roomCode'] = normalizedCode;
    }
    final data = await _post('/rooms', body);
    return _parseJoinResponse(data, role: role);
  }

  Future<MediaRoomJoinResponse> joinRoomWithIdentity({
    required String roomCode,
    required String userId,
    required String displayName,
    String? deviceId,
    String? avatarUrl,
    String? roomOwnerCredential,
    MediaRole? role,
  }) async {
    final code = _required(roomCode, 'roomCode');
    final data = await _post('/rooms/${Uri.encodeComponent(code)}/join', {
      'userId': _required(userId, 'userId'),
      'displayName': _required(displayName, 'displayName'),
      if (avatarUrl != null) 'avatarUrl': avatarUrl,
      if (role != null) 'role': role.wireName,
      if (deviceId != null && deviceId.trim().isNotEmpty)
        'deviceId': deviceId.trim(),
      if (roomOwnerCredential != null && roomOwnerCredential.trim().isNotEmpty)
        'roomOwnerCredential': roomOwnerCredential.trim(),
    });
    // Joining cannot grant the caller's requested role. The server assigns
    // authority from room policy and credentials; absent role fails closed to
    // ordinary participant rather than inventing broadcaster privileges.
    return _parseJoinResponse(data, fallbackRoomCode: code);
  }

  Future<MediaRoomJoinResponse> createRoomWithIdentity({
    String? roomCode,
    required String userId,
    required String displayName,
    String? deviceId,
    String? avatarUrl,
    MediaRoomMode roomMode = MediaRoomMode.meeting,
    MediaMeetingMode? meetingMode,
    bool? preventScreenCapture,
    MediaRole? role,
  }) async {
    final body = <String, Object?>{
      'userId': _required(userId, 'userId'),
      'displayName': _required(displayName, 'displayName'),
      'nickname': displayName.trim(),
      if (avatarUrl != null) 'avatarUrl': avatarUrl,
      'roomMode': roomMode.wireName,
      if (meetingMode != null) 'meetingMode': meetingMode.name,
      if (preventScreenCapture == true) 'preventScreenCapture': true,
      if (role != null) 'role': role.wireName,
      if (deviceId != null && deviceId.trim().isNotEmpty)
        'deviceId': deviceId.trim(),
      if (roomCode != null && roomCode.trim().isNotEmpty)
        'roomCode': roomCode.trim(),
    };
    return _parseJoinResponse(await _post('/rooms', body), role: role);
  }

  Future<MediaRoomJoinResponse> joinRoom({
    required MediaRole role,
    required String roomCode,
    required String nickname,
    String? deviceId,
    String? roomOwnerCredential,
  }) async {
    final code = _required(roomCode, 'roomCode');
    final data = await _post('/rooms/${Uri.encodeComponent(code)}/join', {
      'userId': _required(nickname, 'nickname'),
      'role': role.wireName,
      if (deviceId != null && deviceId.trim().isNotEmpty)
        'deviceId': deviceId.trim(),
      if (roomOwnerCredential != null && roomOwnerCredential.trim().isNotEmpty)
        'roomOwnerCredential': roomOwnerCredential.trim(),
    });
    // Legacy join requests may include 'host', but its presence in the
    // request is not proof that the backend issued broadcaster credentials.
    return _parseJoinResponse(data, fallbackRoomCode: code);
  }

  /// Requests replacement provider credentials for an existing participant.
  ///
  /// The backend must preserve the room, provider, participant id, and role.
  Future<MediaRoomJoinResponse> refreshCredentials({
    required String roomCode,
    required String participantId,
    required MediaRole role,
    String? participantCredential,
  }) async {
    final code = _required(roomCode, 'roomCode');
    final data =
        await _post('/rooms/${Uri.encodeComponent(code)}/credentials/refresh', {
          'participantId': _required(participantId, 'participantId'),
          'role': role.wireName,
          if (participantCredential != null &&
              participantCredential.trim().isNotEmpty)
            'participantCredential': participantCredential.trim(),
        });
    return _parseJoinResponse(data, role: role, fallbackRoomCode: code);
  }

  /// Acquires or revokes an auxiliary publishing credential (e.g. `#content`).
  Future<Map<String, dynamic>> auxiliaryMediaToken({
    required String roomCode,
    required String participantId,
    required String action,
    String? participantCredential,
  }) async {
    final code = _required(roomCode, 'roomCode');
    return _post('/rooms/${Uri.encodeComponent(code)}/media/auxiliary-token', {
      'participantId': _required(participantId, 'participantId'),
      'action': action,
      if (participantCredential != null &&
          participantCredential.trim().isNotEmpty)
        'participantCredential': participantCredential.trim(),
    });
  }

  @override
  Future<void> heartbeat(String roomCode, {String? participantId}) async {
    final code = _required(roomCode, 'roomCode');
    await _post('/rooms/${Uri.encodeComponent(code)}/heartbeat', {
      if (participantId != null && participantId.trim().isNotEmpty)
        'participantId': participantId.trim(),
    });
  }

  @override
  Future<void> leave(String roomCode, {String? participantId}) async {
    final code = _required(roomCode, 'roomCode');
    await _post('/rooms/${Uri.encodeComponent(code)}/leave', {
      if (participantId != null && participantId.trim().isNotEmpty)
        'participantId': participantId.trim(),
    });
  }

  Future<void> closeRoom(String roomCode) async {
    final code = _required(roomCode, 'roomCode');
    await _request('DELETE', '/rooms/${Uri.encodeComponent(code)}');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _executor.close();
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, Object?> body) =>
      _request('POST', path, body: body);

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    if (_disposed) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'The backend client is closed.',
      );
    }
    final transport = _transport;
    final data = await _executor.request(
      method: method,
      uri: _uri(path),
      timeout: config.requestTimeout,
      domain: 'media',
      headers: _headers,
      body: body,
      transport: transport == null
          ? null
          : (headers, body, abort) async {
              try {
                final response = await transport.send(
                  method: method,
                  uri: _uri(path),
                  headers: headers,
                  body: body,
                );
                return (response.statusCode, response.body);
              } on MediaBackendTransportException catch (error) {
                throw RealtimeException(
                  code: error.unsupportedPlatform
                      ? RealtimeErrorCode.unsupportedPlatform
                      : RealtimeErrorCode.network,
                  message: error.message,
                  cause: error,
                  domain: 'media',
                );
              }
            },
    );
    _validateContractVersion(data);
    return data;
  }

  Future<Map<String, String>> _headers() async {
    final headers = <String, String>{};
    final custom = await config.headersProvider?.call();
    if (custom != null) headers.addAll(custom);
    headers['Accept'] = 'application/json';
    headers['Content-Type'] = 'application/json';
    headers[mediaBackendContractHeader] = '$mediaBackendContractVersion';
    final token = (await config.tokenProvider?.call())?.trim();
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Uri _uri(String path) {
    final base = config.backendUrl.toString().replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse('$base$path');
  }

  void _validateContractVersion(Map<String, dynamic> data) {
    final value = data['contractVersion'];
    if (value == null) return;
    final parsed = value is num
        ? value.toInt()
        : int.tryParse(value.toString());
    if (parsed != mediaBackendContractVersion) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidResponse,
        message:
            'Backend response uses unsupported contract version '
            '${value.toString()}.',
        details: value,
      );
    }
  }

  MediaRoomJoinResponse _parseJoinResponse(
    Map<String, dynamic> data, {
    MediaRole? role,
    String? fallbackRoomCode,
  }) {
    final roomCode = data['roomCode']?.toString().trim();
    final resolvedRoomCode = roomCode == null || roomCode.isEmpty
        ? fallbackRoomCode?.trim()
        : roomCode;
    if (resolvedRoomCode == null || resolvedRoomCode.isEmpty) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidResponse,
        message: 'Backend response is missing roomCode.',
      );
    }
    final publicProviderId =
        data['provider']?.toString().trim().toLowerCase() ?? '';
    final engineId = data['engine']?.toString().trim().toLowerCase() ?? '';
    // Vendor-aware backends may expose provider=aws while retaining the
    // concrete adapter id in engine. Older backends continue to work because
    // they only return provider.
    final providerId = engineId.isNotEmpty ? engineId : publicProviderId;
    final resolvedRole =
        MediaRole.tryParse(data['role']) ?? role ?? MediaRole.participant;
    return MediaRoomJoinResponse(
      roomCode: resolvedRoomCode,
      providerId: providerId.isEmpty ? defaultMediaProviderId : providerId,
      role: resolvedRole,
      json: data,
    );
  }

  String _required(String value, String name) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: '$name must not be empty.',
      );
    }
    return normalized;
  }
}
