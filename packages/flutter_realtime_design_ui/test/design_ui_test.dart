import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_design_ui/flutter_realtime_design_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'compact workspace keeps its header fixed and labels every destination',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var destination = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: RealtimeUiTheme.light(),
          home: RealtimeWorkspaceShell(
            selectedIndex: 0,
            compactNavigation: true,
            header: const SizedBox(height: 56, child: Text('Workspace header')),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.chat_outlined),
                label: 'Chat',
              ),
            ],
            onDestinationSelected: (value) => destination = value,
            child: ListView(
              children: List.generate(
                30,
                (i) => SizedBox(height: 64, child: Text('Room $i')),
              ),
            ),
          ),
        ),
      );
      final header = tester.getRect(find.text('Workspace header'));
      final chat = find.byTooltip('Chat');
      expect(chat, findsOneWidget);
      expect(tester.getRect(chat).right, lessThanOrEqualTo(60));
      await tester.tap(chat);
      expect(destination, 1);
      await tester.drag(find.byType(ListView).last, const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('Workspace header')), header);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'join-type sliding selection matches the outer capsule radius and toggles',
    (tester) async {
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: RealtimeUiTheme.light(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 320,
                child: StatefulBuilder(
                  builder: (context, setLocalState) =>
                      RealtimeCupertinoSegmentedBar<int>(
                        groupValue: selected,
                        children: const {
                          0: Text('Join meeting'),
                          1: Text('Watch live'),
                        },
                        onValueChanged: (value) =>
                            setLocalState(() => selected = value),
                      ),
                ),
              ),
            ),
          ),
        ),
      );
      final segmented = find.byType(RealtimeCupertinoSegmentedBar<int>);
      final outer = tester.widget<Container>(
        find.descendant(of: segmented, matching: find.byType(Container)).first,
      );
      final thumb = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('realtime-segmented-thumb')),
      );
      final outerRadius =
          (outer.decoration! as BoxDecoration).borderRadius! as BorderRadius;
      final thumbRadius =
          (thumb.decoration as BoxDecoration).borderRadius! as BorderRadius;
      expect(outerRadius.topLeft.x, 24);
      expect(thumbRadius.topLeft.x, 20);
      expect(outerRadius.topLeft.x - thumbRadius.topLeft.x, 4);
      expect(tester.getSize(segmented).height, 48);
      await tester.tap(find.text('Watch live'));
      await tester.pumpAndSettle();
      expect(selected, 1);
      expect(
        tester
            .widget<AnimatedPositioned>(
              find.descendant(
                of: segmented,
                matching: find.byType(AnimatedPositioned),
              ),
            )
            .left,
        greaterThan(0),
      );
      await tester.drag(find.text('Watch live'), const Offset(-160, 0));
      await tester.pumpAndSettle();
      expect(selected, 0);
    },
  );

  testWidgets('meeting tab highlight keeps the same track curvature', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              child: RealtimeSegmentedTabs<int>(
                selectedValue: 0,
                onChanged: (_) {},
                tabs: const [
                  RealtimeSegmentTab(value: 0, label: 'Chat'),
                  RealtimeSegmentTab(value: 1, label: 'Members'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final segmented = find.byType(RealtimeSegmentedTabs<int>);
    final outer = tester.widget<Container>(
      find.descendant(of: segmented, matching: find.byType(Container)).first,
    );
    final active = tester.widget<AnimatedPositioned>(
      find.descendant(of: segmented, matching: find.byType(AnimatedPositioned)),
    );
    final outerRadius =
        (outer.decoration! as BoxDecoration).borderRadius! as BorderRadius;
    final thumbRadius =
        ((active.child as Container).decoration! as BoxDecoration).borderRadius!
            as BorderRadius;
    expect(outerRadius.topLeft.x, 23);
    expect(thumbRadius.topLeft.x, 19);
    expect(outerRadius.topLeft.x - thumbRadius.topLeft.x, 4);
  });

  testWidgets('meeting sidebar tabs remain horizontal at 300 px', (
    tester,
  ) async {
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: StatefulBuilder(
                builder: (context, setState) => RealtimeSegmentedTabs<int>(
                  height: 40,
                  selectedValue: selected,
                  onChanged: (value) => setState(() => selected = value),
                  tabs: const [
                    RealtimeSegmentTab(value: 0, label: '聊天'),
                    RealtimeSegmentTab(value: 1, label: '成员'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(ListTile), findsNothing);
    expect(find.byType(AnimatedPositioned), findsOneWidget);
    expect(tester.getSize(find.byType(RealtimeSegmentedTabs<int>)).height, 40);
    expect(
      tester.getRect(find.text('聊天')).top,
      closeTo(tester.getRect(find.text('成员')).top, 1),
    );
    await tester.tap(find.text('成员'));
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two short Cupertino segments stay horizontal at 240px', (
    tester,
  ) async {
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              child: StatefulBuilder(
                builder: (context, setState) =>
                    RealtimeCupertinoSegmentedBar<int>(
                      groupValue: selected,
                      onValueChanged: (value) =>
                          setState(() => selected = value),
                      children: const {0: Text('Audio'), 1: Text('Video')},
                    ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(ListTile), findsNothing);
    expect(
      find.byKey(const ValueKey('realtime-segmented-thumb')),
      findsOneWidget,
    );
    await tester.tap(find.text('Video'));
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('three long Cupertino segments stack at 280px', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              child: RealtimeCupertinoSegmentedBar<int>(
                groupValue: 0,
                onValueChanged: (_) {},
                children: const {
                  0: Text('No background'),
                  1: Text('Background blur'),
                  2: Text('Replace background'),
                },
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(ListTile), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('segmented tabs keep accessible list on genuinely tiny widths', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 150,
              child: RealtimeSegmentedTabs<int>(
                selectedValue: 0,
                onChanged: (_) {},
                tabs: const [
                  RealtimeSegmentTab(value: 0, label: 'Chat'),
                  RealtimeSegmentTab(value: 1, label: 'People'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(ListTile), findsNWidgets(2));
    expect(find.byType(AnimatedPositioned), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('segmented preferences stack accessibly on tiny windows', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: 220,
            child: RealtimeCupertinoSegmentedBar<int>(
              groupValue: 1,
              onValueChanged: (_) {},
              children: const {
                0: Text('No effect'),
                1: Text('Blur effect'),
                2: Text('Replace background'),
              },
            ),
          ),
        ),
      ),
    );
    expect(find.byType(ListTile), findsNWidgets(3));
    expect(find.byType(CupertinoSlidingSegmentedControl<int>), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('ambient color always paints an opaque light base', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: const SizedBox(
              width: 120,
              height: 120,
              child: RealtimeAmbientBackground(child: SizedBox.expand()),
            ),
          ),
        ),
      ),
    );
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        for (var pixel = 0; pixel < bytes.lengthInBytes; pixel += 4) {
          expect(bytes.getUint8(pixel + 3), 255);
          expect(bytes.getUint8(pixel), greaterThan(225));
          expect(bytes.getUint8(pixel + 1), greaterThan(225));
          expect(bytes.getUint8(pixel + 2), greaterThan(225));
        }
      } finally {
        image.dispose();
      }
    });
  });
  testWidgets('host geometry and typography reach public controls', (
    tester,
  ) async {
    final editor = TextEditingController();
    addTearDown(editor.dispose);
    final base = RealtimeUiTheme.light(
      appearance: const RealtimeUiThemeExtension(controlRadius: 37),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: base.copyWith(
          textTheme: base.textTheme.apply(fontFamily: 'HostFont'),
        ),
        home: Scaffold(
          body: Column(
            children: [
              RealtimeGlassIconButton(icon: Icons.add, onPressed: () {}),
              RealtimeGlassButton(onPressed: () {}, child: const Text('Save')),
              FilledButton(onPressed: () {}, child: const Text('Confirm')),
              RealtimeGlassTextField(controller: editor, label: 'Name'),
            ],
          ),
        ),
      ),
    );
    for (final type in [
      RealtimeGlassIconButton,
      RealtimeGlassButton,
      RealtimeGlassTextField,
    ]) {
      final container = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byType(type),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      expect(
        (container.decoration! as BoxDecoration).borderRadius,
        BorderRadius.circular(37),
      );
    }
    expect(
      DefaultTextStyle.of(tester.element(find.text('Save'))).style.fontFamily,
      'HostFont',
    );
    expect(
      DefaultTextStyle.of(
        tester.element(find.text('Confirm')),
      ).style.fontFamily,
      'HostFont',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).style!.fontFamily,
      'HostFont',
    );
  });

  testWidgets(
    'explicit default-valued surface settings win over the host theme',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: RealtimeUiTheme.light(
            appearance: const RealtimeUiThemeExtension(
              cardRadius: 40,
              controlRadius: 37,
              glassEnabled: true,
              blur: 30,
              glassOpacity: .6,
            ),
          ),
          home: Scaffold(
            body: Column(
              children: [
                RealtimeGlassIconButton(
                  icon: Icons.add,
                  onPressed: () {},
                  radius: 20,
                ),
                const RealtimeCardSurface(radius: 28, child: Text('Card')),
                const RealtimeGlassSurface(
                  radius: 28,
                  blur: 24,
                  opacity: .82,
                  child: Text('Glass'),
                ),
              ],
            ),
          ),
        ),
      );
      final icon = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byType(RealtimeGlassIconButton),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      expect(
        (icon.decoration! as BoxDecoration).borderRadius,
        BorderRadius.circular(20),
      );
      for (final type in [RealtimeCardSurface, RealtimeGlassSurface]) {
        final box = tester.widget<Container>(
          find
              .descendant(
                of: find.byType(type),
                matching: find.byType(Container),
              )
              .first,
        );
        expect(
          (box.decoration! as BoxDecoration).borderRadius,
          BorderRadius.circular(28),
        );
      }
      final glass = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(RealtimeGlassSurface),
              matching: find.byType(Container),
            )
            .first,
      );
      expect((glass.decoration! as BoxDecoration).color!.a, closeTo(.82, .001));
      expect(
        tester
            .widget<BackdropFilter>(find.byType(BackdropFilter))
            .filter
            .toString(),
        contains('24.0'),
      );
    },
  );

  testWidgets(
    'idle controls stay visible while keyboard focus is inside them',
    (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var activations = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RealtimeIdleControls(
              hideAfter: const Duration(seconds: 1),
              child: const SizedBox.expand(),
              controls: TextButton(
                focusNode: focus,
                onPressed: () => activations++,
                child: const Text('Action'),
              ),
            ),
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      final opacity = find.ancestor(
        of: find.text('Action'),
        matching: find.byType(AnimatedOpacity),
      );
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(activations, 1);
      focus.unfocus();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(activations, 1);
    },
  );

  test('the cool-gray palette keeps text and actions readable', () {
    final palette = RealtimeStyle.light;
    expect(palette.background, const Color(0xFFE9EDF2));
    expect(palette.primary, RealtimeUiTokens.accent);
    expect(palette.accent, const Color(0xFFF5C518));
    expect(_contrast(palette.text, palette.surface), greaterThan(16));
    expect(_contrast(palette.textMuted, palette.surface), greaterThan(4.5));
    // Amber is a filled-action color: its label must be the dark ink.
    expect(_contrast(palette.onAccent, palette.accent), greaterThan(7));
    expect(_contrast(palette.surface, palette.accent), lessThan(2));
    expect(_contrast(palette.surface, palette.danger), greaterThan(4.5));
    expect(_contrast(palette.surface, palette.speak), greaterThan(3));
    expect(_contrast(palette.speakStrong, palette.surface), greaterThan(4.5));
    expect(_contrast(palette.surface, palette.speakStrong), greaterThan(4.5));
    expect(_contrast(palette.success, palette.successSubtle), greaterThan(4.5));
    expect(
      palette.copyWith(speakStrong: Colors.black).speakStrong,
      Colors.black,
    );
    expect(RealtimeUiTheme.light().brightness, Brightness.light);
    // ignore: deprecated_member_use
    expect(RealtimeUiTheme.dark().brightness, Brightness.light);
  });

  testWidgets(
    'actionable pills meet the mobile touch target without inflating labels',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: RealtimeUiTheme.light(),
          home: Scaffold(
            body: Column(
              children: [
                RealtimePill(label: 'Filter', onTap: () => taps++),
                const RealtimePill(label: 'Status'),
              ],
            ),
          ),
        ),
      );
      final active = find.widgetWithText(RealtimePill, 'Filter');
      final passive = find.widgetWithText(RealtimePill, 'Status');
      expect(tester.getSize(active).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(passive).height, lessThan(48));
      await tester.tap(active);
      await tester.pump();
      expect(taps, 1);
    },
  );

  testWidgets(
    'a host can override the public theme without media dependencies',
    (tester) async {
      final appearance = const RealtimeUiThemeExtension().copyWith(
        palette: RealtimeStyle.light.copyWith(
          primary: const Color(0xFF503C2B),
          surface: const Color(0xFFFFFCF8),
        ),
        cardRadius: 40,
        glassEnabled: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: RealtimeUiTheme.light(appearance: appearance),
          home: const Scaffold(
            body: RealtimeCardSurface(child: Text('Host content')),
          ),
        ),
      );
      final context = tester.element(find.byType(RealtimeCardSurface));
      expect(RealtimeStyle.of(context).primary, const Color(0xFF503C2B));
      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(RealtimeCardSurface),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, const Color(0xFFFFFCF8));
      expect(decoration.borderRadius, BorderRadius.circular(40));
      expect(find.byType(BackdropFilter), findsNothing);
    },
  );

  testWidgets('glass becomes opaque for host preferences and high contrast', (
    tester,
  ) async {
    for (final highContrast in [false, true]) {
      for (final enabled in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: RealtimeUiTheme.light(
              appearance: RealtimeUiThemeExtension(glassEnabled: enabled),
            ),
            home: MediaQuery(
              data: MediaQueryData(highContrast: highContrast),
              child: const Scaffold(
                body: RealtimeGlassSurface(child: Text('Readable controls')),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(BackdropFilter),
          enabled && !highContrast ? findsOneWidget : findsNothing,
        );
        final container = tester.widget<Container>(
          find
              .descendant(
                of: find.byType(RealtimeGlassSurface),
                matching: find.byType(Container),
              )
              .first,
        );
        final fill = (container.decoration! as BoxDecoration).color!;
        expect(fill.a, enabled && !highContrast ? lessThan(1) : 1);
      }
    }
  });

  testWidgets('glass controls support keyboard activation and reduced motion', (
    tester,
  ) async {
    var activations = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(
          appearance: const RealtimeUiThemeExtension(motionEnabled: false),
        ),
        home: Scaffold(
          body: RealtimeGlassPressable(
            onTap: () => activations++,
            child: const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Open tools'),
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(activations, 1);
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).duration,
      Duration.zero,
    );
  });

  testWidgets('top-level navigation preserves content when layouts change', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    var selected = 0;
    final editor = TextEditingController(text: 'draft');
    addTearDown(editor.dispose);
    for (final width in [320.0, 390.0, 768.0, 1024.0, 1280.0, 1440.0]) {
      tester.view.physicalSize = Size(width, 850);
      await tester.pumpWidget(
        MaterialApp(
          theme: RealtimeUiTheme.light(),
          home: StatefulBuilder(
            builder: (context, setState) => RealtimeWorkspaceShell(
              selectedIndex: selected,
              onDestinationSelected: (value) =>
                  setState(() => selected = value),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
                NavigationDestination(icon: Icon(Icons.chat), label: 'Chat'),
                NavigationDestination(
                  icon: Icon(Icons.settings),
                  label: 'Settings',
                ),
              ],
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: TextField(controller: editor),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'width $width');
      expect(editor.text, 'draft');
      await tester.tap(find.text('Chat').last);
      await tester.pumpAndSettle();
      expect(selected, 1);
    }
  });

  testWidgets('speaker stage survives narrow windows and enlarged labels', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: const Scaffold(
            body: RealtimeMeetingFilmstripStage(
              primaryParticipant: RealtimeMeetingTileData(
                id: 'host',
                displayName: 'Long presenter name for accessibility',
              ),
              participants: [
                RealtimeMeetingTileData(
                  id: 'member',
                  displayName: 'Another participant',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('accessible navigation never hides meeting actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: const MediaQuery(
          data: MediaQueryData(accessibleNavigation: true),
          child: Scaffold(
            body: RealtimeIdleControls(
              hideAfter: Duration(milliseconds: 500),
              child: ColoredBox(color: Colors.black),
              controls: SizedBox(height: 60, child: Text('Accessible dock')),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    final opacity = find.descendant(
      of: find.byType(RealtimeIdleControls),
      matching: find.byType(AnimatedOpacity),
    );
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'filmstrip switches the focused participant without rebuilding a room',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var selectedId = 'alice';
      await tester.pumpWidget(
        MaterialApp(
          theme: RealtimeUiTheme.light(),
          home: StatefulBuilder(
            builder: (context, update) {
              final members = [
                const RealtimeMeetingTileData(
                  id: 'alice',
                  displayName: 'Alice',
                ),
                const RealtimeMeetingTileData(id: 'bob', displayName: 'Bob'),
                const RealtimeMeetingTileData(
                  id: 'carol',
                  displayName: 'Carol',
                ),
              ];
              return Scaffold(
                body: RealtimeMeetingFilmstripStage(
                  primaryParticipant: members.firstWhere(
                    (p) => p.id == selectedId,
                  ),
                  participants: members
                      .where((p) => p.id != selectedId)
                      .toList(),
                  bottomControlsInset: 90,
                  onSelectParticipant: (p) => update(() => selectedId = p.id),
                ),
              );
            },
          ),
        ),
      );
      final first = tester.widget<RealtimeMeetingFilmstripStage>(
        find.byType(RealtimeMeetingFilmstripStage),
      );
      expect(first.primaryParticipant.id, 'alice');
      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      final next = tester.widget<RealtimeMeetingFilmstripStage>(
        find.byType(RealtimeMeetingFilmstripStage),
      );
      expect(next.primaryParticipant.id, 'bob');
      expect(next.participants.map((p) => p.id), contains('alice'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('idle controls fade and pointer motion brings them back', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: RealtimeUiTheme.light(),
        home: const Scaffold(
          body: RealtimeIdleControls(
            hideAfter: Duration(seconds: 2),
            child: ColoredBox(color: Colors.black),
            controls: SizedBox(height: 64, child: Text('Controls')),
          ),
        ),
      ),
    );
    final opacity = find.descendant(
      of: find.byType(RealtimeIdleControls),
      matching: find.byType(AnimatedOpacity),
    );
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(100, 100));
    await mouse.moveTo(const Offset(120, 120));
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });
}

double _contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance();
  final b = background.computeLuminance();
  return a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
}
