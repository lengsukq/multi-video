import 'realtime_video_effects.dart';
import 'members/room_members_controller.dart';
import 'room_recording_controller.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_realtime_interaction_core/flutter_realtime_interaction_core.dart';
import 'dart:async';

// ignore_for_file: prefer_initializing_formals

import 'package:flutter_realtime_chat_core/flutter_realtime_chat_core.dart';
import 'package:flutter_realtime_chat_rtc/flutter_realtime_chat_rtc.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'realtime_error.dart';
import 'realtime_event.dart';
import 'realtime_room_state.dart';
import 'realtime_moderation.dart';
import 'interaction_runtime.dart';
import 'realtime_feature_registry.dart';
import 'realtime_feature_plugin.dart';
import 'realtime_feature_context.dart';

part 'realtime_room_controls.dart';

/// A fully resolved room containing media, rendering and optional chat.
class RealtimeRoom implements MediaBackgroundEffectsController {
  RealtimeRoom({
    required this.media,
    String? publicProviderId,
    required this.renderer,
    this.chat,
    this.interactionControlPlane,
    this.interactionRevisionTransport,
    this.featureBackendUrl,
    this.featureTokenProvider,
    this.featureRequestTimeout,
    Iterable<RealtimeFeaturePlugin<Object>> featurePlugins = const [],
    ChatRoomSession? productChatRoom,
    RtcDataChatSession? rtcChatRoom,
    required void Function() disposeClients,
    RealtimeVideoEffects? videoEffects,
    MediaCloudRecordingSession? cloudRecordingSession,
    MediaBackgroundCapabilities effectsCapabilities =
        const MediaBackgroundCapabilities.none(),
  }) : publicProviderId = publicProviderId ?? media.providerId,
       _productChatRoom = productChatRoom,
       _rtcChatRoom = rtcChatRoom,
       _disposeClients = disposeClients {
    features = RealtimeFeatureRegistry(
      featurePlugins,
      onError: (id, error, stack) => _reportFailure(
        normalizeRealtimeException(
          error,
          domain: 'runtime',
          operation: 'feature.$id',
          providerId: providerId,
          stackTrace: stack,
        ),
      ),
    );
    _effects = videoEffects?.createController(
      media: media,
      capabilities: effectsCapabilities,
      reportError: _reportFailure,
    );
    recording = RoomRecordingController(
      media: media,
      providerId: providerId,
      cloudRecordingSession: cloudRecordingSession,
      onFailure: _reportFailure,
    );
    _mediaEventSubscription = media.session.events.listen(_onMediaEvent);
    _mediaStateSubscription = media.session.states.listen(_onMediaState);
    _backendErrorSubscription = media.backendErrors.listen((error) {
      if (_disposed) return;
      _eventController.add(
        RealtimeBackendFailure(
          mapRealtimeException(error, providerId: providerId),
        ),
      );
    });
    final chatSession = chat;
    if (chatSession != null) {
      _chatEventSubscription = chatSession.events.listen(_onChatEvent);
      _chatStateSubscription = chatSession.states.listen((_) => _emitState());
    }
    // Auxiliary sessions belong to Runtime, not to a particular Widget tree.
    unawaited(initialize());
  }

  final MediaRoomSession media;
  final String publicProviderId;
  final MediaTrackRenderer renderer;

  /// UI-independent RTC + IM roster and moderation operations.
  final RoomMembersController memberDirectory = RoomMembersController();
  final ChatSession? chat;

  late final RealtimeFeatureRegistry features;
  final String? featureBackendUrl;
  final Future<String?> Function()? featureTokenProvider;
  final Duration? featureRequestTimeout;

  /// Optional authoritative state and permission provider supplied by host.
  final InteractionControlPlane? interactionControlPlane;

  /// Optional IM/RTC revision-only hint channel, never a command channel.
  final InteractionRevisionTransport? interactionRevisionTransport;
  InteractionSession? _interactions;

  /// Optional, headless interaction channel for any Meeting/Live room.
  ///
  /// Lazily created to avoid extra subscriptions for applications which only
  /// use media and chat. Does not enable classroom or live business features.
  InteractionSession get interactions {
    if (_disposed) throw StateError('Room has been disposed');
    return _interactions ??= DefaultInteractionSession(
      roomCode: media.roomCode,
      senderId: media.participantId,
      transport: MediaInteractionTransport(media.session),
      controlPlane: interactionControlPlane,
      revisionTransport: interactionRevisionTransport,
    );
  }

  final ChatRoomSession? _productChatRoom;
  final RtcDataChatSession? _rtcChatRoom;
  final void Function() _disposeClients;
  final StreamController<RealtimeEvent> _eventController =
      StreamController<RealtimeEvent>.broadcast();
  final StreamController<RealtimeRoomState> _stateController =
      StreamController<RealtimeRoomState>.broadcast();
  StreamSubscription<MediaEvent>? _mediaEventSubscription;
  StreamSubscription<MediaSessionState>? _mediaStateSubscription;
  StreamSubscription<RealtimeException>? _backendErrorSubscription;
  StreamSubscription<ChatEvent>? _chatEventSubscription;
  StreamSubscription<ChatConnectionState>? _chatStateSubscription;
  bool _disposed = false;
  Future<void>? _disposeFuture;
  Future<void>? _leaveRoomFuture;
  Future<void>? _initializeFuture;

  /// Starts optional classroom/live sessions exactly once per room lifetime.
  /// Failure is reported via [events] and does not disconnect healthy media.
  Future<void> initialize() => _initializeFuture ??= _initialize();

  /// Waits only for room feature attachment (not its initial HTTP snapshot).
  /// SDK callers can safely inspect classroom/live features before rendering.
  Future<void> readyFeatures() => features.initialize(
    RealtimeFeatureContext(
      media: media,
      chat: chat,
      interactions: () => interactions,
      backendUrl: featureBackendUrl,
      tokenProvider: featureTokenProvider,
      requestTimeout: featureRequestTimeout,
      reportError: (error, stack) => _reportFailure(
        normalizeRealtimeException(
          error,
          domain: 'runtime',
          operation: 'feature',
          providerId: providerId,
          stackTrace: stack,
        ),
      ),
    ),
  );

  Future<void> _initialize() async {
    Future<void> start(String operation, Future<void> Function() action) async {
      if (_disposed) return;
      try {
        await action();
      } catch (error, stack) {
        _reportFailure(
          normalizeRealtimeException(
            error,
            domain: 'runtime',
            operation: operation,
            providerId: providerId,
            stackTrace: stack,
          ),
        );
      }
    }

    // Registration runs synchronously until its first unresolved async attach.
    // Start those ready presets immediately; a slow unrelated feature must
    // not hold up the initial Classroom/Live authoritative snapshot.
    final attachment = readyFeatures();
    await start('features.start', features.startAttached);
    if (_disposed) return;
    await start('features.attach', () => attachment);
  }

  Duration cleanupTimeout = const Duration(seconds: 10);

  /// Whether [dispose] has started on this room.
  bool get isDisposed => _disposed;

  /// Whether a local leave, close, or disposal operation is in progress.
  bool get isLeaving =>
      _disposed || _leaveRoomFuture != null || media.isLeavingOrClosing;

  String get roomCode => media.roomCode;
  String get providerId => publicProviderId;
  String get engineProviderId => media.providerId;
  String? get chatProvider => media.chatProvider;
  bool get usesProductChat => _productChatRoom != null;
  bool get usesRtcDataChat => _rtcChatRoom != null;
  RealtimeRoomCapabilities get capabilities => RealtimeRoomCapabilities(
    media: media.session.capabilities,
    chat: chat?.capabilities,
  );
  late final RealtimeVideoEffectsController? _effects;
  @override
  MediaBackgroundCapabilities get backgroundCapabilities =>
      _effects?.backgroundCapabilities ??
      const MediaBackgroundCapabilities.none();
  @override
  MediaBackgroundEffect get backgroundEffect =>
      _effects?.backgroundEffect ?? const MediaBackgroundEffect.none();
  Future<void> prepareVideoEffects(MediaLocalPreviewSettings settings) =>
      _effects?.prepareVideoEffects(settings) ?? Future<void>.value();

  /// Set camera publication through the SDK's video-effects pipeline.
  ///
  /// Unlike calling `room.media.session.setVideoEnabled` directly, this
  /// serializes camera changes with background selection when the installed
  /// effects controller supports coordination. Headless clients should use
  /// this whenever they expose virtual backgrounds.
  Future<void> setCameraEnabled(bool enabled) {
    if (_disposed) {
      return Future<void>.error(
        const RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'The room has been disposed.',
        ),
      );
    }
    final effects = _effects;
    if (effects is RealtimeCameraEffectsController) {
      return (effects as RealtimeCameraEffectsController).setCameraEnabled(
        enabled,
      );
    }
    final session = media.session;
    if (session is InteractiveMediaSession &&
        session.capabilities.canPublishVideo) {
      return session.setVideoEnabled(enabled);
    }
    return Future<void>.error(
      RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'Camera publishing is unavailable for this room.',
        providerId: providerId,
      ),
    );
  }

  @override
  Future<void> setBackgroundEffect(MediaBackgroundEffect effect) =>
      _effects?.setBackgroundEffect(effect) ??
      (effect.enabled
          ? Future<void>.error(
              const RealtimeException(
                code: RealtimeErrorCode.unsupportedFeature,
                message: 'videoEffects.unregistered',
              ),
            )
          : Future<void>.value());

  List<MediaParticipant> get participants =>
      List.unmodifiable(media.snapshot.participants);
  RealtimeRoomState get state => RealtimeRoomState(
    media: media.session.state,
    chat: chat?.state,
    participants: participants,
    capabilities: capabilities,
  );
  Stream<RealtimeRoomState> get states => _stateController.stream;
  Stream<RealtimeEvent> get events => _eventController.stream;
  RealtimeMediaModeration get mediaModeration => RealtimeMediaModeration(media);
  RealtimeChatModeration? get chatModeration => chat == null
      ? null
      : RealtimeChatModeration(chat!, _productChatRoom?.moderation);

  /// Recording controller for this room session.
  late final RoomRecordingController recording;
  MediaRecordingController get recordingController => recording;

  /// Current recording status of the room.
  RecordingStatus get recordingStatus => recording.status;

  /// Emits recording status changes.
  Stream<RecordingStatus> get recordingStatuses => recording.statuses;

  /// Emits recorded duration updates every second.
  Stream<Duration> get recordingDurations => recording.durations;

  /// Starts recording with optional [options].
  ///
  /// Uses cloud recording through the configured backend.
  Future<RecordingResult> startRecording([RecordingOptions? options]) =>
      recording.startRecording(options);

  /// Stops the active recording session and finishes writing files.
  Future<RecordingResult?> stopRecording() => recording.stopRecording();

  /// Queries real cloud recording finalization state after stop.
  Future<RecordingResult> queryCloudRecording() =>
      recording.queryCloudRecording();

  /// Returns a short-lived signed download URL once the recording is complete.
  Future<Uri> cloudRecordingDownloadUrl() =>
      recording.cloudRecordingDownloadUrl();

  /// Generates a structured [CloudRecordingDescriptor] containing official
  /// vendor API endpoints, HTTP headers, and request body payloads.
  CloudRecordingDescriptor describeCloudRecording([
    RecordingOptions? options,
  ]) => recording.describeCloudRecording(options);

  void _onMediaState(MediaSessionState state) {
    _emitState();
    if (_disposed ||
        (state != MediaSessionState.ended &&
            state != MediaSessionState.failed &&
            state != MediaSessionState.disposed)) {
      return;
    }
    unawaited(
      (_effects?.release() ?? Future<void>.value()).catchError((
        Object error,
        StackTrace stack,
      ) {
        _reportFailure(
          normalizeRealtimeException(
            error,
            domain: 'room.effects.release',
            stackTrace: stack,
          ),
        );
      }),
    );
  }

  final List<RealtimeException> _diagnostics = [];
  List<RealtimeException> get diagnostics => List.unmodifiable(_diagnostics);

  /// Retains late failures even after room event streams have closed.
  void reportLifecycleFailure(RealtimeException error) => _reportFailure(error);

  void _reportFailure(RealtimeException error) {
    if (_diagnostics.length == 64) _diagnostics.removeAt(0);
    _diagnostics.add(error);
    if (!_disposed) _eventController.add(RealtimeBackendFailure(error));
  }

  void _onMediaEvent(MediaEvent event) {
    if (_disposed) return;
    _eventController.add(RealtimeMediaEvent(event));
    _emitState();
  }

  void _onChatEvent(ChatEvent event) {
    if (_disposed) return;
    _eventController.add(RealtimeChatEvent(event));
    _emitState();
  }

  void _emitState() {
    if (_disposed) return;
    final value = state;
    _stateController.add(value);
    _eventController.add(RealtimeStateChanged(value));
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _effects?.beginDisposal();
    final cleanup = Cleanup(timeout: cleanupTimeout);
    // Startup may be waiting on a remote snapshot indefinitely; disposal
    // must cancel/close the auxiliary sessions without waiting for that read.
    // Late startup errors are ignored once _disposed is set.
    await cleanup.run('recording', recording.dispose);
    await cleanup.run('video.effects', () async {
      await _effects?.dispose();
    });
    await cleanup.run('features', features.dispose);
    await cleanup.run('interactions', () async {
      await _interactions?.dispose();
      // No interaction session was ever requested: still release any prepared
      // revision adapter (which never owns the room's chat/media sessions).
      if (_interactions == null) await interactionRevisionTransport?.dispose();
    });
    await cleanup.run('media.events', () async {
      await _mediaEventSubscription?.cancel();
    });
    await cleanup.run('media.states', () async {
      await _mediaStateSubscription?.cancel();
    });
    await cleanup.run('backend.errors', () async {
      await _backendErrorSubscription?.cancel();
    });
    await cleanup.run('chat.events', () async {
      await _chatEventSubscription?.cancel();
    });
    await cleanup.run('chat.states', () async {
      await _chatStateSubscription?.cancel();
    });
    await cleanup.run('chat.product', () async {
      await _productChatRoom?.dispose();
    });
    await cleanup.run('chat.rtc', () async {
      await _rtcChatRoom?.dispose();
    });
    await cleanup.run('media', () async {
      await media.dispose();
    });
    await cleanup.run('states', () async {
      await _stateController.close();
    });
    await cleanup.run('events', () async {
      await _eventController.close();
    });
    await cleanup.run('clients', () async {
      _disposeClients();
    });
    cleanup.finish(domain: 'room');
  }
}
