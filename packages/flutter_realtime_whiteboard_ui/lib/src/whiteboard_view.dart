import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_realtime_design_ui/flutter_realtime_design_ui.dart';
import 'package:flutter_realtime_whiteboard_core/flutter_realtime_whiteboard_core.dart';
import 'annotation_surface.dart';
import 'color_picker_dialog.dart';
import 'whiteboard_strings.dart';
import 'whiteboard_viewport_scale.dart';

const _quickPenColors = <int>[0xff1f2a3c, 0xff2563eb, 0xffd93a3f, 0xfff5c518];

Future<void> _pickPenColor(
  BuildContext context,
  WhiteboardToolsController controller,
) async {
  final color = await showWhiteboardColorPicker(
    context,
    initialColor: controller.color,
  );
  if (color != null && context.mounted) controller.selectColor(color);
}

/// Independent view: no media, chat or classroom session is required.
/// The host owns and disposes the session. Students follow its active page.
///
/// Reference classroom shape: a 60 pt vertical teaching-tool rail on the left,
/// a page-tab bar across the top and a 16:9 board with zoom controls. The rail
/// only exposes tools the whiteboard core can actually execute.
/// Share drawing selections with a host-provided toolbar without duplicating
/// the whiteboard's state or coupling it to the room UI.
class WhiteboardToolsController extends ChangeNotifier {
  AnnotationTool _tool = AnnotationTool.pen;
  int _color = 0xff1f2a3c;
  bool _drawingEnabled = true;

  AnnotationTool get tool => _tool;
  int get color => _color;
  bool get drawingEnabled => _drawingEnabled;

  void selectTool(AnnotationTool tool) {
    _tool = tool;
    _drawingEnabled = true;
    notifyListeners();
  }

  void selectColor(int color) {
    if (_color == color) return;
    _color = color;
    notifyListeners();
  }

  void toggleDrawing() {
    _drawingEnabled = !_drawingEnabled;
    notifyListeners();
  }
}

class WhiteboardView extends StatefulWidget {
  const WhiteboardView({
    super.key,
    required this.session,
    this.onStop,
    this.toolsController,
    this.showToolRail = true,
  });
  final WhiteboardSession session;
  final VoidCallback? onStop;

  /// Supplying a controller lets the room's leading rail own these controls.
  final WhiteboardToolsController? toolsController;
  final bool showToolRail;
  @override
  State<WhiteboardView> createState() => _WhiteboardViewState();
}

class _WhiteboardViewState extends State<WhiteboardView> {
  Object? _error;
  bool _busy = false;
  final _localTools = WhiteboardToolsController();
  WhiteboardToolsController get _tools => widget.toolsController ?? _localTools;
  int _zoomPercent = 100;
  final _transform = TransformationController();
  final _viewportKey = GlobalKey();
  bool _initialViewportReady = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run(widget.session.start));
  }

  @override
  void didUpdateWidget(WhiteboardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      unawaited(_run(widget.session.start));
    }
  }

  @override
  void dispose() {
    _transform.dispose();
    _localTools.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      await operation();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setZoom(double scale) {
    final next = scale.clamp(0.25, 8.0);
    final size = _viewportSize;
    if (size == null) return;
    // Keep the scene point under the viewport center fixed while zooming.
    // A Matrix4 applies its rightmost operations first: scaling before
    // translating also scales the center offset, drifting the board on every
    // zoom step and eventually moving strokes out of the visible viewport.
    final center = Offset(size.width / 2, size.height / 2);
    final scene = _transform.toScene(center);
    final translation = center - scene * next;
    _transform.value = Matrix4.identity()
      ..translateByDouble(translation.dx, translation.dy, 0, 1)
      ..scaleByDouble(next, next, 1, 1);
    setState(() => _zoomPercent = (next * 100).round());
  }

  void _resetViewport() {
    final size = _viewportSize;
    if (size == null) return;
    final center = Offset(size.width / 2, size.height / 2);
    _transform.value = Matrix4.identity()
      ..translateByDouble(center.dx - 800, center.dy - 450, 0, 1);
    setState(() => _zoomPercent = 100);
  }

  Size? _viewportSize;

  void _onViewportSize(Size size) {
    if (size.isEmpty || size == _viewportSize && _initialViewportReady) return;
    final previous = _viewportSize;
    _viewportSize = size;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_initialViewportReady) {
        const worldCenter = Offset(800, 450);
        final center = Offset(size.width / 2, size.height / 2);
        _transform.value = Matrix4.identity()
          ..translateByDouble(
            center.dx - worldCenter.dx,
            center.dy - worldCenter.dy,
            0,
            1,
          );
        _initialViewportReady = true;
      } else if (previous != null && previous != size) {
        // Window rotations/resizes keep the viewed world point centered.
        final previousCenter = Offset(previous.width / 2, previous.height / 2);
        final scene = _transform.toScene(previousCenter);
        final scale = whiteboardViewportScale(_transform.value);
        final nextCenter = Offset(size.width / 2, size.height / 2);
        final translation = nextCenter - scene * scale;
        _transform.value = Matrix4.identity()
          ..translateByDouble(translation.dx, translation.dy, 0, 1)
          ..scaleByDouble(scale, scale, 1, 1);
      }
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _tools,
    builder: (context, _) => StreamBuilder<WhiteboardState>(
      stream: widget.session.states,
      initialData: widget.session.state,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final s = WhiteboardStrings.of(context);
        if (state == null) {
          return Center(
            child: _error == null
                ? const CircularProgressIndicator()
                : Text('$_error'),
          );
        }
        final activeIndex = state.pages.indexWhere(
          (p) => p.id == state.activePageId,
        );
        final style = RealtimeStyle.of(context);
        final rail = state.canEdit && widget.showToolRail
            ? Container(
                width: 60,
                color: style.surface,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: WhiteboardToolRail(
                    session: widget.session,
                    controller: _tools,
                  ),
                ),
              )
            : null;

        return Material(
          color: style.background,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide =
                  RealtimeBreakpoints.isWide(
                    context,
                    MediaQuery.sizeOf(context).width,
                  ) &&
                  constraints.maxWidth >= 600 &&
                  constraints.maxHeight >= 420;
              final body = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildPageBar(context, state, activeIndex, s),
                  // A narrow stage inside a wide meeting still has the
                  // permanent outer rail. Do not add a second toolbar merely
                  // because its available content width became small.
                  if (!wide &&
                      state.canEdit &&
                      (widget.toolsController == null ||
                          !RealtimeBreakpoints.isWide(
                            context,
                            MediaQuery.sizeOf(context).width,
                          )))
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                      child: _buildHorizontalToolbar(context, state),
                    ),
                  if (_error != null)
                    Text(
                      '$_error',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  Expanded(
                    child: _BoardCanvas(
                      viewportKey: _viewportKey,
                      transformationController: _transform,
                      session: widget.session,
                      state: state,
                      tool: _tools.tool,
                      selectedColor: _tools.color,
                      drawingEnabled: _tools.drawingEnabled,
                      onViewportSize: _onViewportSize,
                      onZoomChanged: (scale) {
                        final percent = (scale * 100).round();
                        if (percent != _zoomPercent && mounted) {
                          setState(() => _zoomPercent = percent);
                        }
                      },
                    ),
                  ),
                ],
              );
              if (rail == null) return body;
              if (!wide) return body;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  rail,
                  Expanded(child: body),
                ],
              );
            },
          ),
        );
      },
    ),
  );

  Widget _buildPageBar(
    BuildContext context,
    WhiteboardState state,
    int activeIndex,
    WhiteboardStrings s,
  ) {
    final style = RealtimeStyle.of(context);
    final pageTabs = <Widget>[
      for (var i = 0; i < state.pages.length; i++)
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: _PageTab(
            label: state.pages[i].title.isEmpty
                ? (s.zh ? '第 ${i + 1} 页' : 'Page ${i + 1}')
                : state.pages[i].title,
            selected: i == activeIndex,
            onTap: state.canEdit && !_busy && i != activeIndex
                ? () => _run(() => widget.session.selectPage(state.pages[i].id))
                : null,
          ),
        ),
      if (state.canEdit)
        IconButton(
          tooltip: s.t('addPage'),
          iconSize: 18,
          onPressed: _busy || state.pages.length >= state.maxPages
              ? null
              : () => _run(
                  () => widget.session.addPage(
                    title: s.zh
                        ? '第 ${state.pages.length + 1} 页'
                        : 'Page ${state.pages.length + 1}',
                  ),
                ),
          icon: const Icon(Icons.add_rounded),
        ),
    ];
    final trailing = <Widget>[
      _ZoomControl(
        percent: _zoomPercent,
        onZoomOut: _zoomPercent <= 25
            ? null
            : () => _setZoom(_zoomPercent / 100 - .25),
        onZoomIn: _zoomPercent >= 800
            ? null
            : () => _setZoom(_zoomPercent / 100 + .25),
        onReset: _resetViewport,
      ),
      if (state.canEdit) ...[
        const SizedBox(width: 4),
        IconButton(
          tooltip: s.t('deletePage'),
          iconSize: 18,
          onPressed: _busy || state.pages.length <= 1
              ? null
              : () => _run(() => widget.session.deletePage(state.activePageId)),
          icon: const Icon(Icons.delete_outline_rounded),
        ),
      ],
      if (widget.onStop != null) ...[
        const SizedBox(width: 4),
        FilledButton.icon(
          onPressed: widget.onStop,
          style: FilledButton.styleFrom(
            backgroundColor: style.speakStrong,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            textStyle: TextStyle(
              fontFamily: RealtimeFonts.bodyOf(context),
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9),
            ),
          ),
          icon: const Icon(Icons.stop_rounded, size: 16),
          label: Text(s.t('stopSharing')),
        ),
      ],
    ];
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: style.surface,
        border: Border(bottom: BorderSide(color: style.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Narrow bars keep the page tabs scrollable and pin the trailing
          // actions, so stop sharing never gets clipped off-screen.
          final narrow = constraints.maxWidth < 640;
          return Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: pageTabs),
                ),
              ),
              if (narrow)
                _CompactPageActions(
                  onZoomOut: _zoomPercent <= 25
                      ? null
                      : () => _setZoom(_zoomPercent / 100 - .25),
                  onZoomIn: _zoomPercent >= 800
                      ? null
                      : () => _setZoom(_zoomPercent / 100 + .25),
                  onReset: _resetViewport,
                  onDelete: !state.canEdit
                      ? null
                      : (_busy || state.pages.length <= 1
                            ? null
                            : () => _run(
                                () => widget.session.deletePage(
                                  state.activePageId,
                                ),
                              )),
                  onStop: widget.onStop,
                  stopTooltip: s.t('stopSharing'),
                )
              else ...[
                const SizedBox(width: 8),
                ...trailing,
              ],
            ],
          );
        },
      ),
    );
  }

  /// Tablets and phones keep the same tools in a compact horizontal strip.
  Widget _buildHorizontalToolbar(BuildContext context, WhiteboardState state) {
    final style = RealtimeStyle.of(context);
    final s = WhiteboardStrings.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: style.surface,
        borderRadius: BorderRadius.circular(RealtimeUiTokens.controlRadius),
        border: Border.all(color: style.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RailTool(
            icon: Icons.pan_tool_outlined,
            tooltip: s.t('annotate'),
            selected: !_tools.drawingEnabled,
            compact: true,
            onTap: _tools.toggleDrawing,
          ),
          for (final entry in const <(AnnotationTool, IconData, String)>[
            (AnnotationTool.pen, Icons.edit_rounded, 'pen'),
            (AnnotationTool.highlight, Icons.brush_rounded, 'highlight'),
            (AnnotationTool.circle, Icons.circle_outlined, 'circle'),
            (AnnotationTool.arrow, Icons.arrow_outward_rounded, 'arrow'),
            (AnnotationTool.text, Icons.title_rounded, 'label'),
            (AnnotationTool.eraser, Icons.auto_fix_off_rounded, 'eraser'),
          ])
            _RailTool(
              icon: entry.$2,
              tooltip: s.t(entry.$3),
              selected: _tools.tool == entry.$1,
              compact: true,
              onTap: () => _tools.selectTool(entry.$1),
            ),
          for (final color in _quickPenColors)
            _ColorDot(
              color: Color(color),
              selected: _tools.color == color,
              onTap: () => _tools.selectColor(color),
            ),
          if (!_quickPenColors.contains(_tools.color))
            _ColorDot(
              color: Color(_tools.color),
              selected: true,
              onTap: () => unawaited(_pickPenColor(context, _tools)),
            ),
          _RailTool(
            icon: Icons.palette_outlined,
            tooltip: s.t('moreColors'),
            selected: !_quickPenColors.contains(_tools.color),
            compact: true,
            onTap: () => unawaited(_pickPenColor(context, _tools)),
          ),
          _RailTool(
            icon: Icons.undo_rounded,
            tooltip: s.t('undo'),
            compact: true,
            onTap: _busy ? null : () => _run(widget.session.undo),
          ),
          _RailTool(
            icon: Icons.delete_sweep_outlined,
            tooltip: s.t('clear'),
            compact: true,
            onTap: _busy ? null : () => _run(widget.session.clear),
          ),
        ],
      ),
    );
  }
}

/// Tool controls without a second sidebar. A room can append this inside its
/// primary navigation rail; standalone whiteboards use it in their own rail.
/// [horizontal] lays the same tools out in one row for the tablet rail.
class WhiteboardToolRail extends StatefulWidget {
  const WhiteboardToolRail({
    super.key,
    required this.session,
    required this.controller,
    this.horizontal = false,
  });

  final WhiteboardSession session;
  final WhiteboardToolsController controller;
  final bool horizontal;

  @override
  State<WhiteboardToolRail> createState() => _WhiteboardToolRailState();
}

class _WhiteboardToolRailState extends State<WhiteboardToolRail> {
  bool _busy = false;
  Object? _error;

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => StreamBuilder<WhiteboardState>(
      stream: widget.session.states,
      initialData: widget.session.state,
      builder: (context, snapshot) {
        if (snapshot.data?.canEdit != true) return const SizedBox.shrink();
        final s = WhiteboardStrings.of(context);
        final tools = widget.controller;
        final horizontal = widget.horizontal;
        final divider = horizontal
            ? const SizedBox(width: 8)
            : const _RailDivider();
        final items = <Widget>[
          _RailTool(
            icon: tools.drawingEnabled
                ? Icons.pan_tool_outlined
                : Icons.near_me_outlined,
            tooltip: s.t('annotate'),
            selected: !tools.drawingEnabled,
            compact: horizontal,
            onTap: tools.toggleDrawing,
          ),
          divider,
          for (final entry in const <(AnnotationTool, IconData, String)>[
            (AnnotationTool.pen, Icons.edit_rounded, 'pen'),
            (AnnotationTool.highlight, Icons.brush_rounded, 'highlight'),
            (AnnotationTool.circle, Icons.circle_outlined, 'circle'),
            (AnnotationTool.arrow, Icons.arrow_outward_rounded, 'arrow'),
            (AnnotationTool.text, Icons.title_rounded, 'label'),
            (AnnotationTool.eraser, Icons.auto_fix_off_rounded, 'eraser'),
          ])
            _RailTool(
              icon: entry.$2,
              tooltip: s.t(entry.$3),
              selected: tools.tool == entry.$1,
              compact: horizontal,
              onTap: () => tools.selectTool(entry.$1),
            ),
          divider,
          for (final color in _quickPenColors)
            _ColorDot(
              color: Color(color),
              selected: tools.color == color,
              onTap: () => tools.selectColor(color),
            ),
          if (!_quickPenColors.contains(tools.color))
            _ColorDot(
              color: Color(tools.color),
              selected: true,
              onTap: () => unawaited(_pickPenColor(context, tools)),
            ),
          _RailTool(
            icon: Icons.palette_outlined,
            tooltip: s.t('moreColors'),
            selected: !_quickPenColors.contains(tools.color),
            compact: horizontal,
            onTap: () => unawaited(_pickPenColor(context, tools)),
          ),
          divider,
          _RailTool(
            icon: Icons.undo_rounded,
            tooltip: s.t('undo'),
            compact: horizontal,
            onTap: _busy ? null : () => _run(widget.session.undo),
          ),
          _RailTool(
            icon: Icons.delete_sweep_outlined,
            tooltip: s.t('clear'),
            compact: horizontal,
            onTap: _busy ? null : () => _run(widget.session.clear),
          ),
          if (_error != null)
            Tooltip(
              message: '$_error',
              child: Icon(
                Icons.error_outline_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
        ];
        return horizontal
            ? Row(mainAxisSize: MainAxisSize.min, children: items)
            : Column(mainAxisSize: MainAxisSize.min, children: items);
      },
    ),
  );
}

/// The board fills available screen real estate, while its drawing coordinates
/// remain a stable unbounded scene shared across viewport sizes and devices.
class _BoardCanvas extends StatelessWidget {
  const _BoardCanvas({
    required this.viewportKey,
    required this.transformationController,
    required this.session,
    required this.state,
    required this.tool,
    required this.selectedColor,
    required this.drawingEnabled,
    required this.onViewportSize,
    required this.onZoomChanged,
  });

  final GlobalKey viewportKey;
  final TransformationController transformationController;
  final WhiteboardSession session;
  final WhiteboardState state;
  final AnnotationTool tool;
  final int selectedColor;
  final bool drawingEnabled;
  final ValueChanged<Size> onViewportSize;
  final ValueChanged<double> onZoomChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(
          RealtimeUiThemeExtension.of(context).stageRadius,
        ),
        child: ColoredBox(
          color: Colors.white,
          child: LayoutBuilder(
            key: viewportKey,
            builder: (context, board) {
              onViewportSize(board.biggest);
              return AnnotationSurface(
                key: ValueKey(state.canvas.canvasId),
                session: session,
                tool: tool,
                selectedColor: selectedColor,
                drawingEnabled: drawingEnabled,
                toolbarPlacement: AnnotationToolbarPlacement.none,
                transformationController: transformationController,
                infiniteCanvas: true,
                onViewportTransformChanged: onZoomChanged,
              );
            },
          ),
        ),
      );
    },
  );
}

class _PageTab extends StatelessWidget {
  const _PageTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedContainer(
        duration: RealtimeUiTokens.animFast,
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? style.surfaceSubtle : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? style.border : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? style.text : style.textMuted,
          ),
        ),
      ),
    );
  }
}

/// Narrow page bar tail: zoom, delete and stop stay pinned while the page
/// tabs scroll, so every action keeps a stable hit target.
class _CompactPageActions extends StatelessWidget {
  const _CompactPageActions({
    required this.onZoomOut,
    required this.onZoomIn,
    required this.onReset,
    required this.onDelete,
    required this.onStop,
    required this.stopTooltip,
  });
  final VoidCallback? onZoomOut;
  final VoidCallback? onZoomIn;
  final VoidCallback? onReset;
  final VoidCallback? onDelete;
  final VoidCallback? onStop;
  final String stopTooltip;

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Zoom out',
          iconSize: 16,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
          onPressed: onZoomOut,
          icon: const Icon(Icons.remove_rounded),
        ),
        IconButton(
          tooltip: 'Zoom in',
          iconSize: 16,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
          onPressed: onZoomIn,
          icon: const Icon(Icons.add_rounded),
        ),
        IconButton(
          tooltip: 'Reset whiteboard view',
          iconSize: 16,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
          onPressed: onReset,
          icon: const Icon(Icons.center_focus_strong_rounded),
        ),
        if (onDelete != null)
          IconButton(
            tooltip: 'Delete page',
            iconSize: 17,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        if (onStop != null)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: IconButton(
              tooltip: stopTooltip,
              iconSize: 17,
              style: IconButton.styleFrom(
                backgroundColor: style.speakStrong,
                foregroundColor: Colors.white,
                minimumSize: const Size(32, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: onStop,
              icon: const Icon(Icons.stop_rounded),
            ),
          ),
      ],
    );
  }
}

class _ZoomControl extends StatelessWidget {
  const _ZoomControl({
    required this.percent,
    required this.onZoomOut,
    required this.onZoomIn,
    required this.onReset,
  });
  final int percent;
  final VoidCallback? onZoomOut;
  final VoidCallback? onZoomIn;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: style.surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: style.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Zoom out',
            iconSize: 16,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: onZoomOut,
            icon: const Icon(Icons.remove_rounded),
          ),
          InkWell(
            onTap: onReset,
            child: SizedBox(
              width: 42,
              child: Text(
                '$percent%',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: style.text,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Zoom in',
            iconSize: 16,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: onZoomIn,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
    );
  }
}

class _RailTool extends StatelessWidget {
  const _RailTool({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
    this.compact = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool selected;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    final size = compact ? 34.0 : 40.0;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        label: tooltip,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 1 : 8,
            vertical: compact ? 2 : 3,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: AnimatedContainer(
              duration: RealtimeUiTokens.animFast,
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: selected ? style.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                size: 19,
                color: selected ? style.onAccent : style.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? style.text : style.border,
              width: selected ? 2 : 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _RailDivider extends StatelessWidget {
  const _RailDivider();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: SizedBox(
      width: 24,
      height: 1,
      child: ColoredBox(color: RealtimeStyle.of(context).border),
    ),
  );
}
