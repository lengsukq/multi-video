import 'whiteboard_command.dart';
import 'package:flutter_realtime_foundation/flutter_realtime_foundation.dart';
import 'dart:async';
import 'dart:math';
import 'annotation_canvas.dart';
import 'annotation_controller.dart';
import 'annotation_point.dart';
import 'annotation_shape.dart';
import 'memory_whiteboard_repository.dart';
import 'whiteboard_repository.dart';
import 'whiteboard_state.dart';

class WhiteboardSession implements AnnotationController {
  WhiteboardSession(this.repository, {this.ownsRepository = true});
  factory WhiteboardSession.local({bool canEdit = true, int maxPages = 20}) =>
      WhiteboardSession(
        MemoryWhiteboardRepository(canEdit: canEdit, maxPages: maxPages),
      );
  final WhiteboardRepository repository;
  final bool ownsRepository;
  final _states = StreamController<WhiteboardState>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  static final _random = Random.secure();
  WhiteboardState? _state;
  StreamSubscription<WhiteboardState>? _subscription;
  Future<void>? _queue;
  Future<void>? _starting;
  bool _disposed = false;
  Future<void>? _disposeFuture;
  Duration cleanupTimeout = const Duration(seconds: 10);
  WhiteboardState? get state => _state;
  Stream<WhiteboardState> get states => _states.stream;
  Stream<Object> get errors => _errors.stream;
  @override
  AnnotationCanvas get canvas => _state?.canvas ?? AnnotationCanvas();
  @override
  Stream<AnnotationCanvas> get canvases => states.map((s) => s.canvas);
  @override
  bool get canEdit => _state?.canEdit ?? false;
  void _accept(WhiteboardState value) {
    if (_disposed || (_state != null && value.revision < _state!.revision)) {
      return;
    }
    _state = value;
    _states.add(value);
  }

  Future<void> start() {
    if (_disposed) {
      return Future.error(
        const RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'Whiteboard disposed',
          domain: 'whiteboard',
        ),
      );
    }

    if (_state != null) return Future<void>.value();
    return _starting ??=
        (() async {
          _subscription ??= repository.states.listen(
            _accept,
            onError: (Object e) {
              if (!_disposed) _errors.add(e);
            },
          );
          await refresh();
        })().whenComplete(() {
          _starting = null;
        });
  }

  Future<void> refresh() async {
    if (_disposed) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'Whiteboard disposed',
      );
    }
    try {
      _accept(await repository.snapshot());
    } catch (error, stack) {
      Error.throwWithStackTrace(
        normalizeRealtimeException(
          error,
          domain: 'whiteboard',
          operation: 'snapshot',
          stackTrace: stack,
        ),
        stack,
      );
    }
  }

  Future<void> _act(WhiteboardAction action, Map<String, Object?> data) {
    final result = (_queue ?? Future<void>.value()).then((_) async {
      if (_disposed) {
        throw RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'Whiteboard disposed',
        );
      }
      if (_state == null) await start();
      if (!canEdit) {
        throw RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'Whiteboard is read-only',
        );
      }
      try {
        _accept(
          await repository.action(
            WhiteboardCommand(
              action,
              {...data, 'expectedRevision': _state!.revision},
              eventId:
                  '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(0x100000000)}',
            ),
          ),
        );
      } catch (error, stack) {
        Error.throwWithStackTrace(
          normalizeRealtimeException(
            error,
            domain: 'whiteboard',
            operation: action.wireName,
            stackTrace: stack,
          ),
          stack,
        );
      }
    });
    final tail = result.catchError((Object e) {
      if (!_disposed) _errors.add(e);
    });
    _queue = tail;
    unawaited(
      tail.then((_) {
        if (identical(_queue, tail)) _queue = null;
      }),
    );
    return result;
  }

  Future<void> addPage({String? title}) => _act(WhiteboardAction.pageAdd, {
    'title': title ?? 'Page ${(_state?.pages.length ?? 0) + 1}',
  });
  Future<void> selectPage(String pageId) =>
      _act(WhiteboardAction.pageSelect, {'pageId': pageId});
  Future<void> deletePage(String pageId) =>
      _act(WhiteboardAction.pageDelete, {'pageId': pageId});
  Map<String, Object?> _target(String canvasId) => {
    'canvasId': canvasId,
    'pageId': canvas.sourceKey,
  };
  @override
  Future<void> begin(AnnotationShape shape, {required String canvasId}) =>
      _act(WhiteboardAction.begin, {..._target(canvasId), ...shape.toJson()});
  @override
  Future<void> append(
    String shapeId,
    List<AnnotationPoint> points, {
    required String canvasId,
  }) => _act(WhiteboardAction.append, {
    ..._target(canvasId),
    'id': shapeId,
    'points': points.map((p) => p.toJson()).toList(),
  });
  @override
  Future<void> erase(String shapeId, {required String canvasId}) =>
      _act(WhiteboardAction.erase, {..._target(canvasId), 'id': shapeId});
  @override
  Future<void> undo() => _act(WhiteboardAction.undo, _target(canvas.canvasId));
  @override
  Future<void> clear() =>
      _act(WhiteboardAction.clear, _target(canvas.canvasId));
  Future<void> dispose() => _disposeFuture ??= _dispose();
  Future<void> _dispose() async {
    _disposed = true;
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run('whiteboard.subscription', () async {
      await _subscription?.cancel();
    });
    await cleanup.run('whiteboard.queue', () async {
      await _queue;
    });
    if (ownsRepository) {
      await cleanup.run('whiteboard.repository', repository.close);
    }
    await cleanup.run('whiteboard.states', _states.close);
    await cleanup.run('whiteboard.errors', _errors.close);
    cleanup.finish(domain: 'whiteboard');
  }
}
