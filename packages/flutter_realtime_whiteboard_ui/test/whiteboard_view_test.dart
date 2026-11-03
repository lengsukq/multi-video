import 'package:flutter/material.dart';
import 'package:flutter_realtime_design_ui/flutter_realtime_design_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_realtime_whiteboard_core/flutter_realtime_whiteboard_core.dart';
import 'package:flutter_realtime_whiteboard_ui/flutter_realtime_whiteboard_ui.dart';
import 'package:flutter_realtime_whiteboard_ui/src/annotation_hit_test.dart';

class _CountedScreen extends StatelessWidget {
  const _CountedScreen(this.onBuild);
  final VoidCallback onBuild;
  @override
  Widget build(BuildContext context) {
    onBuild();
    return const ColoredBox(color: Colors.blue);
  }
}

void main() {
  test(
    'eraser hit-testing handles geometry, topmost marks and empty space',
    () {
      const size = Size(1000, 1000);
      final circle = AnnotationShape(
        id: 'circle',
        tool: AnnotationTool.circle,
        points: const [AnnotationPoint(.2, .2), AnnotationPoint(.8, .8)],
      );
      final arrow = AnnotationShape(
        id: 'arrow',
        tool: AnnotationTool.arrow,
        points: const [AnnotationPoint(.1, .5), AnnotationPoint(.9, .5)],
      );
      final text = AnnotationShape(
        id: 'text',
        tool: AnnotationTool.text,
        text: 'Lesson title',
        points: const [AnnotationPoint(.35, .35)],
      );
      expect(
        findErasableShape([circle], const Offset(500, 200), size)?.id,
        'circle',
      );
      expect(findErasableShape([circle], const Offset(500, 500), size), isNull);
      expect(
        findErasableShape([arrow, circle], const Offset(500, 500), size)?.id,
        'arrow',
      );
      expect(
        findErasableShape([text], const Offset(360, 355), size)?.id,
        'text',
      );
      expect(findErasableShape([text], const Offset(10, 10), size), isNull);
    },
  );

  testWidgets(
    'mobile pinch reversal and finger replacement never jump or leave ink',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 760);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final session = WhiteboardSession.local();
      await session.start();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WhiteboardView(session: session)),
        ),
      );
      await tester.pumpAndSettle();
      final surface = find.byType(AnnotationSurface);
      final rect = tester.getRect(surface);
      final transform = tester
          .widget<AnnotationSurface>(surface)
          .transformationController!;
      final origin = rect.center - rect.topLeft;
      final initialScene = transform.toScene(origin);

      final first = await tester.startGesture(
        rect.center + const Offset(-40, 0),
        pointer: 31,
      );
      final second = await tester.startGesture(
        rect.center + const Offset(40, 0),
        pointer: 32,
      );
      await tester.pump();
      expect(transform.value.getMaxScaleOnAxis(), closeTo(1, .001));

      // Move one finger at a time as iOS delivers touch events. Both fingers
      // eventually return to their starting positions, so zoom and the world
      // point at the viewport center must return exactly to their origin.
      await first.moveBy(const Offset(-40, 0));
      await tester.pump();
      expect(transform.value.getMaxScaleOnAxis(), closeTo(1.5, .01));
      await second.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(transform.value.getMaxScaleOnAxis(), closeTo(2, .01));

      await first.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(transform.value.getMaxScaleOnAxis(), closeTo(1.5, .01));
      await second.moveBy(const Offset(-40, 0));
      await tester.pump();
      expect(transform.value.getMaxScaleOnAxis(), closeTo(1, .01));
      expect(transform.toScene(origin).dx, closeTo(initialScene.dx, .01));
      expect(transform.toScene(origin).dy, closeTo(initialScene.dy, .01));

      // A third finger replaces the first one. Its down event must only
      // rebase the pinch, not move the board, and the remaining finger must
      // not start drawing when the first is lifted.
      await first.up();
      await tester.pump();
      await second.moveBy(const Offset(15, 0));
      await tester.pump();
      expect(transform.value.getMaxScaleOnAxis(), closeTo(1, .01));
      final beforeReplacement = transform.value.clone();
      final third = await tester.startGesture(
        rect.center + const Offset(-40, 0),
        pointer: 33,
      );
      await tester.pump();
      expect(transform.value.storage, orderedEquals(beforeReplacement.storage));

      await third.moveBy(const Offset(-25, 0));
      await tester.pump();
      expect(transform.value.getMaxScaleOnAxis(), greaterThan(1.2));
      await second.up();
      await third.up();
      await tester.pumpAndSettle();
      expect(session.canvas.shapes, isEmpty);

      // Subsequent independent one-finger drawing is still permitted.
      await tester.dragFrom(rect.center, const Offset(25, 15));
      await tester.pumpAndSettle();
      expect(session.canvas.shapes, hasLength(1));
    },
  );

  testWidgets(
    'eraser deletes real ink, undo restores it without covering ink',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final board = WhiteboardSession.local();
      final controls = WhiteboardToolsController();
      await board.start();
      addTearDown(controls.dispose);
      await board.begin(
        AnnotationShape(
          id: 'ink-center',
          tool: AnnotationTool.pen,
          color: 0xff2563eb,
          points: const [AnnotationPoint(.45, .5), AnnotationPoint(.55, .5)],
        ),
        canvasId: board.canvas.canvasId,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                SizedBox(
                  width: 60,
                  child: SingleChildScrollView(
                    child: WhiteboardToolRail(
                      session: board,
                      controller: controls,
                    ),
                  ),
                ),
                Expanded(
                  child: WhiteboardView(
                    session: board,
                    toolsController: controls,
                    showToolRail: false,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final eraser = find.descendant(
        of: find.byType(WhiteboardToolRail),
        matching: find.byTooltip('Eraser (whole stroke)'),
      );
      expect(eraser, findsOneWidget);
      await tester.tap(eraser);
      await tester.pumpAndSettle();
      final surface = tester.getRect(find.byType(AnnotationSurface));
      await tester.tapAt(surface.center);
      await tester.pumpAndSettle();
      expect(board.canvas.shapes, isEmpty);
      await tester.tap(
        find.descendant(
          of: find.byType(WhiteboardToolRail),
          matching: find.byTooltip('Undo'),
        ),
      );
      await tester.pumpAndSettle();
      expect(board.canvas.shapes.single.id, 'ink-center');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(board.dispose);
    },
  );

  testWidgets('merged whiteboard rail custom palette colors real strokes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final session = WhiteboardSession.local();
    final controls = WhiteboardToolsController();
    await session.start();
    addTearDown(controls.dispose);
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 60,
                child: SingleChildScrollView(
                  child: WhiteboardToolRail(
                    session: session,
                    controller: controls,
                  ),
                ),
              ),
              Expanded(
                child: WhiteboardView(
                  session: session,
                  toolsController: controls,
                  showToolRail: false,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WhiteboardToolRail), findsOneWidget);
    final palette = find.descendant(
      of: find.byType(WhiteboardToolRail),
      matching: find.byTooltip('More colors'),
    );
    expect(palette, findsOneWidget);
    final initialColor = controls.color;
    await tester.tap(palette);
    await tester.pumpAndSettle();
    expect(find.byType(WhiteboardColorPickerDialog), findsOneWidget);
    expect(find.byKey(const ValueKey('whiteboard-color-hue')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('whiteboard-color-saturation')),
      findsOneWidget,
    );
    await tester.drag(
      find.byKey(const ValueKey('whiteboard-color-hue')),
      const Offset(90, 0),
    );
    await tester.drag(
      find.byKey(const ValueKey('whiteboard-color-saturation')),
      const Offset(75, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(controls.color, isNot(initialColor));
    expect(find.byType(WhiteboardColorPickerDialog), findsNothing);

    final surface = tester.getRect(find.byType(AnnotationSurface));
    await tester.dragFrom(surface.center, const Offset(36, 28));
    await tester.pumpAndSettle();
    expect(session.canvas.shapes, isNotEmpty);
    expect(session.canvas.shapes.last.color, controls.color);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(session.dispose);
  });

  testWidgets(
    'annotation labels follow the host font and repaint when it changes',
    (tester) async {
      final session = WhiteboardSession.local();
      await session.start();
      addTearDown(session.dispose);
      Future<AnnotationPainter> mount(String family) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: RealtimeUiTheme.light(
              appearance: RealtimeUiThemeExtension(bodyFontFamily: family),
            ),
            home: Scaffold(body: AnnotationSurface(session: session)),
          ),
        );
        await tester.pumpAndSettle();
        return tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((widget) => widget.painter)
            .whereType<AnnotationPainter>()
            .single;
      }

      final first = await mount('HostNotes');
      expect(first.fontFamily, 'HostNotes');
      final next = await mount('AccessibleNotes');
      expect(next.fontFamily, 'AccessibleNotes');
      expect(next.shouldRepaint(first), isTrue);
    },
  );

  testWidgets(
    'screen stage shares all tools, keeps the screen renderer and respects portrait/landscape letterboxes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final size in [
        const Size(360, 640),
        const Size(640, 360),
        const Size(1200, 800),
      ]) {
        tester.view.physicalSize = size;
        final session = WhiteboardSession.local();
        await session.start();
        var builds = 0;
        final background = _CountedScreen(() => builds++);
        Widget stage(bool edit) => MaterialApp(
          home: Scaffold(
            body: SharedContentStage(
              mode: SharedContentMode.screen,
              whiteboard: session,
              screen: background,
              screenAspectRatio: 4 / 3,
              screenAnnotations: session,
              canAnnotateScreen: edit,
            ),
          ),
        );
        await tester.pumpWidget(stage(true));
        await tester.pumpAndSettle();
        final before = builds;
        final rect = tester.getRect(find.byType(AnnotationSurface));
        // Logical-pixel rounding can shift the fitted edge by <1 px.
        expect(rect.width / rect.height, closeTo(4 / 3, .005));
        await tester.tap(find.byTooltip('Draw / navigate'));
        await tester.pumpAndSettle();
        for (final label in ['Pen', 'Highlight', 'Circle', 'Arrow']) {
          await tester.tap(find.byTooltip(label));
          await tester.pump();
          await tester.dragFrom(rect.center, const Offset(25, 25));
          await tester.pumpAndSettle();
          expect(
            session.canvas.shapes.length,
            greaterThan(0),
            reason: 'At least one screen annotation must survive $label',
          );
        }
        await tester.tap(find.byTooltip('Text'));
        await tester.pump();
        await tester.tapAt(rect.center);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Shared screen');
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        expect(session.canvas.shapes.length, 5);
        expect(builds, before);
        await tester.tap(find.byTooltip('Undo'));
        await tester.pumpAndSettle();
        expect(session.canvas.shapes.length, 4);
        await tester.tap(find.byTooltip('Clear'));
        await tester.pumpAndSettle();
        expect(session.canvas.shapes, isEmpty);
        await tester.pumpWidget(stage(false));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Draw / navigate'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(session.dispose);
      }
    },
  );

  testWidgets(
    'independent board draws, pages, undo/clear with no media session',
    (tester) async {
      final session = WhiteboardSession.local();
      await session.start();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WhiteboardView(session: session)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MovableAnnotationToolbar), findsNothing);
      expect(find.byIcon(Icons.drag_indicator), findsNothing);
      expect(find.byTooltip('Draw / navigate'), findsOneWidget);
      final surface = find.byType(AnnotationSurface);
      final rect = tester.getRect(surface);
      for (final label in ['Pen', 'Highlight', 'Circle', 'Arrow']) {
        await tester.tap(find.byTooltip(label));
        await tester.pump();
        await tester.dragFrom(rect.center, const Offset(35, 20));
        await tester.pumpAndSettle();
      }
      expect(session.canvas.shapes.length, 4);
      await tester.tap(find.byTooltip('Text'));
      await tester.pump();
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Lesson');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(session.canvas.shapes.last.text, 'Lesson');
      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();
      expect(session.canvas.shapes.length, 4);
      await tester.tap(find.byTooltip('Add page'));
      await tester.pumpAndSettle();
      expect(session.state!.pages.length, 2);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byTooltip('Delete current page'));
      await tester.pumpAndSettle();
      expect(session.canvas.shapes.length, 4);

      // Verify changing color applies to highlight
      final blueDot = find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color == const Color(0xff2563eb),
      );
      await tester.tap(blueDot);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Highlight'));
      await tester.pump();
      await tester.dragFrom(rect.center, const Offset(30, 20));
      await tester.pumpAndSettle();
      expect(session.canvas.shapes.last.tool, AnnotationTool.highlight);
      expect(session.canvas.shapes.last.color, 0xff2563eb);

      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      expect(session.canvas.shapes, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.dispose);
    },
  );
  testWidgets(
    'student cannot edit or change pages, mobile viewport fills available stage',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 760);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final session = WhiteboardSession.local(canEdit: false);
      await session.start();
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 700,
            child: WhiteboardView(session: session),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Draw / navigate'), findsNothing);
      expect(find.byTooltip('Add page'), findsNothing);
      expect(find.byTooltip('Delete current page'), findsNothing);
      final size = tester.getSize(find.byType(AnnotationSurface));
      expect(size.width, closeTo(390, 1));
      expect(size.height, greaterThan(size.width));
      expect(
        tester
            .widget<AnnotationSurface>(find.byType(AnnotationSurface))
            .infiniteCanvas,
        isTrue,
      );
      await tester.drag(find.byType(AnnotationSurface), const Offset(40, 20));
      await tester.pumpAndSettle();
      expect(session.canvas.shapes, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.dispose);
    },
  );
  testWidgets(
    'inverse zoom transform maps draw coordinates to content; toolbar stays outside transform',
    (tester) async {
      final session = WhiteboardSession.local();
      await session.start();
      await tester.pumpWidget(
        MaterialApp(home: WhiteboardView(session: session)),
      );
      await tester.pumpAndSettle();
      final transform = tester
          .widget<AnnotationSurface>(find.byType(AnnotationSurface))
          .transformationController!;
      transform.value = Matrix4.identity()..scaleByDouble(2, 2, 1, 1);
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byType(AnnotationSurface));
      final start = rect.topLeft + Offset(rect.width * .5, rect.height * .5);
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(20, 20));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        session.canvas.shapes.single.points.first.x,
        closeTo(rect.width / (2 * 1600 * 2), .02),
      );
      expect(
        session.canvas.shapes.single.points.first.y,
        closeTo(rect.height / (2 * 900 * 2), .02),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.dispose);
    },
  );

  testWidgets('zoom controls keep the board centered and drawing aligned', (
    tester,
  ) async {
    final session = WhiteboardSession.local();
    await session.start();
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WhiteboardView(session: session)),
      ),
    );
    await tester.pumpAndSettle();

    final rect = tester.getRect(find.byType(AnnotationSurface));
    final center = Offset(rect.width / 2, rect.height / 2);
    final transform = tester
        .widget<AnnotationSurface>(find.byType(AnnotationSurface))
        .transformationController!;

    for (final percent in [125, 150, 175, 200, 225, 250, 275, 300]) {
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pumpAndSettle();
      expect(find.text('$percent%'), findsOneWidget);
      expect(transform.toScene(center).dx, closeTo(800, .01));
      expect(transform.toScene(center).dy, closeTo(450, .01));
    }

    await tester.dragFrom(rect.center, const Offset(32, 24));
    await tester.pumpAndSettle();
    expect(session.canvas.shapes, hasLength(1));
    final points = session.canvas.shapes.single.points;
    expect(points.first.x, closeTo(.5, .01));
    expect(points.first.y, closeTo(.5, .01));
    expect(points.last.x, closeTo(.5 + 32 / 1600 / 3, .01));
    expect(points.last.y, closeTo(.5 + 24 / 900 / 3, .01));

    for (final percent in [275, 250, 225, 200, 175, 150, 125, 100]) {
      await tester.tap(find.byTooltip('Zoom out'));
      await tester.pumpAndSettle();
      expect(find.text('$percent%'), findsOneWidget);
      expect(transform.toScene(center).dx, closeTo(800, .01));
      expect(transform.toScene(center).dy, closeTo(450, .01));
    }
    await tester.dragFrom(rect.center, const Offset(32, 24));
    await tester.pumpAndSettle();
    expect(session.canvas.shapes, hasLength(2));
    expect(session.canvas.shapes.last.points.first.x, closeTo(.5, .01));
    expect(session.canvas.shapes.last.points.first.y, closeTo(.5, .01));
  });

  testWidgets(
    'mobile two-finger zoom and pan keep one-finger drawing aligned',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 760);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final session = WhiteboardSession.local();
      await session.start();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WhiteboardView(session: session)),
        ),
      );
      await tester.pumpAndSettle();
      final surface = find.byType(AnnotationSurface);
      final rect = tester.getRect(surface);
      final transform = tester
          .widget<AnnotationSurface>(surface)
          .transformationController!;
      expect(transform.value.getMaxScaleOnAxis(), closeTo(1, .01));

      final first = await tester.startGesture(
        rect.center + const Offset(-45, 0),
        pointer: 11,
      );
      final second = await tester.startGesture(
        rect.center + const Offset(45, 0),
        pointer: 12,
      );
      await tester.pump();
      await first.moveBy(const Offset(-75, 0));
      await tester.pump();
      await second.moveBy(const Offset(75, 0));
      await tester.pump();
      expect(transform.value.getMaxScaleOnAxis(), greaterThan(1.2));
      final oldCenter = transform.toScene(rect.center - rect.topLeft);
      await first.moveBy(const Offset(0, 65));
      await second.moveBy(const Offset(0, 65));
      await tester.pump();
      final newCenter = transform.toScene(rect.center - rect.topLeft);
      expect(newCenter.dy, lessThan(oldCenter.dy));
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(
        session.canvas.shapes,
        isEmpty,
        reason: 'Two fingers must navigate without drawing',
      );

      final expected = transform.toScene(rect.center - rect.topLeft);
      await tester.dragFrom(rect.center, const Offset(30, 15));
      await tester.pumpAndSettle();
      expect(session.canvas.shapes, hasLength(1));
      expect(
        session.canvas.shapes.single.points.first.x,
        closeTo(expected.dx / 1600, .02),
      );
      expect(
        session.canvas.shapes.single.points.first.y,
        closeTo(expected.dy / 900, .02),
      );
    },
  );

  testWidgets('whiteboard can persist ink outside the original page bounds', (
    tester,
  ) async {
    final session = WhiteboardSession.local();
    await session.start();
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WhiteboardView(session: session)),
      ),
    );
    await tester.pumpAndSettle();
    final surface = find.byType(AnnotationSurface);
    final rect = tester.getRect(surface);
    final transform = tester
        .widget<AnnotationSurface>(surface)
        .transformationController!;
    transform.value = Matrix4.identity()..translateByDouble(2200, 0, 0, 1);
    await tester.pump();
    await tester.dragFrom(rect.center, const Offset(35, 20));
    await tester.pumpAndSettle();
    expect(session.canvas.shapes.single.points.first.x, lessThan(0));
    expect(session.canvas.shapes.single.toJson()['points'], isNotEmpty);
  });

  testWidgets('mobile hand tool pans with one finger and resets to center', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 760);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final session = WhiteboardSession.local();
    await session.start();
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WhiteboardView(session: session)),
      ),
    );
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byType(AnnotationSurface));
    final transform = tester
        .widget<AnnotationSurface>(find.byType(AnnotationSurface))
        .transformationController!;
    final viewportCenter = Offset(rect.width / 2, rect.height / 2);
    await tester.tap(find.byTooltip('Draw / navigate'));
    await tester.pumpAndSettle();
    await tester.dragFrom(rect.center, const Offset(85, 55));
    await tester.pumpAndSettle();
    expect(transform.toScene(viewportCenter).dx, lessThan(790));
    expect(session.canvas.shapes, isEmpty);
    await tester.tap(find.byTooltip('Reset whiteboard view'));
    await tester.pumpAndSettle();
    expect(transform.toScene(viewportCenter).dx, closeTo(800, .01));
    expect(transform.toScene(viewportCenter).dy, closeTo(450, .01));
    await tester.tap(find.byTooltip('Pen'));
    await tester.pumpAndSettle();
    await tester.dragFrom(rect.center, const Offset(30, 20));
    await tester.pumpAndSettle();
    expect(session.canvas.shapes, hasLength(1));
  });
}
