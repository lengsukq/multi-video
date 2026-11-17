part of 'media_room_session.dart';

class _RoomManagement {
  _RoomManagement({
    required this.session,
    required this.management,
    required this.roomCode,
    required this.participantId,
    required this.participantCredential,
    required this.roomOwnerCredential,
    required this.backendMetadata,
  });
  MediaSession session;
  final MediaRoomManagement? management;
  final String roomCode;
  final String participantId;
  final String? participantCredential;
  final String? roomOwnerCredential;
  final Map<String, dynamic> backendMetadata;
  String get providerId => session.providerId;
  MediaRole get role => session.role;
  MediaRoomManagement executor(
    ManagementCapability capability,
    String operation,
  ) {
    if (!capability.supported) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message:
            'Cannot $operation because the active provider does not support it.',
        providerId: providerId,
      );
    }
    if (capability.canExecuteOnClient && session is MediaRoomManagement) {
      return session as MediaRoomManagement;
    }
    return _requireManagement(operation);
  }

  MediaRoomModeration _moderationExecutor(
    ManagementCapability capability,
    String operation,
  ) {
    if (!capability.supported) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message:
            'Cannot $operation because the active provider does not support it.',
        providerId: providerId,
      );
    }
    if (capability.canExecuteOnClient && session is MediaRoomModeration) {
      return session as MediaRoomModeration;
    }
    return _requireModeration(operation);
  }

  bool get isLogicalOwner =>
      (roomOwnerCredential?.trim().isNotEmpty ?? false) ||
      role == MediaRole.host;

  bool _backendManagementFlag(String key, {required bool fallback}) {
    final raw = backendMetadata['management'];
    if (raw is! Map) return fallback;
    final value = raw[key];
    return value is bool ? value : fallback;
  }

  MediaManagementCapabilities get capabilities {
    final client = session.capabilities.managementCapabilities;
    if (!isLogicalOwner || management == null) return client;
    ManagementCapability preferClient(
      ManagementCapability clientCapability, {
      required String backendKey,
      required bool backendFallback,
    }) {
      if (clientCapability.supported) return clientCapability;
      return _backendManagementFlag(backendKey, fallback: backendFallback)
          ? const ManagementCapability.backend()
          : clientCapability;
    }

    return MediaManagementCapabilities(
      listParticipants: preferClient(
        client.listParticipants,
        backendKey: 'listParticipants',
        backendFallback: true,
      ),
      removeParticipant: preferClient(
        client.removeParticipant,
        backendKey: 'removeParticipant',
        backendFallback: false,
      ),
      muteParticipant: client.muteParticipant,
      stopParticipantVideo: client.stopParticipantVideo,
      changeParticipantRole: client.changeParticipantRole,
      closeRoom: preferClient(
        client.closeRoom,
        backendKey: 'closeRoom',
        backendFallback: true,
      ),
    );
  }

  /// Lists sanitized logical room participants. The backend remains the
  /// authority and rejects callers without room-management permission.
  Future<List<MediaRoomParticipantSummary>> listParticipants() =>
      executor(
        capabilities.listParticipants,
        'list room participants',
      ).listParticipants(
        roomCode,
        requesterParticipantId: participantId,
        participantCredential: participantCredential,
        roomOwnerCredential: roomOwnerCredential,
      );

  Future<void> muteParticipant(String targetParticipantId) =>
      _moderationExecutor(
        capabilities.muteParticipant,
        'mute room participants',
      ).muteParticipant(
        roomCode,
        requesterParticipantId: participantId,
        targetParticipantId: targetParticipantId,
        participantCredential: participantCredential,
        roomOwnerCredential: roomOwnerCredential,
      );

  Future<void> stopParticipantVideo(String targetParticipantId) =>
      _moderationExecutor(
        capabilities.stopParticipantVideo,
        'stop participant video',
      ).stopParticipantVideo(
        roomCode,
        requesterParticipantId: participantId,
        targetParticipantId: targetParticipantId,
        participantCredential: participantCredential,
        roomOwnerCredential: roomOwnerCredential,
      );

  Future<void> changeParticipantRole(
    String targetParticipantId,
    MediaRole role,
  ) =>
      _moderationExecutor(
        capabilities.changeParticipantRole,
        'change participant role',
      ).changeParticipantRole(
        roomCode,
        requesterParticipantId: participantId,
        targetParticipantId: targetParticipantId,
        role: role,
        participantCredential: participantCredential,
        roomOwnerCredential: roomOwnerCredential,
      );

  /// Removes a participant when the backend/provider supports true moderation.
  Future<void> removeParticipant(String targetParticipantId) =>
      executor(
        capabilities.removeParticipant,
        'remove room participants',
      ).removeParticipant(
        roomCode,
        requesterParticipantId: participantId,
        targetParticipantId: targetParticipantId,
        participantCredential: participantCredential,
        roomOwnerCredential: roomOwnerCredential,
      );
  MediaRoomManagement _requireManagement(String operation) {
    final management = this.management;
    if (management != null) return management;
    throw RealtimeException(
      code: RealtimeErrorCode.unsupportedFeature,
      message:
          'Cannot $operation because this room was joined without a room '
          'management executor.',
      providerId: providerId,
    );
  }

  MediaRoomModeration _requireModeration(String operation) {
    final management = this.management;
    if (management is MediaRoomModeration) return management;
    throw RealtimeException(
      code: RealtimeErrorCode.unsupportedFeature,
      message:
          'Cannot $operation because this room has no advanced moderation executor.',
      providerId: providerId,
    );
  }
}
