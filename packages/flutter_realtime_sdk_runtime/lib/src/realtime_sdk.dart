import 'realtime_room_services.dart';
import 'realtime_platform_reports.dart';
import 'realtime_credentials_parser.dart';

import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_chat_core/flutter_realtime_chat_core.dart';
import 'composed_local_preview.dart';
import 'realtime_video_effects.dart';

import 'provider_driver.dart';
import 'provider_plugin.dart';
import 'provider_web_assets.dart';
import 'provider_web_session_wrapper.dart';
import 'realtime_client.dart';
import 'realtime_feature_plugin.dart';
import 'realtime_error.dart';
import 'realtime_room.dart';
import 'realtime_chat_room.dart';
import 'runtime_platform.dart';

typedef RealtimeClientFactory = RealtimeClient Function();

/// Lowest-cognitive-load application entry point.
///
/// Backend-selected rooms are supported, but a backend is not required for
/// direct joins provisioned by the host application.
class RealtimeSdk {
  RealtimeSdk({
    this.backendUrl,
    this.requestTimeout,
    this.services = const RealtimeRoomServices(),
    required Iterable<RealtimeProviderPlugin> plugins,
    this.tokenProvider,
    this.clientFactory,
    this.interactionControlPlaneFactory,
    Iterable<RealtimeFeaturePlugin<Object>> featurePlugins = const [],
    this.driverRegistry,
    RealtimeProviderWebAssetsLoader? webAssetsLoader,
    Future<void> Function(String providerId)? chatAssetsLoader,
  }) : plugins = RealtimePluginRegistry(
         _pluginsForRuntime(
           plugins,
           platform:
               driverRegistry?.platform ?? resolveRealtimeRuntimePlatform(),
           webAssetsLoader: webAssetsLoader ?? ensureRealtimeProviderWebAssets,
           chatAssetsLoader: chatAssetsLoader,
         ),
       ),
       featurePlugins = List.unmodifiable(featurePlugins);

  factory RealtimeSdk.standard({
    String? backendUrl,
    Duration? requestTimeout,
    RealtimeRoomServices services = const RealtimeRoomServices(),
    RealtimeTokenProvider? tokenProvider,
    RealtimeClientFactory? clientFactory,
    InteractionControlPlaneFactory? interactionControlPlaneFactory,
    Iterable<RealtimeFeaturePlugin<Object>> featurePlugins = const [],
    RealtimePlatformResolver platformResolver = resolveRealtimeRuntimePlatform,
    Iterable<RealtimeProviderPlugin> additionalPlugins = const [],
    Iterable<RealtimeProviderDriver> drivers = const [],
    RealtimeProviderWebAssetsLoader? webAssetsLoader,
  }) {
    final registry = RealtimeDriverRegistry(
      drivers,
      platformResolver: platformResolver,
    );
    return RealtimeSdk(
      backendUrl: backendUrl,
      requestTimeout: requestTimeout,
      services: services,
      plugins: registry.resolvePlugins(additionalPlugins: additionalPlugins),
      tokenProvider: tokenProvider,
      clientFactory: clientFactory,
      interactionControlPlaneFactory: interactionControlPlaneFactory,
      featurePlugins: featurePlugins,
      driverRegistry: registry,
      webAssetsLoader: webAssetsLoader,
    );
  }

  final String? backendUrl;
  final Duration? requestTimeout;
  final RealtimeRoomServices services;
  final RealtimePluginRegistry plugins;
  final RealtimeDriverRegistry? driverRegistry;
  final RealtimeTokenProvider? tokenProvider;
  final RealtimeClientFactory? clientFactory;
  final InteractionControlPlaneFactory? interactionControlPlaneFactory;
  final List<RealtimeFeaturePlugin<Object>> featurePlugins;
  RealtimeRuntimePlatform get platform =>
      driverRegistry?.platform ?? resolveRealtimeRuntimePlatform();

  late final RealtimeVideoEffects? _videoEffects = services.videoEffectsFactory
      ?.call();

  final Map<String, MediaBackgroundCapabilities> _effectsSupport = {};
  final Map<String, Future<MediaBackgroundCapabilities>> _effectsPending = {};
  final List<RealtimeException> _diagnostics = [];
  List<RealtimeException> get diagnostics => List.unmodifiable(_diagnostics);

  Future<MediaBackgroundCapabilities> _probeEffects(
    String? providerId,
    MediaRole role,
  ) async {
    final id = providerId?.trim().toLowerCase();
    final probe = id == null ? null : plugins.lookup(id)?.effectsProbe;
    if (_videoEffects == null || probe == null || role == MediaRole.viewer) {
      return const MediaBackgroundCapabilities.none();
    }
    final key = '$id:${role.name}';
    final cached = _effectsSupport[key];
    if (cached != null) return cached;
    try {
      final result = await (_effectsPending[key] ??= (() async {
        if (!await _videoEffects.isSupported()) {
          return const MediaBackgroundCapabilities.none();
        }
        return probe(role);
      })().timeout(const Duration(seconds: 10)));
      _effectsSupport[key] = result;
      return result;
    } catch (error, stack) {
      if (_diagnostics.length == 64) _diagnostics.removeAt(0);
      _diagnostics.add(
        normalizeRealtimeException(
          error,
          domain: 'videoEffects',
          operation: 'probe',
          providerId: id,
          stackTrace: stack,
        ),
      );
      return const MediaBackgroundCapabilities.none();
    } finally {
      _effectsPending.removeWhere((candidate, _) => candidate == key);
    }
  }

  Future<bool> _supportsVideoEffectsForProvider({
    required String? providerId,
    MediaRole role = MediaRole.participant,
  }) async => (await _probeEffects(providerId, role)).isSupported;

  Iterable<String> get supportedProviderIds =>
      driverRegistry?.supportedProviderIds() ?? plugins.providerIds;

  bool supportsProvider(String providerId) =>
      driverRegistry?.supportsProvider(providerId) ??
      plugins.lookup(providerId) != null;

  /// Opens an optional provider-local preview without creating a room.
  ///
  /// Returns `null` when the resolved adapter does not implement the preview
  /// contract. Callers must dispose a returned session when leaving the
  /// pre-join flow, including when the user cancels.
  Future<MediaLocalPreviewSession?> createLocalPreview({
    required String providerId,
    required MediaRole role,
  }) => _guard(() async {
    final mode = role == MediaRole.participant
        ? MediaRoomMode.meeting
        : MediaRoomMode.broadcast;
    final engineProvider =
        driverRegistry?.resolveMediaEngine(
          providerId: providerId,
          roomMode: mode,
        ) ??
        providerId.trim().toLowerCase();
    if (role != MediaRole.viewer) {
      final effects = _videoEffects;
      if (effects != null &&
          await _supportsVideoEffectsForProvider(
            providerId: engineProvider,
            role: role,
          )) {
        try {
          final camera = await effects.createPreview(
            providerId: engineProvider,
            role: role,
          );
          // A processed-video preview does not own microphone capture.
          // Compose the provider's credential-free local audio preview so
          // volume levels and input selection are backed by real capture.
          try {
            final audio = await _createDevicePreview(
              providerId: engineProvider,
              role: role,
            );
            return ComposedLocalPreview(video: camera, audio: audio);
          } catch (_) {
            await camera.dispose();
            rethrow;
          }
        } catch (error, stack) {
          if (_diagnostics.length == 64) _diagnostics.removeAt(0);
          _diagnostics.add(
            normalizeRealtimeException(
              error,
              domain: 'videoEffects',
              operation: 'preview',
              providerId: engineProvider,
              stackTrace: stack,
            ),
          );
        }
      }
    }
    return _createDevicePreview(providerId: engineProvider, role: role);
  });

  Future<MediaLocalPreviewSession?> _createDevicePreview({
    required String providerId,
    required MediaRole role,
  }) async {
    final factory = plugins.media.lookup(providerId)?.sessionFactory;
    if (factory is MediaLocalPreviewFactory) {
      return (factory as MediaLocalPreviewFactory).createLocalPreview(
        role: role,
      );
    }
    final fallback = services.localPreviewFallbackFactory;
    return fallback == null
        ? null
        : fallback(providerId: providerId, role: role);
  }

  RealtimeClient createClient() =>
      clientFactory?.call() ??
      RealtimeClient(
        backendUrl: backendUrl,
        requestTimeout: requestTimeout,
        effectsProbe: _videoEffects == null ? null : _probeEffects,
        videoEffects: _videoEffects,
        mediaClientFactory: services.mediaClientFactory,
        chatClientFactory: services.chatClientFactory,
        recordingSessionFactory: services.recordingSessionFactory,
        mediaAdapters: plugins.media,
        chatRegistry: plugins.chat,
        tokenProvider: tokenProvider,
        publicProviderResolver: driverRegistry?.publicProviderForEngine,
        interactionControlPlaneFactory:
            services.interactionControlPlaneFactory ??
            interactionControlPlaneFactory,
        featurePlugins: featurePlugins,
      );

  /// Lists backend-provisioned rooms without exposing a lower-level client.
  Future<List<MediaRoomSummary>> listRooms() => _guard(() async {
    final client = createClient().newMediaClient();
    try {
      return await client.listRooms();
    } finally {
      client.dispose();
    }
  });

  /// Checks backend reachability and whether its active provider is available
  /// on this SDK's runtime platform.
  Future<MediaDoctorReport> diagnoseBackend() => _guard(() async {
    final client = createClient().newMediaClient();
    try {
      final backend = client.backend;
      if (backend == null) {
        throw const RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'Backend diagnostics require a configured backend URL.',
          suggestedAction: 'configure-backend',
        );
      }
      final report = await MediaDoctor.check(
        backend: backend,
        registry: client.registry,
      );
      return _applyPlatformSupportToDoctorReport(report);
    } finally {
      client.dispose();
    }
  });

  /// Parses raw provider media credentials through the selected SDK driver.
  ///
  /// Applications can keep provider credential JSON opaque and avoid
  /// importing provider-specific JoinInfo classes. The payload shape remains
  /// provider-defined; only platform selection and parsing are centralized.
  late final _credentials = RealtimeCredentialsParser(
    plugins,
    driverRegistry,
    _assertPlatformSupport,
  );
  MediaJoinInfo parseMediaCredentials({
    required String providerId,
    required Map<String, dynamic> joinPayload,
  }) => _credentials.parseMediaCredentials(
    providerId: providerId,
    joinPayload: joinPayload,
  );
  ChatJoinInfo parseChatCredentials({
    required String providerId,
    required Map<String, dynamic> joinPayload,
  }) => _credentials.parseChatCredentials(
    providerId: providerId,
    joinPayload: joinPayload,
  );

  /// Direct media join using raw provider credential JSON.
  ///
  /// Media and Product Chat providers remain independent. When Product Chat is
  /// supplied, both [chatProviderId] and [chatJoinPayload] are required.
  Future<RealtimeRoom> joinWithCredentials({
    required String mediaProviderId,
    required Map<String, dynamic> mediaJoinPayload,
    String? chatProviderId,
    Map<String, dynamic>? chatJoinPayload,
    ChatCredentialProvider? chatCredentialProvider,
  }) {
    final normalizedChatProvider = chatProviderId?.trim();
    if ((normalizedChatProvider == null || normalizedChatProvider.isEmpty) !=
        (chatJoinPayload == null)) {
      return Future.error(
        const RealtimeException(
          code: RealtimeErrorCode.invalidArgument,
          message:
              'chatProviderId and chatJoinPayload must be supplied together.',
        ),
      );
    }

    final media = parseMediaCredentials(
      providerId: mediaProviderId,
      joinPayload: mediaJoinPayload,
    );
    final chat = chatJoinPayload == null
        ? null
        : parseChatCredentials(
            providerId: normalizedChatProvider!,
            joinPayload: chatJoinPayload,
          );
    return joinDirect(
      media,
      chatJoinInfo: chat,
      chatCredentialProvider: chatCredentialProvider,
    );
  }

  /// Direct Product Chat connection using raw provider credential JSON.
  Future<RealtimeChatRoom> connectChatWithCredentials({
    required String providerId,
    required Map<String, dynamic> joinPayload,
    ChatCredentialProvider? credentialProvider,
  }) => connectChatDirect(
    parseChatCredentials(providerId: providerId, joinPayload: joinPayload),
    credentialProvider: credentialProvider,
  );

  /// Runs the provider-neutral pre-join diagnostics through the high-level SDK.
  ///
  /// The temporary lower-level client is owned and disposed by this call.
  Future<MediaPreJoinResult> preJoin({
    MediaRole role = MediaRole.participant,
    String? providerId,
    String? roomCode,
    MediaPreJoinRequirements? requirements,
  }) => _guard(() async {
    final client = createClient().newMediaClient();
    try {
      final requestedProvider = providerId?.trim().toLowerCase();
      var coreProvider = requestedProvider;
      final registry = driverRegistry;
      if ((coreProvider == null || coreProvider.isEmpty) &&
          (roomCode == null || roomCode.trim().isEmpty) &&
          registry != null) {
        final backend = client.backend;
        if (backend != null) {
          final doctor = await MediaDoctor.check(
            backend: backend,
            registry: client.registry,
          );
          final activeProvider = doctor.activeProvider;
          if (activeProvider != null &&
              registry.knowsProvider(activeProvider)) {
            coreProvider = registry.resolveMediaEngine(
              providerId: activeProvider,
              roomMode: role == MediaRole.participant
                  ? MediaRoomMode.meeting
                  : MediaRoomMode.broadcast,
            );
          }
        }
      }
      if (registry != null &&
          coreProvider != null &&
          coreProvider.isNotEmpty &&
          client.registry.lookup(coreProvider) == null &&
          registry.knowsProvider(coreProvider)) {
        coreProvider = registry.resolveMediaEngine(
          providerId: coreProvider,
          roomMode: role == MediaRole.participant
              ? MediaRoomMode.meeting
              : MediaRoomMode.broadcast,
        );
      }
      var result = await client.runPreJoinCheck(
        role: role,
        providerId: coreProvider,
        roomCode: roomCode,
        requirements: requirements,
      );
      final publicProvider =
          requestedProvider ??
          (result.providerId == null
              ? null
              : registry?.publicProviderForEngine(result.providerId!) ??
                    result.providerId);
      if (publicProvider != null && publicProvider != result.providerId) {
        result = MediaPreJoinResult(
          role: result.role,
          meetingMode: result.meetingMode,
          providerId: publicProvider,
          checks: result.checks,
          backgroundCapabilities: result.backgroundCapabilities,
        );
      }
      final effectsProvider = (coreProvider ?? result.providerId)
          ?.trim()
          .toLowerCase();
      result = _applyPlatformSupportToPreJoin(result);
      if (role != MediaRole.viewer) {
        try {
          if (await _supportsVideoEffectsForProvider(
            providerId: effectsProvider,
            role: role,
          )) {
            result = MediaPreJoinResult(
              role: result.role,
              meetingMode: result.meetingMode,
              providerId: result.providerId,
              checks: result.checks,
              backgroundCapabilities: await _probeEffects(
                effectsProvider,
                role,
              ),
            );
          }
        } catch (_) {
          // Video effects are optional; diagnostics remain valid without them.
        }
      }
      return result;
    } finally {
      client.dispose();
    }
  });

  Future<RealtimeRoom> createRoom({
    required MediaIdentity user,
    MediaRoomMode mode = MediaRoomMode.meeting,
    MediaMeetingMode? meetingMode,
    MediaRole? role,
    String? roomCode,
  }) => _guard(() async {
    return createClient().createRoomAndJoinIdentity(
      identity: user,
      roomMode: mode,
      meetingMode: meetingMode,
      role: role,
      roomCode: roomCode,
    );
  });

  Future<RealtimeChatRoom> connectChatDirect(
    ChatJoinInfo joinInfo, {
    ChatCredentialProvider? credentialProvider,
  }) => _guard(() async {
    _assertPlatformSupport(joinInfo.providerId);
    return createClient().connectChatDirect(
      joinInfo,
      credentialProvider: credentialProvider,
    );
  });

  Future<RealtimeChatRoom> createChatRoom({
    required StandaloneChatProvisioner provisioner,
    required String userId,
    required String displayName,
    String? avatarUrl,
    ChatRole role = ChatRole.host,
    String? roomCode,
  }) => _guard(() async {
    return createClient().createChatRoom(
      provisioner: provisioner,
      userId: userId,
      displayName: displayName,
      avatarUrl: avatarUrl,
      role: role,
      roomCode: roomCode,
    );
  });

  Future<RealtimeChatRoom> joinChatRoom({
    required StandaloneChatProvisioner provisioner,
    required String roomCode,
    required String userId,
    required String displayName,
    String? avatarUrl,
    ChatRole role = ChatRole.participant,
  }) => _guard(() async {
    return createClient().joinChatRoom(
      provisioner: provisioner,
      roomCode: roomCode,
      userId: userId,
      displayName: displayName,
      avatarUrl: avatarUrl,
      role: role,
    );
  });

  /// Joins directly from provider-neutral media join information.
  ///
  /// The host application owns provisioning. This path does not require the
  /// repository Backend Contract or demo-server.
  Future<RealtimeRoom> joinDirect(
    MediaJoinInfo joinInfo, {
    ChatJoinInfo? chatJoinInfo,
    ChatCredentialProvider? chatCredentialProvider,
  }) => _guard(() async {
    _assertPlatformSupport(joinInfo.providerId);
    final productChat = chatJoinInfo;
    if (productChat != null) {
      _assertPlatformSupport(productChat.providerId);
    }
    return createClient().joinDirect(
      joinInfo,
      chatJoinInfo: chatJoinInfo,
      chatCredentialProvider: chatCredentialProvider,
    );
  });

  /// Adopts a room joined through the advanced client, for example after a
  /// custom Pre-Join flow, while still applying facade error semantics.
  Future<RealtimeRoom> adopt(MediaClient client, MediaRoomSession room) =>
      _guard(() async {
        _assertPlatformSupport(room.providerId);
        final chatProvider = room.chatProvider;
        if (chatProvider != null) _assertPlatformSupport(chatProvider);
        return createClient().adopt(client, room);
      });

  Future<RealtimeRoom> joinRoom({
    required String roomCode,
    required MediaIdentity user,
    String? roomOwnerCredential,
    MediaRole? role,
  }) => _guard(() async {
    return createClient().joinRoomIdentity(
      roomCode: roomCode,
      identity: user,
      roomOwnerCredential: roomOwnerCredential,
      role: role,
    );
  });

  Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } catch (error) {
      throw mapRealtimeException(error);
    }
  }

  void _assertPlatformSupport(String providerId) {
    final registry = driverRegistry;
    if (registry == null ||
        !registry.knowsProvider(providerId) ||
        registry.supportsProvider(providerId)) {
      return;
    }
    throw RealtimeException(
      code: RealtimeErrorCode.unsupportedPlatform,
      message:
          'Provider "$providerId" is not available on '
          '${registry.platform.name}.',
      providerId: providerId,
      suggestedAction: 'choose-supported-provider',
      details: {'platform': registry.platform.name},
    );
  }

  late final _platformReports = RealtimePlatformReports(driverRegistry);
  MediaPreJoinResult _applyPlatformSupportToPreJoin(
    MediaPreJoinResult result,
  ) => _platformReports.preJoin(result);
  MediaDoctorReport _applyPlatformSupportToDoctorReport(
    MediaDoctorReport report,
  ) => _platformReports.doctor(report);
}

Iterable<RealtimeProviderPlugin> _pluginsForRuntime(
  Iterable<RealtimeProviderPlugin> plugins, {
  required RealtimeRuntimePlatform platform,
  required RealtimeProviderWebAssetsLoader webAssetsLoader,
  Future<void> Function(String providerId)? chatAssetsLoader,
}) => platform == RealtimeRuntimePlatform.web
    ? wrapWebProviderPlugins(
        plugins,
        webAssetsLoader,
        chatAssetsLoader: chatAssetsLoader,
      )
    : plugins;
