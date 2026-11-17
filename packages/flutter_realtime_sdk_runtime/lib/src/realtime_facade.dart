import 'provider_plugin.dart';
import 'provider_web_assets.dart';
import 'realtime_room_services.dart';
import 'provider_bundle.dart';
import 'provider_web_session_wrapper.dart';
import 'package:flutter_realtime_chat_core/flutter_realtime_chat_core.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'provider_driver.dart';
import 'realtime_client.dart';
import 'realtime_feature_plugin.dart';
import 'realtime_connection.dart';
import 'realtime_error.dart';
import 'realtime_request.dart';
import 'realtime_room.dart';
import 'realtime_chat_room.dart';
import 'realtime_sdk.dart';
import 'runtime_platform.dart';

/// Simplified application-facing realtime API.
///
/// Most applications should start here. [RealtimeSdk] remains available as
/// the advanced API for custom provisioning and lower-level orchestration.
class Realtime {
  Realtime.fromSdk(this.sdk, {this.standaloneChatProvisionerFactory});

  factory Realtime({
    required Iterable<RealtimeProviderBundle> providers,
    String? backendUrl,
    Duration? requestTimeout,
    bool preventScreenCapture = false,
    RealtimeRoomServices services = const RealtimeRoomServices(),
    RealtimeTokenProvider? tokenProvider,
    InteractionControlPlaneFactory? interactionControlPlaneFactory,
    Iterable<RealtimeFeaturePlugin<Object>> featurePlugins = const [],
    RealtimePlatformResolver platformResolver = resolveRealtimeRuntimePlatform,
  }) {
    final bundles = providers.toList();
    if (bundles.isEmpty) {
      throw ArgumentError.value(
        providers,
        'providers',
        'At least one provider is required',
      );
    }
    final registry = RealtimeDriverRegistry(
      bundles.expand((b) => b.drivers),
      platformResolver: platformResolver,
    );
    final plugins = bundles.expand((bundle) {
      final ownRegistry = RealtimeDriverRegistry(
        bundle.drivers,
        platformResolver: platformResolver,
      );
      final resolved = ownRegistry.resolvePlugins();
      return registry.platform == RealtimeRuntimePlatform.web
          ? wrapWebProviderPlugins(resolved, bundle.webAssetsLoader)
          : resolved;
    });
    final sdk = RealtimeSdk(
      backendUrl: backendUrl,
      requestTimeout: requestTimeout,
      preventScreenCapture: preventScreenCapture,
      services: services,
      plugins: plugins,
      driverRegistry: registry,
      tokenProvider: tokenProvider,
      interactionControlPlaneFactory: interactionControlPlaneFactory,
      featurePlugins: featurePlugins,
    );
    final url = backendUrl?.trim();
    return Realtime.fromSdk(
      sdk,
      standaloneChatProvisionerFactory:
          services.standaloneChatProvisionerFactory ??
          (url == null || url.isEmpty
              ? null
              : () => HttpStandaloneChatProvisioner(
                  ChatBackendConfig.fromUrl(
                    url,
                    tokenProvider: tokenProvider,
                    requestTimeout:
                        requestTimeout ?? const Duration(seconds: 15),
                  ),
                )),
    );
  }

  factory Realtime.standard({
    String? backendUrl,
    Duration? requestTimeout,
    bool preventScreenCapture = false,
    RealtimeRoomServices services = const RealtimeRoomServices(),
    RealtimeTokenProvider? tokenProvider,
    InteractionControlPlaneFactory? interactionControlPlaneFactory,
    Iterable<RealtimeFeaturePlugin<Object>> featurePlugins = const [],
    RealtimeClientFactory? clientFactory,
    RealtimePlatformResolver platformResolver = resolveRealtimeRuntimePlatform,
    Iterable<RealtimeProviderPlugin> additionalPlugins = const [],
    Iterable<RealtimeProviderDriver> drivers = const [],
    RealtimeProviderWebAssetsLoader? webAssetsLoader,
  }) {
    final sdk = RealtimeSdk.standard(
      backendUrl: backendUrl,
      requestTimeout: requestTimeout,
      preventScreenCapture: preventScreenCapture,
      services: services,
      tokenProvider: tokenProvider,
      interactionControlPlaneFactory: interactionControlPlaneFactory,
      featurePlugins: featurePlugins,
      clientFactory: clientFactory,
      platformResolver: platformResolver,
      additionalPlugins: additionalPlugins,
      drivers: drivers,
      webAssetsLoader: webAssetsLoader,
    );
    final url = backendUrl?.trim();
    return Realtime.fromSdk(
      sdk,
      standaloneChatProvisionerFactory:
          services.standaloneChatProvisionerFactory ??
          (url == null || url.isEmpty
              ? null
              : () => HttpStandaloneChatProvisioner(
                  ChatBackendConfig.fromUrl(
                    url,
                    tokenProvider: tokenProvider,
                    requestTimeout:
                        requestTimeout ?? const Duration(seconds: 15),
                  ),
                )),
    );
  }

  final RealtimeSdk sdk;
  final RealtimeStandaloneChatProvisionerFactory?
  standaloneChatProvisionerFactory;

  bool get preventScreenCapture => sdk.preventScreenCapture;
  Iterable<String> get supportedProviderIds => sdk.supportedProviderIds;
  RealtimeRuntimePlatform get platform => sdk.platform;
  bool supportsProvider(String providerId) => sdk.supportsProvider(providerId);

  Future<List<MediaRoomSummary>> listRooms() => sdk.listRooms();

  Future<MediaDoctorReport> diagnoseBackend() => sdk.diagnoseBackend();

  Future<MediaPreJoinResult> preJoin({
    MediaRole role = MediaRole.participant,
    String? providerId,
    String? roomCode,
    MediaPreJoinRequirements? requirements,
  }) => sdk.preJoin(
    role: role,
    providerId: providerId,
    roomCode: roomCode,
    requirements: requirements,
  );

  /// Opens an optional provider-local preview without creating a room.
  Future<MediaLocalPreviewSession?> createLocalPreview({
    required String providerId,
    required MediaRole role,
  }) => sdk.createLocalPreview(providerId: providerId, role: role);

  Future<List<ChatRoomSummary>> listChatRooms() async {
    final factory = standaloneChatProvisionerFactory;
    if (factory == null) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message:
            'Standalone Chat discovery requires a backend URL or a custom '
            'StandaloneChatProvisioner factory.',
        suggestedAction: 'configure-backend',
      );
    }
    final provisioner = factory();
    late final List<ChatRoomSummary> rooms;
    try {
      rooms = await provisioner.listRooms();
    } catch (error) {
      await _disposeProvisioner(provisioner, cause: error);
      throw mapRealtimeException(error);
    }
    await _disposeProvisioner(provisioner);
    return List.unmodifiable(rooms);
  }

  Future<RealtimeConnection> open(RealtimeRequest request) async {
    try {
      if (request.meetingMode != null &&
          request.experience != RealtimeExperience.meeting) {
        throw const RealtimeException(
          code: RealtimeErrorCode.invalidArgument,
          message: 'meetingMode.requiresMeeting',
        );
      }
      final user = request.user.normalized();
      final source = request.source;
      if (source is RealtimeBackendSource) {
        return await _openBackend(request, user);
      }
      if (source is RealtimeCredentialsSource) {
        return await _openCredentials(request, user, source);
      }
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Unsupported realtime connection source.',
      );
    } catch (error) {
      throw mapRealtimeException(error);
    }
  }

  Future<RealtimeConnection> _openBackend(
    RealtimeRequest request,
    RealtimeUser user,
  ) async {
    final roomCode = _normalizedRoomCode(request.roomCode);
    if (request.action == RealtimeAction.join && roomCode == null) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Joining through the backend requires a roomCode.',
      );
    }

    if (request.experience == RealtimeExperience.chat) {
      return _openBackendChat(request, user, roomCode);
    }

    _requireBackend();
    final identity = user.toMediaIdentity();
    final mode = _mediaMode(request.experience);
    final RealtimeRoom room;
    if (request.action == RealtimeAction.create) {
      room = await sdk.createRoom(
        user: identity,
        mode: mode,
        meetingMode: request.meetingMode,
        role: request.mediaRole ?? _defaultMediaRole(request),
        roomCode: roomCode,
      );
    } else {
      room = await sdk.joinRoom(
        roomCode: roomCode!,
        user: identity,
        roomOwnerCredential: request.roomOwnerCredential,
        // Existing rooms are authoritative about Meeting/Live role mapping.
        // Keeping this null by default also preserves manual room-code joins
        // where the application does not know the room mode in advance.
        role: request.mediaRole,
      );
    }
    return RealtimeConnection.media(experience: request.experience, room: room);
  }

  Future<RealtimeConnection> _openBackendChat(
    RealtimeRequest request,
    RealtimeUser user,
    String? roomCode,
  ) async {
    final factory = standaloneChatProvisionerFactory;
    if (factory == null) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message:
            'Standalone backend Chat requires a backend URL or a custom '
            'StandaloneChatProvisioner factory.',
        suggestedAction: 'configure-backend',
      );
    }
    final provisioner = factory();
    try {
      final RealtimeChatRoom room;
      if (request.action == RealtimeAction.create) {
        room = await sdk.createChatRoom(
          provisioner: provisioner,
          userId: user.id,
          displayName: user.name,
          avatarUrl: user.avatarUrl,
          role: request.chatRole ?? ChatRole.host,
          roomCode: roomCode,
        );
      } else {
        room = await sdk.joinChatRoom(
          provisioner: provisioner,
          roomCode: roomCode!,
          userId: user.id,
          displayName: user.name,
          avatarUrl: user.avatarUrl,
          role: request.chatRole ?? ChatRole.participant,
        );
      }
      return RealtimeConnection.chat(
        room: room,
        disposeAuxiliary: () => _disposeProvisioner(provisioner),
      );
    } catch (error) {
      await _disposeProvisioner(provisioner, cause: error);
      rethrow;
    }
  }

  Future<RealtimeConnection> _openCredentials(
    RealtimeRequest request,
    RealtimeUser user,
    RealtimeCredentialsSource source,
  ) async {
    if (request.action != RealtimeAction.join) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message:
            'Direct credentials can only join/connect an already provisioned '
            'room. Create the provider room on a trusted backend first.',
      );
    }

    if (request.experience == RealtimeExperience.chat) {
      if (source.media != null || source.chat == null) {
        throw const RealtimeException(
          code: RealtimeErrorCode.invalidArgument,
          message:
              'Standalone direct Chat requires chat credentials and no media '
              'credentials.',
        );
      }
      final chat = source.chat!;
      final room = await sdk.connectChatWithCredentials(
        providerId: _providerId(chat.providerId),
        joinPayload: _chatPayload(request, user, chat.payload),
        credentialProvider: _chatCredentialProvider(
          request,
          user,
          chat,
          source.chatCredentialProvider,
        ),
      );
      return RealtimeConnection.chat(room: room);
    }

    final media = source.media;
    if (media == null) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Meeting/live direct join requires media credentials.',
      );
    }
    final chat = source.chat;
    final room = await sdk.joinWithCredentials(
      mediaProviderId: _providerId(media.providerId),
      mediaJoinPayload: _mediaPayload(request, user, media.payload),
      chatProviderId: chat == null ? null : _providerId(chat.providerId),
      chatJoinPayload: chat == null
          ? null
          : _chatPayload(request, user, chat.payload),
      chatCredentialProvider: chat == null
          ? null
          : _chatCredentialProvider(
              request,
              user,
              chat,
              source.chatCredentialProvider,
            ),
    );
    return RealtimeConnection.media(experience: request.experience, room: room);
  }

  Map<String, dynamic> _mediaPayload(
    RealtimeRequest request,
    RealtimeUser user,
    Map<String, dynamic> input,
  ) {
    final payload = Map<String, dynamic>.from(input);
    payload.putIfAbsent(
      'roomMode',
      () => _mediaMode(request.experience).wireName,
    );
    payload.putIfAbsent(
      'role',
      () => (request.mediaRole ?? _defaultMediaRole(request)).wireName,
    );
    final roomCode = _normalizedRoomCode(request.roomCode);
    if (roomCode != null) payload.putIfAbsent('roomCode', () => roomCode);
    payload.putIfAbsent('participantId', () => user.id);
    payload.putIfAbsent('userId', () => user.id);
    payload.putIfAbsent('displayName', () => user.name);
    if (user.avatarUrl != null) {
      payload.putIfAbsent('avatarUrl', () => user.avatarUrl);
    }
    if (user.deviceId != null) {
      payload.putIfAbsent('deviceId', () => user.deviceId);
    }
    return payload;
  }

  ChatCredentialProvider? _chatCredentialProvider(
    RealtimeRequest request,
    RealtimeUser user,
    RealtimeCredentials initial,
    RealtimeChatCredentialProvider? refresh,
  ) {
    if (refresh == null) return null;
    final expectedProvider = _providerId(initial.providerId);
    return () async {
      final credentials = await refresh();
      final providerId = _providerId(credentials.providerId);
      if (providerId != expectedProvider) {
        throw RealtimeException(
          code: RealtimeErrorCode.invalidCredential,
          message:
              'Refreshed Chat credentials changed provider from '
              '$expectedProvider to $providerId.',
          providerId: expectedProvider,
        );
      }
      return sdk.parseChatCredentials(
        providerId: providerId,
        joinPayload: _chatPayload(request, user, credentials.payload),
      );
    };
  }

  Map<String, dynamic> _chatPayload(
    RealtimeRequest request,
    RealtimeUser user,
    Map<String, dynamic> input,
  ) {
    final payload = Map<String, dynamic>.from(input);
    final roomCode = _normalizedRoomCode(request.roomCode);
    if (roomCode != null) payload.putIfAbsent('roomCode', () => roomCode);
    payload.putIfAbsent('participantId', () => user.id);
    payload.putIfAbsent('userId', () => user.id);
    payload.putIfAbsent('displayName', () => user.name);
    payload.putIfAbsent(
      'role',
      () => (request.chatRole ?? _defaultChatRole(request)).wireName,
    );
    if (user.avatarUrl != null) {
      payload.putIfAbsent('avatarUrl', () => user.avatarUrl);
    }
    return payload;
  }

  void _requireBackend() {
    final backend = sdk.backendUrl?.trim();
    if (backend == null || backend.isEmpty) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'This request requires a configured backend URL.',
        suggestedAction: 'configure-backend',
      );
    }
  }

  MediaRoomMode _mediaMode(RealtimeExperience experience) {
    return switch (experience) {
      RealtimeExperience.meeting => MediaRoomMode.meeting,
      RealtimeExperience.live => MediaRoomMode.broadcast,
      RealtimeExperience.chat => throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Standalone Chat does not have a media room mode.',
      ),
    };
  }

  MediaRole _defaultMediaRole(RealtimeRequest request) {
    return switch ((request.experience, request.action)) {
      (RealtimeExperience.meeting, _) => MediaRole.participant,
      (RealtimeExperience.live, RealtimeAction.create) => MediaRole.host,
      (RealtimeExperience.live, RealtimeAction.join) => MediaRole.viewer,
      (RealtimeExperience.chat, _) => throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Standalone Chat does not have a media role.',
      ),
    };
  }

  ChatRole _defaultChatRole(RealtimeRequest request) {
    if (request.action == RealtimeAction.create) return ChatRole.host;
    return request.experience == RealtimeExperience.live
        ? ChatRole.viewer
        : ChatRole.participant;
  }

  String? _normalizedRoomCode(String? value) {
    final roomCode = value?.trim();
    return roomCode == null || roomCode.isEmpty ? null : roomCode;
  }

  String _providerId(String value) {
    final providerId = value.trim().toLowerCase();
    if (providerId.isEmpty) {
      throw ArgumentError.value(value, 'providerId', 'must not be empty');
    }
    return providerId;
  }

  Future<void> _disposeProvisioner(
    StandaloneChatProvisioner provisioner, {
    Object? cause,
  }) async {
    final cleanup = Cleanup();
    await cleanup.run('chat.provisioner', provisioner.dispose);
    cleanup.finish(domain: 'chat', cause: cause);
  }
}
