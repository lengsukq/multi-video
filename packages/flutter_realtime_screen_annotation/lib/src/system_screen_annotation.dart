import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_whiteboard_core/flutter_realtime_whiteboard_core.dart';

/// Provider-neutral bridge to system drawing windows. The host owns screen
/// capture and supplies an authoritative [AnnotationController].
class SystemScreenAnnotationController implements SystemAnnotationBridge {
  SystemScreenAnnotationController({required this.annotations});
  final AnnotationController annotations;
  static const _channel = MethodChannel('flutter_realtime_screen_annotation');
  static SystemScreenAnnotationController? _owner;
  final _states = StreamController<void>.broadcast();
  @override
  Stream<void> get changes => _states.stream;
  StreamSubscription<AnnotationCanvas>? _canvasSub;
  final _pending = <String, (AnnotationShape, bool)>{};
  final _uploaded = <String, int>{};
  final _order = Queue<String>();
  final _commands = <String, String>{};
  int _commandId = 0;
  Future<void>? _pump;
  Future<void> _lifecycle = Future.value();
  bool _active = false, _disposed = false;
  Future<void>? _disposeFuture;
  Duration cleanupTimeout = const Duration(seconds: 10);
  bool _clearOnClose = false;
  Object? _error;
  String _canvasId = '', _sessionId = '';
  @override
  bool get active => _active;
  @override
  Object? get error => _error;
  static final _random = math.Random.secure();
  void _emit() {
    if (!_disposed) _states.add(null);
  }

  @override
  Future<SystemAnnotationCapabilities> probe() => capabilities();

  static Future<SystemAnnotationCapabilities> capabilities() async {
    if (kIsWeb ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.fuchsia) {
      return const SystemAnnotationCapabilities(
        supported: false,
        reason:
            'This platform supports classroom annotation, but not drawing over other apps.',
      );
    }
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>(
        'capabilities',
      );
      return SystemAnnotationCapabilities(
        supported: value?['supported'] == true,
        permissionRequired: value?['permissionRequired'] == true,
        reason: value?['reason'] as String? ?? '',
      );
    } on MissingPluginException {
      return const SystemAnnotationCapabilities(
        supported: false,
        reason: 'System annotation plugin is not registered.',
      );
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _lifecycle.then((_) => action()).catchError((
      Object error,
      StackTrace stack,
    ) {
      Error.throwWithStackTrace(
        normalizeRealtimeException(
          error,
          domain: 'annotation',
          stackTrace: stack,
        ),
        stack,
      );
    });
    _lifecycle = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Request overlay access on user intent, before optional backend setup.
  /// Android opens its system settings only when access has not been granted.
  @override
  Future<void> requestPermission() => _serial(() async {
    if (_disposed) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'System annotations disposed',
      );
    }
    final caps = await capabilities();
    if (!caps.supported) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: caps.reason,
      );
    }
    if (_disposed) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'System annotations disposed',
      );
    }
    if (_active || !caps.permissionRequired) return;
    if (_owner != null && _owner != this) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'Another room owns the system annotation window',
      );
    }
    _owner = this;
    _sessionId =
        '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(0x100000000)}';
    try {
      if (await _channel.invokeMethod<bool>('requestPermission') != true) {
        throw RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message:
              'Allow drawing over other apps in Android settings, then retry.',
        );
      }
      if (_disposed) {
        throw RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'System annotations disposed',
        );
      }
    } finally {
      if (_owner == this) _owner = null;
    }
  });

  @override
  Future<void> start({
    SystemAnnotationViewport viewport = const SystemAnnotationViewport(),
    String languageCode = 'en',
  }) => _serial(() async {
    if (_disposed) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'System annotations disposed',
      );
    }
    if (_active) return;
    if (_owner != null && _owner != this) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'Another room owns the system annotation window',
      );
    }
    if (!annotations.canEdit || !annotations.canvas.active) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'An editable shared screen is required',
      );
    }
    final caps = await capabilities();
    if (_disposed) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'System annotations disposed',
      );
    }
    if (!caps.supported) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: caps.reason,
      );
    }
    if (_owner != null && _owner != this) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'Another room owns the system annotation window',
      );
    }
    final rect = viewport.toJson();
    _owner = this;
    _sessionId =
        '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(0x100000000)}';
    _canvasId = annotations.canvas.canvasId;
    _error = null;
    try {
      _channel.setMethodCallHandler(_onNative);
      if (caps.permissionRequired &&
          await _channel.invokeMethod<bool>('requestPermission') != true) {
        throw RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message:
              'Allow drawing over other apps in Android settings, then retry.',
        );
      }
      // Permission dialogs may outlive a screen share or teacher privilege.
      if (_disposed ||
          !annotations.canEdit ||
          annotations.canvas.canvasId != _canvasId ||
          !annotations.canvas.active) {
        throw RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'The shared screen changed while requesting permission',
        );
      }
      _canvasSub = annotations.canvases.listen((canvas) {
        if (!canvas.active ||
            canvas.canvasId != _canvasId ||
            !annotations.canEdit) {
          unawaited(
            stop().catchError((Object e) {
              _error = e;
              _emit();
            }),
          );
        } else if (_active) {
          unawaited(
            _render().catchError((Object e) {
              _error = e;
              _emit();
            }),
          );
        }
      });
      await _channel.invokeMethod<void>('open', {
        'sessionId': _sessionId,
        'canvasId': _canvasId,
        'viewport': rect,
        'languageCode': languageCode,
        'shapes': annotations.canvas.shapes.map((s) => s.toJson()).toList(),
      });
      _active = true;
      await _render();
      _emit();
    } catch (e) {
      _error = e;
      await _close();
      _emit();
      rethrow;
    }
  });

  Future<void> _render() => _channel.invokeMethod<void>('update', {
    'sessionId': _sessionId,
    'shapes': annotations.canvas.shapes.map((s) => s.toJson()).toList(),
    'error': _error?.toString(),
  });

  Future<dynamic> _onNative(MethodCall call) async {
    if (call.method != 'event' || !_active || _disposed) return null;
    final event = Map<String, dynamic>.from(call.arguments as Map);
    if (event['sessionId'] != _sessionId) return null;
    switch (event['type']) {
      case 'closed':
      case 'geometryChanged':
        if (event['type'] == 'geometryChanged') {
          _clearOnClose = true;
          _error = StateError(
            'Display changed; restart annotations on the new shared screen.',
          );
        }
        unawaited(
          stop().catchError((Object e) {
            _error = e;
            _emit();
          }),
        );
      case 'stroke':
        if (_error != null ||
            !annotations.canEdit ||
            annotations.canvas.canvasId != _canvasId) {
          return null;
        }
        final shape = AnnotationShape.fromJson(
          Map<String, dynamic>.from(event['shape'] as Map),
        );
        if (shape.points.isEmpty ||
            shape.points.length > 2048 ||
            shape.text.length > 200 ||
            shape.width < 1 ||
            shape.width > 20 ||
            shape.points.any(
              (p) =>
                  !p.x.isFinite ||
                  !p.y.isFinite ||
                  p.x < 0 ||
                  p.x > 1 ||
                  p.y < 0 ||
                  p.y > 1,
            )) {
          return null;
        }
        if (_pending.length >= 8 && !_pending.containsKey(shape.id)) {
          await _fail(
            StateError(
              'Annotation synchronization is busy; reopen tools to retry.',
            ),
          );
          return null;
        }
        if (!_pending.containsKey(shape.id)) _order.add(shape.id);
        _pending[shape.id] = (shape, event['finished'] == true);
        _schedulePump();
      case 'undo':
      case 'clear':
        if (_error != null) return null;
        if (_commands.length >= 8) {
          await _fail(
            StateError(
              'Annotation synchronization is busy; reopen tools to retry.',
            ),
          );
          return null;
        }
        final key = '@command-${_commandId++}';
        _commands[key] = event['type'] as String;
        _order.add(key);
        _schedulePump();
    }
    return null;
  }

  void _schedulePump() {
    if (_pump != null) return;
    _pump = _drain().whenComplete(() {
      _pump = null;
      if (_order.isNotEmpty && _active && _error == null) _schedulePump();
    });
  }

  Future<void> _drain() async {
    while (_order.isNotEmpty && _active && _error == null) {
      final id = _order.removeFirst();
      final command = _commands.remove(id);
      if (command != null) {
        try {
          if (!annotations.canEdit ||
              annotations.canvas.canvasId != _canvasId) {
            return;
          }
          if (command == 'undo') {
            await annotations.undo();
          } else {
            await annotations.clear();
          }
          if (_active) await _render();
        } catch (e) {
          await _fail(e);
        }
        continue;
      }
      final (shape, finished) = _pending.remove(id)!;
      final freehand =
          shape.tool == AnnotationTool.pen ||
          shape.tool == AnnotationTool.highlight;
      if (!freehand && !finished) continue;
      try {
        if (!annotations.canEdit || annotations.canvas.canvasId != _canvasId) {
          return;
        }
        var count = _uploaded[id] ?? 0;
        if (count == 0) {
          final batch = shape.points.take(freehand ? 100 : 2).toList();
          await annotations.begin(
            AnnotationShape(
              id: id,
              tool: shape.tool,
              points: batch,
              text: shape.text,
              color: shape.color,
              width: shape.width,
            ),
            canvasId: _canvasId,
          );
          count = batch.length;
        }
        while (freehand && count < shape.points.length) {
          if (!_active ||
              annotations.canvas.canvasId != _canvasId ||
              !annotations.canEdit) {
            return;
          }
          final end = math.min(count + 100, shape.points.length);
          await annotations.append(
            id,
            shape.points.sublist(count, end),
            canvasId: _canvasId,
          );
          count = end;
        }
        _uploaded[id] = count;
        if (finished && _active) {
          await _channel.invokeMethod<void>('ack', {
            'sessionId': _sessionId,
            'id': id,
          });
          _uploaded.remove(id);
        }
      } catch (e) {
        await _fail(e);
      }
    }
  }

  Future<void> _fail(Object e) async {
    _error = e;
    _pending.clear();
    _commands.clear();
    _order.clear();
    _emit();
    if (_active) {
      try {
        await _render();
      } catch (_) {}
    }
  }

  @override
  Future<void> stop() {
    if (!_active && _owner == this) {
      // Cancel a settings request without waiting for the lifecycle queue it
      // currently occupies. The settings page itself remains user-controlled.
      unawaited(
        _channel
            .invokeMethod<void>('cancel', {'sessionId': _sessionId})
            .catchError((Object _) {}),
      );
    }
    return _serial(_close);
  }

  Future<void> _close() async {
    await _canvasSub?.cancel();
    _canvasSub = null;
    if (_owner == this) {
      try {
        await _channel.invokeMethod<void>('close', {'sessionId': _sessionId});
      } finally {
        _owner = null;
        _channel.setMethodCallHandler(null);
      }
    }
    // Remove the system windows immediately, but finish already accepted
    // strokes in order while their canvas and editing authority remain valid.
    await _pump;
    _active = false;
    _pending.clear();
    _commands.clear();
    _order.clear();
    _uploaded.clear();
    if (_clearOnClose &&
        annotations.canEdit &&
        annotations.canvas.canvasId == _canvasId) {
      try {
        await annotations.clear();
      } catch (e) {
        _error = e;
      }
    }
    _clearOnClose = false;
    _emit();
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();
  Future<void> _dispose() async {
    _disposed = true;
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run('system.windows', stop);
    await cleanup.run('system.states', _states.close);
    cleanup.finish(domain: 'annotation');
  }
}
