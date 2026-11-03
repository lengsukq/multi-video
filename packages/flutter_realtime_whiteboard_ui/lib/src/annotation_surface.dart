import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_realtime_design_ui/flutter_realtime_design_ui.dart';
import 'package:flutter_realtime_whiteboard_core/flutter_realtime_whiteboard_core.dart';
import 'whiteboard_strings.dart';
import 'movable_annotation_toolbar.dart';
import 'annotation_toolbar.dart';
import 'annotation_hit_test.dart';

enum AnnotationToolbarPlacement { floating, fixedTop, none }

/// This widget must occupy the contained shared-video rectangle (not the full
/// viewport). Its logical points then align on phones, tablets and desktops.
class AnnotationSurface extends StatefulWidget {
  const AnnotationSurface({
    super.key,
    required this.session,
    this.background,
    this.allowEditing = true,
    this.enableNavigation = true,
    this.toolbarAtTop = false,
    this.constrainToolbarToCanvas = false,
    this.toolbarPlacement = AnnotationToolbarPlacement.floating,
    this.initialColor = 0xfff59e0b,
    this.tool,
    this.selectedColor,
    this.drawingEnabled,
    this.onToolChanged,
    this.editTooltip,
    this.transformationController,
    this.infiniteCanvas = false,
    this.onViewportTransformChanged,
  });
  final AnnotationController session;
  final Widget? background;
  final bool allowEditing;
  final bool enableNavigation;
  final bool toolbarAtTop;

  /// Keeps floating tools inside a shared image instead of over side panels.
  final bool constrainToolbarToCanvas;
  final AnnotationToolbarPlacement toolbarPlacement;
  final int initialColor;
  final AnnotationTool? tool;
  final int? selectedColor;
  final bool? drawingEnabled;
  final ValueChanged<AnnotationTool>? onToolChanged;
  final String? editTooltip;

  /// Host-owned zoom/pan transform. When null the surface owns one.
  final TransformationController? transformationController;

  /// Unbounded, shared whiteboard world. Screen-share overlays remain fitted.
  final bool infiniteCanvas;
  final ValueChanged<double>? onViewportTransformChanged;
  @override
  State<AnnotationSurface> createState() => _AnnotationSurfaceState();
}

class _AnnotationSurfaceState extends State<AnnotationSurface> {
  AnnotationTool _tool = AnnotationTool.pen;
  bool _editing = false;
  late int _selectedColor = widget.initialColor;
  AnnotationTool get _activeTool => widget.tool ?? _tool;
  bool get _isEditing => widget.drawingEnabled ?? _editing;
  int get _activeColor => widget.selectedColor ?? _selectedColor;
  AnnotationShape? _draft;
  final _batch = <AnnotationPoint>[];
  Timer? _flushTimer;
  Future<void> _work = Future.value();
  String? _failedStroke;
  Object? _error;
  bool _finishing = false;
  final _pendingErasures = <String>{};
  static final _random = math.Random.secure();
  String _canvasId = '';
  TransformationController? _ownedTransform;
  TransformationController get _transform =>
      widget.transformationController ??
      (_ownedTransform ??= TransformationController());
  static const Size infiniteSceneSize = Size(1600, 900);
  final _activePointers = <int>{};
  final _pointerDownPositions = <int, Offset>{};
  final _pointerPositions = <int, Offset>{};
  // A two-finger gesture is driven by actual pointer positions. Flutter's
  // ScaleUpdateDetails.scale may rebase when the number of touches changes,
  // which makes incremental ratios jump during a mobile pinch.
  bool _pinchUsed = false;
  double _pinchStartRadius = 1;
  double _pinchStartScale = 1;
  Offset? _pinchAnchorScene;
  Offset? _previousFocal;
  @override
  void dispose() {
    _flushTimer?.cancel();
    _ownedTransform?.dispose();
    super.dispose();
  }

  void _eraseAt(Offset offset, Size size) {
    if (_draft != null ||
        _finishing ||
        !widget.session.canEdit ||
        !widget.session.canvas.active) {
      return;
    }
    final canvas = widget.session.canvas;
    final target = findErasableShape(
      canvas.shapes.where((shape) => !_pendingErasures.contains(shape.id)),
      _transform.toScene(offset),
      size,
      radius: 14 / _transform.value.getMaxScaleOnAxis(),
      fontFamily: RealtimeFonts.bodyOf(context),
    );
    if (target == null) return;
    _pendingErasures.add(target.id);
    _enqueue(() async {
      try {
        await widget.session.erase(target.id, canvasId: canvas.canvasId);
      } finally {
        _pendingErasures.remove(target.id);
      }
    });
  }

  AnnotationPoint _point(Offset offset, Size size) {
    final scene = _transform.toScene(offset);
    return AnnotationPoint(
      widget.infiniteCanvas
          ? scene.dx / size.width
          : (scene.dx / size.width).clamp(0.0, 1.0),
      widget.infiniteCanvas
          ? scene.dy / size.height
          : (scene.dy / size.height).clamp(0.0, 1.0),
    );
  }

  void _navigate(Offset focal) {
    final previous = _previousFocal;
    if (previous == null) {
      _previousFocal = focal;
      return;
    }
    final current = _transform.value.getMaxScaleOnAxis();
    final anchor = _transform.toScene(previous);
    final offset = focal - anchor * current;
    _transform.value = Matrix4.identity()
      ..translateByDouble(offset.dx, offset.dy, 0, 1)
      ..scaleByDouble(current, current, 1, 1);
    _previousFocal = focal;
  }

  (Offset, double) _pinchGeometry() {
    final positions = _pointerPositions.values.toList(growable: false);
    final center =
        positions.reduce((a, b) => a + b) / positions.length.toDouble();
    final squaredRadius = positions.fold<double>(
      0,
      (sum, point) => sum + (point - center).distanceSquared,
    );
    return (center, math.sqrt(squaredRadius / positions.length));
  }

  void _rebasePinch() {
    if (_pointerPositions.length < 2) {
      _pinchAnchorScene = null;
      return;
    }
    final (center, radius) = _pinchGeometry();
    _pinchAnchorScene = _transform.toScene(center);
    _pinchStartScale = _transform.value.getMaxScaleOnAxis();
    _pinchStartRadius = radius;
  }

  void _updatePinch() {
    final anchor = _pinchAnchorScene;
    if (anchor == null) return;
    final (center, radius) = _pinchGeometry();
    final ratio = _pinchStartRadius < 1 ? 1.0 : radius / _pinchStartRadius;
    final next = (_pinchStartScale * ratio).clamp(0.25, 8.0);
    final offset = center - anchor * next;
    _transform.value = Matrix4.identity()
      ..translateByDouble(offset.dx, offset.dy, 0, 1)
      ..scaleByDouble(next, next, 1, 1);
    widget.onViewportTransformChanged?.call(next);
  }

  Widget _infiniteViewport(
    BuildContext context,
    AnnotationCanvas canvas,
    bool teacher,
    bool matches,
    Size viewport,
  ) {
    final shapes = <AnnotationShape>[
      if (matches && !canvas.embeddedInVideo)
        ...canvas.shapes.where((shape) => shape.id != _draft?.id),
      if (matches &&
          !canvas.embeddedInVideo &&
          _draft != null &&
          _canvasId == canvas.canvasId)
        _draft!,
    ];
    return Listener(
      onPointerDown: (e) {
        if (_activePointers.isEmpty) _pinchUsed = false;
        _activePointers.add(e.pointer);
        _pointerDownPositions[e.pointer] = e.localPosition;
        _pointerPositions[e.pointer] = e.localPosition;
        if (_activePointers.length > 1) {
          _pinchUsed = true;
          _finish();
          _rebasePinch();
        }
      },
      onPointerMove: (e) {
        if (!_pointerPositions.containsKey(e.pointer)) return;
        _pointerPositions[e.pointer] = e.localPosition;
        if (_pointerPositions.length > 1) _updatePinch();
      },
      onPointerUp: (e) {
        _activePointers.remove(e.pointer);
        _pointerDownPositions.remove(e.pointer);
        _pointerPositions.remove(e.pointer);
        _rebasePinch();
      },
      onPointerCancel: (e) {
        _activePointers.remove(e.pointer);
        _pointerDownPositions.remove(e.pointer);
        _pointerPositions.remove(e.pointer);
        _rebasePinch();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (details) {
          _previousFocal = details.localFocalPoint;
          // Wait for a one-pointer move before starting ink. A second finger
          // can arrive immediately after the first touch; creating a stroke
          // here would leave a phantom mark after every pinch.
        },
        onScaleUpdate: (details) {
          // Once a pinch starts, the remaining finger must not start an ink
          // stroke or a one-finger pan until every touch is released.
          if (_pinchUsed || details.pointerCount > 1) return;
          if (teacher && _isEditing) {
            if (_draft != null) {
              _update(details.localFocalPoint, infiniteSceneSize);
            } else if (_activeTool != AnnotationTool.text && !_finishing) {
              final start = _activePointers.length == 1
                  ? _pointerDownPositions[_activePointers.single]
                  : null;
              _start(start ?? details.localFocalPoint, infiniteSceneSize);
              _update(details.localFocalPoint, infiniteSceneSize);
            }
          } else {
            _navigate(details.localFocalPoint);
          }
        },
        onScaleEnd: (_) {
          _finish();
          _previousFocal = null;
        },
        // Do not mount a competing tap recognizer for pen/highlight strokes;
        // it can win the gesture arena on short drags and swallow the ink.
        onTapUp:
            teacher &&
                _isEditing &&
                (_activeTool == AnnotationTool.text ||
                    _activeTool == AnnotationTool.eraser)
            ? (e) {
                if (_pinchUsed) return;
                if (_activeTool == AnnotationTool.text) {
                  unawaited(_label(e.localPosition, infiniteSceneSize));
                } else if (_activeTool == AnnotationTool.eraser) {
                  _eraseAt(e.localPosition, infiniteSceneSize);
                }
              }
            : null,
        child: ClipRect(
          child: CustomPaint(
            size: viewport,
            painter: _InfiniteWhiteboardPainter(
              shapes: shapes,
              transform: _transform,
              sceneSize: infiniteSceneSize,
              fontFamily: RealtimeFonts.bodyOf(context),
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  void _enqueue(Future<void> Function() operation, {String? strokeId}) {
    _work = _work.then((_) async {
      if (strokeId != null && _failedStroke == strokeId) return;
      try {
        await operation();
      } catch (e) {
        if (strokeId != null) _failedStroke = strokeId;
        if (mounted) setState(() => _error = e);
      }
    });
  }

  void _start(Offset offset, Size size) {
    if (_activeTool == AnnotationTool.eraser) {
      _eraseAt(offset, size);
      return;
    }
    if (_finishing || _draft != null) return;
    final canvas = widget.session.canvas;
    if (!canvas.active) return;
    final id =
        '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(0x100000000)}';
    _canvasId = canvas.canvasId;
    final tool = _activeTool;
    final color = _activeColor;
    final shape = AnnotationShape(
      id: id,
      tool: tool,
      points: [_point(offset, size)],
      color: color,
      width: tool == AnnotationTool.highlight ? 16 : 3,
    );
    setState(() {
      _draft = shape;
      _error = null;
    });
    _failedStroke = null;
    if (tool == AnnotationTool.pen || tool == AnnotationTool.highlight) {
      _enqueue(
        () => widget.session.begin(shape, canvasId: canvas.canvasId),
        strokeId: id,
      );
      _flushTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => _flush(),
      );
    }
  }

  void _update(Offset offset, Size size) {
    if (_activeTool == AnnotationTool.eraser) {
      _eraseAt(offset, size);
      return;
    }
    final shape = _draft;
    if (shape == null || shape.points.length >= 2048) return;
    final point = _point(offset, size);
    final freehand =
        shape.tool == AnnotationTool.pen ||
        shape.tool == AnnotationTool.highlight;
    setState(
      () => _draft = AnnotationShape(
        id: shape.id,
        tool: shape.tool,
        points: freehand
            ? [...shape.points, point]
            : [shape.points.first, point],
        color: shape.color,
        width: shape.width,
      ),
    );
    if (freehand) {
      _batch.add(point);
      if (_batch.length >= 100) _flush();
    }
  }

  void _flush() {
    final shape = _draft;
    if (shape == null || _batch.isEmpty) return;
    final points = List<AnnotationPoint>.of(_batch);
    _batch.clear();
    final canvasId = _canvasId;
    _enqueue(
      () => widget.session.append(shape.id, points, canvasId: canvasId),
      strokeId: shape.id,
    );
  }

  void _finish() {
    final shape = _draft;
    if (shape == null || _finishing) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    _finishing = true;
    if (shape.tool == AnnotationTool.pen ||
        shape.tool == AnnotationTool.highlight) {
      _flush();
    } else {
      final canvasId = _canvasId;
      _enqueue(
        () => widget.session.begin(shape, canvasId: canvasId),
        strokeId: shape.id,
      );
    }
    unawaited(
      _work.then((_) {
        if (mounted) {
          setState(() {
            _draft = null;
            _finishing = false;
          });
        }
      }),
    );
  }

  Future<void> _label(Offset offset, Size size) async {
    final canvas = widget.session.canvas;
    if (!canvas.active) return;
    final s = WhiteboardStrings.of(context);
    final text = await showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => _AnnotationLabelDialog(strings: s),
    );
    if (text == null || text.isEmpty || !mounted) return;
    final shape = AnnotationShape(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(0x100000000)}',
      tool: AnnotationTool.text,
      points: [_point(offset, size)],
      color: _activeColor,
      text: text,
    );
    _enqueue(() => widget.session.begin(shape, canvasId: canvas.canvasId));
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<AnnotationCanvas>(
    stream: widget.session.canvases,
    initialData: widget.session.canvas,
    builder: (context, snapshot) {
      final canvas = snapshot.data ?? AnnotationCanvas();
      // System-window strokes already occur in captured video. Editing happens
      // in that window, and drawing vectors here would duplicate the video ink.
      final teacher =
          widget.session.canEdit &&
          widget.allowEditing &&
          !canvas.embeddedInVideo;
      final matches = canvas.active;
      final s = WhiteboardStrings.of(context);
      return LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          if (widget.infiniteCanvas) {
            return Stack(
              fit: StackFit.expand,
              children: [
                _infiniteViewport(context, canvas, teacher, matches, size),
                if (_error != null)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Material(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text('${s.t('syncError')} $_error'),
                      ),
                    ),
                  ),
              ],
            );
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              InteractiveViewer(
                transformationController: _transform,
                minScale: 1,
                maxScale: 5,
                panEnabled:
                    widget.enableNavigation && (!teacher || !_isEditing),
                scaleEnabled:
                    widget.enableNavigation && (!teacher || !_isEditing),
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (widget.background != null) widget.background!,
                      IgnorePointer(
                        child: CustomPaint(
                          painter: AnnotationPainter([
                            if (matches && !canvas.embeddedInVideo)
                              ...canvas.shapes.where(
                                (shape) => shape.id != _draft?.id,
                              ),
                            if (!canvas.embeddedInVideo &&
                                _draft != null &&
                                _canvasId == canvas.canvasId)
                              _draft!,
                          ], fontFamily: RealtimeFonts.bodyOf(context)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IgnorePointer(
                ignoring: !teacher || !_isEditing || !matches,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: _activeTool == AnnotationTool.text
                      ? null
                      : (event) => _start(event.localPosition, size),
                  onPanUpdate: _activeTool == AnnotationTool.text
                      ? null
                      : (event) => _update(event.localPosition, size),
                  onPanEnd: _activeTool == AnnotationTool.text
                      ? null
                      : (_) => _finish(),
                  onPanCancel: _activeTool == AnnotationTool.text
                      ? null
                      : _finish,
                  onTapUp:
                      _activeTool == AnnotationTool.text ||
                          _activeTool == AnnotationTool.eraser
                      ? (event) {
                          if (_activeTool == AnnotationTool.eraser) {
                            _eraseAt(event.localPosition, size);
                          } else {
                            unawaited(_label(event.localPosition, size));
                          }
                        }
                      : null,
                ),
              ),
              if (teacher &&
                  widget.toolbarPlacement != AnnotationToolbarPlacement.none)
                if (widget.toolbarPlacement ==
                    AnnotationToolbarPlacement.fixedTop)
                  Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                      child: AnnotationToolbar(
                        tool: _activeTool,
                        fixedTop: true,
                        showDragHandle: false,
                        drawingEnabled: _isEditing,
                        selectedColor: _activeColor,
                        onColorChanged: (c) {
                          if (mounted) setState(() => _selectedColor = c);
                        },
                        canEdit: matches,
                        canUndo: _draft == null && !_finishing,
                        canClear: _draft == null && !_finishing,
                        canClose: false,
                        editTooltip: widget.editTooltip ?? s.t('annotate'),
                        onToolChanged: _draft != null || _finishing
                            ? null
                            : (tool) {
                                if (widget.onToolChanged != null) {
                                  widget.onToolChanged!(tool);
                                } else {
                                  setState(() {
                                    _tool = tool;
                                    _editing = true;
                                  });
                                }
                              },
                        onDrawingToggle: () => setState(() {
                          if (_editing) _finish();
                          _editing = !_editing;
                        }),
                        onUndo: () => _enqueue(widget.session.undo),
                        onClear: () => _enqueue(widget.session.clear),
                      ),
                    ),
                  )
                else
                  MovableAnnotationToolbar(
                    startAtTop: widget.toolbarAtTop,
                    constrainToCanvas: widget.constrainToolbarToCanvas,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: AnnotationToolbar(
                        tool: _activeTool,
                        drawingEnabled: _isEditing,
                        selectedColor: _activeColor,
                        onColorChanged: (c) {
                          if (mounted) setState(() => _selectedColor = c);
                        },
                        canEdit: matches,
                        canUndo: _draft == null && !_finishing,
                        canClear: _draft == null && !_finishing,
                        canClose: false,
                        editTooltip: widget.editTooltip ?? s.t('annotate'),
                        onToolChanged: _draft != null || _finishing
                            ? null
                            : (tool) {
                                if (widget.onToolChanged != null) {
                                  widget.onToolChanged!(tool);
                                } else {
                                  setState(() {
                                    _tool = tool;
                                    _editing = true;
                                  });
                                }
                              },
                        onDrawingToggle: () => setState(() {
                          if (_editing) _finish();
                          _editing = !_editing;
                        }),
                        onUndo: () => _enqueue(widget.session.undo),
                        onClear: () => _enqueue(widget.session.clear),
                      ),
                    ),
                  ),
              if (_error != null)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Material(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text('${s.t('syncError')} $_error'),
                    ),
                  ),
                ),
            ],
          );
        },
      );
    },
  );
}

/// Public for hosts that supply their own annotation toolbar and gestures.
class AnnotationPainter extends CustomPainter {
  AnnotationPainter(this.shapes, {this.fontFamily = RealtimeFonts.body});

  /// Font used for annotation labels, independent of a host's widget tree.
  final String fontFamily;
  final List<AnnotationShape> shapes;
  @override
  void paint(Canvas canvas, Size size) => paintScene(canvas, size);

  void paintScene(Canvas canvas, Size size, {bool clipToCanvas = true}) {
    canvas.save();
    if (clipToCanvas) canvas.clipRect(Offset.zero & size);
    for (final shape in shapes) {
      if (shape.points.isEmpty) continue;
      Offset position(AnnotationPoint p) =>
          Offset(p.x * size.width, p.y * size.height);
      final start = position(shape.points.first),
          end = position(shape.points.last);
      // Widths and labels scale with the content, not device pixel density.
      final scale = size.shortestSide / 720;
      final paint = Paint()
        ..color = Color(shape.color)
        ..strokeWidth = math.max(1, shape.width * scale)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      switch (shape.tool) {
        case AnnotationTool.pen:
        case AnnotationTool.highlight:
          if (shape.tool == AnnotationTool.highlight) {
            paint.color = paint.color.withValues(alpha: .35);
          }
          final path = Path()..moveTo(start.dx, start.dy);
          for (final point in shape.points.skip(1)) {
            final p = position(point);
            path.lineTo(p.dx, p.dy);
          }
          if (shape.points.length == 1) {
            canvas.drawCircle(
              start,
              paint.strokeWidth / 2,
              paint..style = PaintingStyle.fill,
            );
          } else {
            canvas.drawPath(path, paint);
          }
        case AnnotationTool.circle:
          canvas.drawOval(Rect.fromPoints(start, end), paint);
        case AnnotationTool.arrow:
          canvas.drawLine(start, end, paint);
          final angle = math.atan2(end.dy - start.dy, end.dx - start.dx);
          final length = math.max(8.0, 18 * scale);
          for (final delta in [-.5, .5]) {
            canvas.drawLine(
              end,
              end -
                  Offset(math.cos(angle + delta), math.sin(angle + delta)) *
                      length,
              paint,
            );
          }
        case AnnotationTool.text:
          final label = TextPainter(
            text: TextSpan(
              text: shape.text,
              style: TextStyle(
                color: paint.color,
                fontFamily: fontFamily.isEmpty ? null : fontFamily,
                fontSize: math.max(10, 22 * scale),
              ),
            ),
            textDirection: TextDirection.ltr,
          );
          label.layout(
            maxWidth: clipToCanvas
                ? math.max(1, size.width - start.dx)
                : size.width,
          );
          label.paint(canvas, start);
        case AnnotationTool.eraser:
          // Editing gesture only: never rendered as a shape.
          break;
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(AnnotationPainter oldDelegate) =>
      !identical(shapes, oldDelegate.shapes) ||
      fontFamily != oldDelegate.fontFamily;
}

/// Paints the shared 1600x900 reference coordinate system across an
/// unbounded viewport. The scene matrix is local to each user; only the
/// scene-space annotation points are sent through the shared repository.
class _InfiniteWhiteboardPainter extends CustomPainter {
  _InfiniteWhiteboardPainter({
    required this.shapes,
    required this.transform,
    required this.sceneSize,
    required this.fontFamily,
  }) : super(repaint: transform);

  final List<AnnotationShape> shapes;
  final TransformationController transform;
  final Size sceneSize;
  final String fontFamily;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(Colors.white, BlendMode.src);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final a = transform.toScene(Offset.zero);
    final b = transform.toScene(Offset(size.width, size.height));
    canvas.transform(transform.value.storage);
    const step = 80.0;
    final grid = Paint()
      ..color = const Color(0xFFEAF0F7)
      ..strokeWidth = 1 / transform.value.getMaxScaleOnAxis();
    final left = math.min(a.dx, b.dx);
    final right = math.max(a.dx, b.dx);
    final top = math.min(a.dy, b.dy);
    final bottom = math.max(a.dy, b.dy);
    for (var x = (left / step).floor() * step; x <= right; x += step) {
      canvas.drawLine(Offset(x, top), Offset(x, bottom), grid);
    }
    for (var y = (top / step).floor() * step; y <= bottom; y += step) {
      canvas.drawLine(Offset(left, y), Offset(right, y), grid);
    }
    AnnotationPainter(
      shapes,
      fontFamily: fontFamily,
    ).paintScene(canvas, sceneSize, clipToCanvas: false);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_InfiniteWhiteboardPainter oldDelegate) =>
      !identical(shapes, oldDelegate.shapes) ||
      !identical(transform, oldDelegate.transform) ||
      fontFamily != oldDelegate.fontFamily;
}

class _AnnotationLabelDialog extends StatefulWidget {
  const _AnnotationLabelDialog({required this.strings});

  final WhiteboardStrings strings;

  @override
  State<_AnnotationLabelDialog> createState() => _AnnotationLabelDialogState();
}

class _AnnotationLabelDialogState extends State<_AnnotationLabelDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    return RealtimeGlassDialog(
      title: Text(s.t('label')),
      content: TextField(
        controller: _controller,
        maxLength: 200,
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(s.t('cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(s.t('submit')),
        ),
      ],
    );
  }
}
