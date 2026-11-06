import 'realtime_video_effects.dart';
import 'realtime_room_services.dart';
import 'http_cloud_recording_session.dart';
import 'package:flutter_realtime_interaction_core/flutter_realtime_interaction_core.dart';
// ignore_for_file: prefer_initializing_formals

import 'package:flutter_realtime_chat_core/flutter_realtime_chat_core.dart';
import 'package:flutter_realtime_chat_rtc/flutter_realtime_chat_rtc.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'media_adapter.dart';
import 'realtime_room.dart';
import 'realtime_requirements.dart';
import 'realtime_chat_room.dart';
import 'interaction_revision_transport.dart';
import 'realtime_feature_plugin.dart';

typedef RealtimeTokenProvider = Future<String?> Function();
typedef RealtimeMediaClientFactory = MediaClient Function();
typedef RealtimeChatClientFactory = ChatClient Function();
typedef RealtimePublicProviderResolver = String Function(String engineId);
typedef InteractionControlPlaneFactory =
    InteractionControlPlane? Function(MediaRoomSession mediaRoom);

/// Recommended application-level entry point for realtime rooms.
///
/// Lower-level [MediaClient] and [ChatClient] remain available for applications
/// that need to own media or product-chat orchestration themselves.
class RealtimeClient {
  RealtimeClient({
    this.backendUrl,
    this.requestTimeout,
    this.effectsProbe,
    this.videoEffects,
    RealtimeRecordingSessionFactory? recordingSessionFactory,
    required this.mediaAdapters,
    ChatRegistry? chatRegistry,
    RealtimeTokenProvider? tokenProvider,
    RealtimeMediaClientFactory? mediaClientFactory,
    RealtimeChatClientFactory? chatClientFactory,
    RealtimePublicProviderResolver? publicProviderResolver,
    this.interactionControlPlaneFactory,
    Iterable<RealtimeFeaturePlugin<Object>> featurePlugins = const [],
  }) : chatRegistry = chatRegistry ?? ChatRegistry(),
       featurePlugins = List.unmodifiable(featurePlugins),
       _tokenProvider = tokenProvider,
       _mediaClientFactory = mediaClientFactory,
       _chatClientFactory = chatClientFactory,
       _publicProviderResolver = publicProviderResolver,
       recordingSessionFactory =
           recordingSessionFactory ??
           (backendUrl == null
               ? null
               : (room) => HttpCloudRecordingSession(
                   backendUrl: backendUrl,
                   roomCode: room.roomCode,
                   participantId: room.participantId,
                   participantCredential: room.participantCredential,
                   roomOwnerCredential: room.roomOwnerCredential,
                   tokenProvider: tokenProvider,
                   requestTimeout:
                       requestTimeout ?? const Duration(seconds: 15),
                 ));

  final RealtimeVideoEffects? videoEffects;
  final RealtimeRecordingSessionFactory? recordingSessionFactory;
  final String? backendUrl;
  final Duration? requestTimeout;
  final Future<MediaBackgroundCapabilities> Function(String, MediaRole)?
  effectsProbe;
  final RealtimeMediaAdapters mediaAdapters;
  final ChatRegistry chatRegistry;
  final RealtimeTokenProvider? _tokenProvider;
  final RealtimeMediaClientFactory? _mediaClientFactory;
  final RealtimeChatClientFactory? _chatClientFactory;
  final RealtimePublicProviderResolver? _publicProviderResolver;
  final InteractionControlPlaneFactory? interactionControlPlaneFactory;
  final List<RealtimeFeaturePlugin<Object>> featurePlugins;

  ChatClient newChatClient({ChatProvisioner? provisioner}) =>
      _chatClientFactory?.call() ??
      (backendUrl == null
          ? ChatClient.direct(registry: chatRegistry, provisioner: provisioner)
          : ChatClient(
              backendUrl: backendUrl!,
              registry: chatRegistry,
              tokenProvider: _tokenProvider,
              requestTimeout: requestTimeout ?? const Duration(seconds: 15),
            ));

  Future<RealtimeChatRoom> connectChatDirect(
    ChatJoinInfo joinInfo, {
    ChatCredentialProvider? credentialProvider,
  }) async {
    final client = ChatClient.direct(registry: chatRegistry);
    try {
      final room = await client.connect(
        joinInfo,
        credentialProvider: credentialProvider,
      );
      return RealtimeChatRoom(room: room, disposeClient: client.dispose);
    } catch (error, stack) {
      final primary = normalizeRealtimeException(
        error,
        domain: 'runtime',
        stackTrace: stack,
      );
      final cleanup = Cleanup();
      await cleanup.run('client', client.dispose);
      cleanup.finish(domain: 'runtime', cause: primary);
      Error.throwWithStackTrace(primary, stack);
    }
  }

  Future<RealtimeChatRoom> createChatRoom({
    required StandaloneChatProvisioner provisioner,
    required String userId,
    required String displayName,
    String? avatarUrl,
    ChatRole role = ChatRole.host,
    String? roomCode,
  }) async {
    final client = ChatClient.direct(
      registry: chatRegistry,
      provisioner: provisioner,
    );
    try {
      final room = await client.createStandaloneRoom(
        userId: userId,
        displayName: displayName,
        avatarUrl: avatarUrl,
        role: role,
        roomCode: roomCode,
      );
      return RealtimeChatRoom(room: room, disposeClient: client.dispose);
    } catch (error, stack) {
      final primary = normalizeRealtimeException(
        error,
        domain: 'runtime',
        stackTrace: stack,
      );
      final cleanup = Cleanup();
      await cleanup.run('client', client.dispose);
      cleanup.finish(domain: 'runtime', cause: primary);
      Error.throwWithStackTrace(primary, stack);
    }
  }

  Future<RealtimeChatRoom> joinChatRoom({
    required StandaloneChatProvisioner provisioner,
    required String roomCode,
    required String userId,
    required String displayName,
    String? avatarUrl,
    ChatRole role = ChatRole.participant,
  }) async {
    final client = ChatClient.direct(
      registry: chatRegistry,
      provisioner: provisioner,
    );
    try {
      final room = await client.joinStandaloneRoom(
        roomCode: roomCode,
        userId: userId,
        displayName: displayName,
        avatarUrl: avatarUrl,
        role: role,
      );
      return RealtimeChatRoom(room: room, disposeClient: client.dispose);
    } catch (error, stack) {
      final primary = normalizeRealtimeException(
        error,
        domain: 'runtime',
        stackTrace: stack,
      );
      final cleanup = Cleanup();
      await cleanup.run('client', client.dispose);
      cleanup.finish(domain: 'runtime', cause: primary);
      Error.throwWithStackTrace(primary, stack);
    }
  }

  MediaClient newMediaClient() =>
      _mediaClientFactory?.call() ??
      (backendUrl == null
          ? MediaClient.direct(registry: mediaAdapters.registry)
          : MediaClient(
              backendUrl: backendUrl!,
              registry: mediaAdapters.registry,
              tokenProvider: _tokenProvider,
              requestTimeout: requestTimeout ?? const Duration(seconds: 15),
              // A closed logical room should be detected promptly across
              // vendors even if the RTC provider cannot kick peers itself.
              heartbeatInterval: const Duration(seconds: 5),
            ));

  /// Adopts media joined from any trusted provisioning mechanism.
  Future<RealtimeRoom> joinDirect(
    MediaJoinInfo joinInfo, {
    ChatJoinInfo? chatJoinInfo,
    ChatCredentialProvider? chatCredentialProvider,
  }) async {
    final client = newMediaClient();
    try {
      final room = await client.join(joinInfo);
      return await _resolveRoom(
        client,
        room,
        directChatJoinInfo: chatJoinInfo,
        directChatCredentialProvider: chatCredentialProvider,
      );
    } catch (error, stack) {
      final primary = normalizeRealtimeException(
        error,
        domain: 'runtime',
        stackTrace: stack,
      );
      final cleanup = Cleanup();
      await cleanup.run('client', client.dispose);
      cleanup.finish(domain: 'runtime', cause: primary);
      Error.throwWithStackTrace(primary, stack);
    }
  }

  Future<RealtimeRoom> createRoomAndJoinIdentity({
    required MediaIdentity identity,
    MediaRoomMode roomMode = MediaRoomMode.meeting,
    MediaMeetingMode? meetingMode,
    MediaRole? role,
    String? roomCode,
  }) async {
    final client = newMediaClient();
    try {
      final room = await client.createRoomAndJoinIdentity(
        identity: identity,
        roomMode: roomMode,
        meetingMode: meetingMode,
        role: role,
        roomCode: roomCode,
      );
      return await _resolveRoom(client, room, createdRoom: true);
    } catch (error, stack) {
      final primary = normalizeRealtimeException(
        error,
        domain: 'runtime',
        stackTrace: stack,
      );
      final cleanup = Cleanup();
      await cleanup.run('client', client.dispose);
      cleanup.finish(domain: 'runtime', cause: primary);
      Error.throwWithStackTrace(primary, stack);
    }
  }

  Future<RealtimeRoom> joinRoomIdentity({
    required String roomCode,
    required MediaIdentity identity,
    String? roomOwnerCredential,
    MediaRole? role,
  }) async {
    final client = newMediaClient();
    try {
      final room = await client.joinRoomIdentity(
        roomCode: roomCode,
        identity: identity,
        roomOwnerCredential: roomOwnerCredential,
        role: role,
      );
      return await _resolveRoom(client, room);
    } catch (error, stack) {
      final primary = normalizeRealtimeException(
        error,
        domain: 'runtime',
        stackTrace: stack,
      );
      final cleanup = Cleanup();
      await cleanup.run('client', client.dispose);
      cleanup.finish(domain: 'runtime', cause: primary);
      Error.throwWithStackTrace(primary, stack);
    }
  }

  Future<RealtimeRoom> adopt(MediaClient client, MediaRoomSession room) =>
      _resolveRoom(client, room);

  Future<RealtimeRoom> _resolveRoom(
    MediaClient mediaClient,
    MediaRoomSession room, {
    ChatJoinInfo? directChatJoinInfo,
    ChatCredentialProvider? directChatCredentialProvider,
    bool createdRoom = false,
  }) async {
    ChatClient? chatClient;
    ChatRoomSession? productChatRoom;
    RtcDataChatSession? rtcChatRoom;
    try {
      final renderer = mediaAdapters.require(room.providerId).renderer;
      ChatSession? chat;
      final productChatConfigured =
          directChatJoinInfo != null || room.chatProvider != null;
      if (productChatConfigured) {
        if (directChatJoinInfo != null) {
          chatClient = ChatClient.direct(registry: chatRegistry);
          productChatRoom = await chatClient.connect(
            directChatJoinInfo,
            credentialProvider: directChatCredentialProvider,
          );
        } else {
          final url = backendUrl;
          if (_chatClientFactory == null && url == null) {
            throw const RealtimeException(
              code: RealtimeErrorCode.unsupportedFeature,
              message:
                  'Product Chat is configured for this room, but no ChatClient '
                  'factory or backend provisioning configuration was supplied.',
            );
          }
          chatClient =
              _chatClientFactory?.call() ??
              ChatClient(
                backendUrl: url!,
                registry: chatRegistry,
                tokenProvider: _tokenProvider,
                requestTimeout: requestTimeout ?? const Duration(seconds: 15),
              );
          productChatRoom = await chatClient.connectRoom(
            roomCode: room.roomCode,
            participantId: room.participantId,
            participantCredential: room.participantCredential,
            roomOwnerCredential: room.roomOwnerCredential,
          );
        }
        if (room.chatProvider != null &&
            productChatRoom.session.providerId != room.chatProvider) {
          throw RealtimeException(
            code: RealtimeErrorCode.invalidArgument,
            message:
                'Backend expected chat provider "${room.chatProvider}" but '
                'issued "${productChatRoom.session.providerId}" credentials.',
            providerId: room.chatProvider,
          );
        }
      }

      chat = resolveChatSessionWithRtcFallback(
        room: room,
        productChatConfigured: productChatConfigured,
        productChatSession: productChatRoom?.session,
      );
      if (chat is RtcDataChatSession) rtcChatRoom = chat;

      _validateRequirements(
        RealtimeCapabilityRequirements.fromBackend(room.backendMetadata),
        media: room.session.capabilities,
        chat: chat?.capabilities,
        providerId: room.providerId,
      );

      final classroomChat = chat;
      final ChatSystemMessaging? classroomSignals =
          classroomChat is ChatSystemMessaging
          ? classroomChat as ChatSystemMessaging
          : null;
      final bool canSendChatSignals =
          classroomChat?.capabilities.canSendMessage ?? false;
      final effects =
          await effectsProbe?.call(room.providerId, room.session.role) ??
          const MediaBackgroundCapabilities.none();
      final resolved = RealtimeRoom(
        effectsCapabilities: effects,
        videoEffects: videoEffects,
        cloudRecordingSession: recordingSessionFactory?.call(room),
        media: room,
        publicProviderId:
            _publicProviderResolver?.call(room.providerId) ?? room.providerId,
        renderer: renderer,
        chat: chat,
        featureBackendUrl: backendUrl,
        featureTokenProvider: _tokenProvider,
        featureRequestTimeout: requestTimeout,
        interactionControlPlane: interactionControlPlaneFactory?.call(room),
        featurePlugins: featurePlugins,
        interactionRevisionTransport:
            classroomSignals != null && canSendChatSignals
            ? ChatInteractionRevisionTransport(
                classroomSignals,
                roomCode: room.roomCode,
              )
            : room.session.capabilities.canSendData &&
                  room.session.capabilities.canReceiveData
            ? MediaInteractionRevisionTransport(
                room.session,
                roomCode: room.roomCode,
              )
            : null,
        productChatRoom: productChatRoom,
        rtcChatRoom: rtcChatRoom,
        disposeClients: () {
          chatClient?.dispose();
          mediaClient.dispose();
        },
      );
      // Sync presets attach before room creation returns. An async custom
      // feature may still be pending: never block connecting media for it.
      // Clients that need all async features can await room.readyFeatures().
      return resolved;
    } catch (error, stack) {
      final cleanup = Cleanup();
      // An adapter may join RTC successfully before chat/feature setup fails.
      // Only the *create* flow may close the new room; a failed ordinary join
      // must never close another host's existing session.
      if (createdRoom &&
          room.roomOwnerCredential?.isNotEmpty == true &&
          room.participantCredential?.isNotEmpty == true) {
        await cleanup.run('created-room.rollback', () async {
          await mediaClient.backend?.closeRoomAsParticipant(
            room.roomCode,
            requesterParticipantId: room.participantId,
            participantCredential: room.participantCredential,
            roomOwnerCredential: room.roomOwnerCredential,
          );
        });
      }
      await cleanup.run('chat.product', () async {
        await productChatRoom?.dispose();
      });
      await cleanup.run('chat.rtc', () async {
        await rtcChatRoom?.dispose();
      });
      await cleanup.run('chat.client', () {
        chatClient?.dispose();
      });
      await cleanup.run('media.room', room.dispose);
      await cleanup.run('media.client', mediaClient.dispose);
      cleanup.finish(domain: 'room', cause: error);
      Error.throwWithStackTrace(error, stack);
    }
  }

  void _validateRequirements(
    RealtimeCapabilityRequirements requirements, {
    required MediaCapabilities media,
    required ChatCapabilities? chat,
    required String providerId,
  }) {
    bool supported(RealtimeCapability value) => switch (value) {
      RealtimeCapability.publishAudio => media.canPublishAudio,
      RealtimeCapability.publishVideo => media.canPublishVideo,
      RealtimeCapability.subscribeVideo => media.canSubscribeVideo,
      RealtimeCapability.screenShare => media.canScreenShare,
      RealtimeCapability.chat =>
        chat?.canSendMessage == true ||
            (media.canSendData && media.canReceiveData),
      RealtimeCapability.listParticipants => media.canListParticipants,
      RealtimeCapability.removeParticipants => media.canRemoveParticipants,
      RealtimeCapability.closeRoom => media.canCloseRoom,
    };

    final missing = requirements.values.where((value) => !supported(value));
    if (missing.isEmpty) return;
    throw RealtimeException(
      code: RealtimeErrorCode.unsupportedFeature,
      message:
          'The backend requires unsupported realtime capabilities: '
          '${missing.map((value) => value.name).join(', ')}.',
      providerId: providerId,
      details: missing.map((value) => value.name).toList(growable: false),
    );
  }
}
