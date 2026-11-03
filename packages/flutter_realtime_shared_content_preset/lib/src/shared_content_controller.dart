import 'dart:async';
import 'package:flutter_realtime_classroom_core/flutter_realtime_classroom_core.dart';
import 'package:flutter_realtime_whiteboard_core/flutter_realtime_whiteboard_core.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'classroom_shared_content_repository.dart';
import 'shared_content_repository.dart';
import 'shared_content_session.dart';
import 'shared_content_command.dart';
import 'shared_content_whiteboard_repository.dart';

class SharedContentStatus {
  const SharedContentStatus({
    required this.content,
    required this.busy,
    required this.captureActive,
    this.error,
  });
  final SharedContentState? content;
  final bool busy, captureActive;
  final Object? error;
}

/// Coordinates capture and authoritative content state without touching camera/mic.
class SharedContentController {
  SharedContentController({
    required this.media,
    this.classroom,
    SharedContentRepository? repository,
    Duration? pollInterval = const Duration(seconds: 2),
  }) {
    assert(classroom != null || repository != null);
    _contentSession = SharedContentSession(
      repository ??
          ClassroomSharedContentRepository(
            classroom!.repository,
            classroom: classroom,
          ),
      pollInterval: classroom == null ? pollInterval : null,
      onError: (error, stack) => _emit(),
    );
    _hadLocalCapture = media.snapshot.localScreenShareEnabled;
    whiteboard = WhiteboardSession(
      SharedContentWhiteboardRepository(_contentSession),
    );
    _classSub = _contentSession.states.listen((_) {
      if (_openingSystem && content?.canManage != true) {
        unawaited(
          systemAnnotations.stop().catchError((Object e) {
            _error = e;
            _emit();
          }),
        );
      }
      _emit();
    });
    _mediaSub = media.snapshots.listen((_) {
      if (!media.snapshot.localScreenShareEnabled &&
          (systemAnnotations.active || _openingSystem)) {
        unawaited(
          stopSystemAnnotations().catchError((Object e) {
            _error = e;
            _emit();
          }),
        );
      }
      _emit();
      _reconcile();
    });
  }
  final MediaSession media;
  final ClassroomSession? classroom;
  late final SharedContentSession _contentSession;
  late final WhiteboardSession whiteboard;
  SystemAnnotationBridge _systemAnnotations =
      const UnavailableSystemAnnotationBridge();
  SystemAnnotationBridge get systemAnnotations => _systemAnnotations;

  Future<void> setSystemAnnotations(SystemAnnotationBridge bridge) async {
    if (_disposed) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'content.disposed',
      );
    }
    await _systemSub?.cancel();
    await _systemAnnotations.dispose();
    _systemAnnotations = bridge;
    _watchSystemAnnotations();
    _emit();
  }

  Future<void> removeSystemAnnotations(SystemAnnotationBridge bridge) async {
    if (!identical(_systemAnnotations, bridge)) return;
    await _systemSub?.cancel();
    _systemSub = null;
    _systemAnnotations = const UnavailableSystemAnnotationBridge();
    await bridge.dispose();
    if (!_disposed) await _restoreAnnotationLayer();
    _emit();
  }

  void _watchSystemAnnotations() {
    _systemSub = systemAnnotations.changes.listen((_) {
      _emit();
      if (!systemAnnotations.active &&
          _contentSession.canvas.embeddedInVideo &&
          !_openingSystem) {
        unawaited(_restoreAnnotationLayer());
      }
    });
  }

  StreamSubscription<void>? _systemSub;
  bool _openingSystem = false;
  Future<void>? _systemStarting;
  Future<void>? _restoreSystem;
  AnnotationController get screenAnnotations => _contentSession;
  final _statuses = StreamController<SharedContentStatus>.broadcast();
  StreamSubscription<SharedContentState?>? _classSub;
  StreamSubscription<MediaSnapshot>? _mediaSub;
  bool _busy = false, _disposed = false;
  Future<void>? _disposeFuture;
  Duration cleanupTimeout = const Duration(seconds: 10);
  bool _hadLocalCapture = false;
  Object? _error;
  String? _fallbackSource;
  Future<void>? _reconciling;
  Future<void>? _operation;
  SharedContentState? get content => classroom != null
      ? classroom!.state?.tools?.content
      : _contentSession.state;
  bool get supported => content != null;
  SharedContentStatus get status => SharedContentStatus(
    content: content,
    busy: _busy,
    captureActive: media.snapshot.localScreenShareEnabled,
    error: _error ?? _contentSession.lastError ?? systemAnnotations.error,
  );
  Stream<SharedContentStatus> get statuses => _statuses.stream;
  // Drawing updates remain inside the annotation widget, never rebuilding video.
  Stream<Object?> get stageUpdates => statuses
      .map(
        (s) => (
          _contentSession.isLoaded,
          s.content?.mode,
          s.content?.screen.canvasId,
          s.content?.screen.participantId,
        ),
      )
      .distinct();
  bool get canShare =>
      media is InteractiveMediaSession && media.capabilities.canScreenShare;
  Future<void> startSystemAnnotations({
    SystemAnnotationViewport viewport = const SystemAnnotationViewport(),
    String languageCode = 'en',
    bool embeddedInVideo = true,
  }) async {
    if (_disposed || _busy || _openingSystem) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'Content is busy',
      );
    }
    if (!media.snapshot.localScreenShareEnabled ||
        content?.mode != SharedContentMode.screen ||
        content?.canAnnotateScreen != true) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message:
            'Share the primary display before opening system annotation tools',
      );
    }
    if (systemAnnotations.active) return;
    _openingSystem = true;
    final starting = Completer<void>();
    _systemStarting = starting.future;
    try {
      final caps = await systemAnnotations.probe();
      if (!caps.supported) {
        throw RealtimeException(
          code: RealtimeErrorCode.unsupportedFeature,
          message: caps.reason,
        );
      }
      if (_disposed) {
        throw RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'Content controller disposed',
        );
      }
      // User authorization is requested by the SDK immediately on this action,
      // even if an older custom backend later rejects presentation setup.
      await systemAnnotations.requestPermission();
      if (_disposed ||
          !media.snapshot.localScreenShareEnabled ||
          content?.canAnnotateScreen != true) {
        throw RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'The shared screen changed while requesting permission',
        );
      }
      await _restoreSystem;
      await _contentSession.setEmbeddedInVideo(embeddedInVideo);
      if (_contentSession.canvas.embeddedInVideo != embeddedInVideo) {
        throw RealtimeException(
          code: RealtimeErrorCode.unsupportedFeature,
          message:
              'The classroom backend does not support system annotation presentation',
        );
      }
      await systemAnnotations.start(
        viewport: viewport,
        languageCode: languageCode,
      );
      _error = null;
    } catch (e) {
      _error = e;
      await _restoreAnnotationLayer();
      rethrow;
    } finally {
      _openingSystem = false;
      starting.complete();
      _systemStarting = null;
      _emit();
    }
  }

  Future<void> _restoreAnnotationLayer() {
    return _restoreSystem ??= (() async {
      try {
        if (_contentSession.canvas.active &&
            _contentSession.canEdit &&
            _contentSession.canvas.embeddedInVideo) {
          await _contentSession.setEmbeddedInVideo(false);
        }
      } catch (e) {
        _error = e;
        _emit();
      }
    })().whenComplete(() => _restoreSystem = null);
  }

  Future<void> stopSystemAnnotations() async {
    await systemAnnotations.stop();
    await _restoreAnnotationLayer();
    _emit();
  }

  void _emit() {
    if (!_disposed) _statuses.add(status);
  }

  Future<void> start() async {
    try {
      _error = null;
      await _contentSession.start();
      if (supported) await whiteboard.start();
      _emit();
    } catch (e) {
      _error = e;
      _emit();
    }
  }

  String _source() {
    final track = media.snapshot.contentShareTrack;
    if (track?.isLocal == true) return track!.id;
    return _fallbackSource ??=
        'capture-${DateTime.now().microsecondsSinceEpoch}';
  }

  Future<void> _commit(SharedContentMode mode, int revision) =>
      _contentSession.execute(
        SharedContentCommand(SharedContentAction.mode, {
          'mode': mode.name,
          'expectedRevision': revision,
          if (mode == SharedContentMode.screen) 'sourceKey': _source(),
        }),
      );

  /// A screen stop / annotation cleanup can race classroom revision updates.
  /// Refresh before committing and retry only an explicit revision conflict,
  /// never authorization, network or unrelated backend failures.
  Future<void> _commitFresh(SharedContentMode mode) async {
    await _contentSession.refresh();
    if (content == null || !_canSelect(mode)) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'Shared content is no longer manageable.',
        domain: 'sharedContent',
      );
    }
    if (content!.mode == mode &&
        (mode != SharedContentMode.screen ||
            content!.screen.participantId ==
                media.snapshot.localParticipantId)) {
      return;
    }
    try {
      await _commit(mode, content!.revision);
    } on RealtimeException catch (error) {
      if (error.statusCode != 409 ||
          error.details is! Map ||
          (error.details as Map)['backendCode'] != 'content-conflict') {
        rethrow;
      }
      await _contentSession.refresh();
      if (content == null || !_canSelect(mode)) {
        rethrow;
      }
      if (content!.mode == mode &&
          (mode != SharedContentMode.screen ||
              content!.screen.participantId ==
                  media.snapshot.localParticipantId)) {
        return;
      }
      await _commit(mode, content!.revision);
    }
  }

  bool _canSelect(SharedContentMode mode) {
    final state = content;
    if (state == null) return false;
    if (mode == SharedContentMode.whiteboard) return state.whiteboard.canEdit;
    return state.canManage ||
        (mode == SharedContentMode.screen && state.canShareScreen);
  }

  Future<void> selectMode(SharedContentMode mode) {
    if (_busy || _openingSystem) {
      return Future.error(
        const RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'A content change is already in progress',
          domain: 'sharedContent',
        ),
      );
    }
    _busy = true;
    _error = null;
    _emit();
    final result = _switch(mode);
    _operation = result;
    return result.whenComplete(() {
      _busy = false;
      _operation = null;
      _emit();
    });
  }

  Future<void> _switch(SharedContentMode mode) async {
    try {
      if (_disposed) {
        throw RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'Content controller disposed',
        );
      }
      if (!supported) {
        throw RealtimeException(
          code: RealtimeErrorCode.unsupportedFeature,
          message: 'Shared content is unavailable',
        );
      }
      if (!_canSelect(mode)) {
        throw RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'sharedContent.permission',
        );
      }
      final interactive = media is InteractiveMediaSession
          ? media as InteractiveMediaSession
          : null;
      if (mode != SharedContentMode.screen) {
        await stopSystemAnnotations();
        if (media.snapshot.localScreenShareEnabled) {
          if (interactive == null) {
            throw RealtimeException(
              code: RealtimeErrorCode.unsupportedFeature,
              message: 'Cannot stop screen capture',
            );
          }
          await interactive.setScreenShareEnabled(false);
          if (media.snapshot.localScreenShareEnabled) {
            throw RealtimeException(
              code: RealtimeErrorCode.invalidState,
              message: 'Screen capture has not stopped',
            );
          }
          _fallbackSource = null;
          _hadLocalCapture = false;
        }
        try {
          await _commitFresh(mode);
        } catch (e) {
          // Capture has already stopped. Preserve the backend error (notably
          // 401/403/404/409 and its operation) so the UI can distinguish a
          // vanished room from a revision conflict or permission failure.
          // The old invalidState wrapper hid every HTTP failure behind the
          // opaque string "sharedContent.commitAfterCaptureStop".
          final failure = normalizeRealtimeException(
            e,
            domain: 'sharedContent',
            operation: 'commitAfterCaptureStop',
          );
          throw RealtimeException(
            code: failure.code,
            message: failure.message,
            domain: failure.domain,
            operation: failure.operation,
            statusCode: failure.statusCode,
            cause: e,
            recoverable:
                failure.recoverable ||
                failure.code == RealtimeErrorCode.roomConflict ||
                failure.code == RealtimeErrorCode.providerError,
            suggestedAction: switch (failure.code) {
              RealtimeErrorCode.roomNotFound => 'rejoin-room',
              RealtimeErrorCode.forbidden ||
              RealtimeErrorCode.unauthorized => 'check-permissions',
              _ => failure.suggestedAction ?? 'retry-content-change',
            },
            details: {
              'captureActive': false,
              if (failure.details is Map) ...(failure.details as Map),
            },
          );
        }
      } else {
        if (!canShare) {
          throw RealtimeException(
            code: RealtimeErrorCode.unsupportedFeature,
            message: 'Screen sharing unavailable on this provider/platform',
          );
        }
        final started = !media.snapshot.localScreenShareEnabled;
        if (started) {
          await interactive!.setScreenShareEnabled(true);
          if (!media.snapshot.localScreenShareEnabled) {
            throw RealtimeException(
              code: RealtimeErrorCode.invalidState,
              message: 'Screen selection cancelled or capture did not start',
            );
          }
          _fallbackSource = null;
        }
        _hadLocalCapture = true;
        try {
          await _commitFresh(mode);
        } catch (commitError) {
          if (started) {
            try {
              await interactive!.setScreenShareEnabled(false);
              if (media.snapshot.localScreenShareEnabled) {
                throw RealtimeException(
                  code: RealtimeErrorCode.invalidState,
                  message: 'Capture remains active',
                );
              }
              _fallbackSource = null;
              _hadLocalCapture = false;
            } catch (stopError) {
              throw RealtimeException(
                code: RealtimeErrorCode.invalidState,
                message: 'Content change failed and capture remains active.',
                cause: commitError,
                suggestedAction: 'stop-screen-sharing',
                details: {
                  'captureActive': true,
                  'compensationFailure': stopError,
                },
              );
            }
          }
          throw RealtimeException(
            code: RealtimeErrorCode.invalidState,
            message: 'Screen mode could not be committed.',
            cause: commitError,
            recoverable: true,
            suggestedAction: 'retry-content-change',
          );
        }
      }
    } catch (e, stack) {
      try {
        await _contentSession.refresh();
      } catch (refreshError) {
        _error = refreshError;
      }
      _error = normalizeRealtimeException(
        e,
        domain: 'sharedContent',
        stackTrace: stack,
      );
      _emit();
      Error.throwWithStackTrace(_error!, stack);
    }
  }

  void _reconcile() {
    if (_disposed ||
        _busy ||
        _error != null ||
        _reconciling != null ||
        content?.canManage != true) {
      return;
    }
    final active = media.snapshot.localScreenShareEnabled;
    final source = active ? _source() : '';
    final current = content!;
    if (active) _hadLocalCapture = true;
    if (active && current.mode == SharedContentMode.whiteboard) return;
    if (!active &&
        !_hadLocalCapture &&
        current.screen.participantId != media.snapshot.localParticipantId) {
      return;
    }
    if (source == current.screen.sourceKey ||
        (!active && current.mode != SharedContentMode.screen)) {
      return;
    }
    _reconciling = _contentSession
        .setSource(source)
        .catchError((Object e) {
          _error = e;
          _emit();
        })
        .whenComplete(() {
          if (!active) _hadLocalCapture = false;
          _reconciling = null;
        });
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run('classroom.subscription', () async {
      await _classSub?.cancel();
    });
    await cleanup.run('media.subscription', () async {
      await _mediaSub?.cancel();
    });
    await cleanup.run('system.subscription', () async {
      await _systemSub?.cancel();
    });
    await cleanup.run('system.annotations', () async {
      await systemAnnotations.dispose();
    });
    await cleanup.run('system.start', () async {
      await _systemStarting;
    });
    await cleanup.run('system.restore', () async {
      await _restoreAnnotationLayer();
    });
    await cleanup.run('content.operation', () async {
      await _operation;
    });
    await cleanup.run('content.reconcile', () async {
      await _reconciling;
    });
    await cleanup.run('whiteboard', () async {
      await whiteboard.dispose();
    });
    await cleanup.run('content.session', _contentSession.dispose);
    await cleanup.run('statuses', () async {
      await _statuses.close();
    });
    cleanup.finish(domain: 'sharedContent');
  }
}
