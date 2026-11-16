import 'package:flutter/material.dart';
import 'package:flutter_realtime_design_ui/flutter_realtime_design_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'standalone SDK modals use the workspace theme and preserve host overrides',
    (tester) async {
      final host = RealtimeUiTheme.light(
        appearance: const RealtimeUiThemeExtension(
          bodyFontFamily: 'HostFont',
          controlRadius: 8,
        ),
      );
      for (final theme in [ThemeData(), host]) {
        late BuildContext launcher;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Builder(
              builder: (context) {
                launcher = context;
                return const Scaffold();
              },
            ),
          ),
        );
        ThemeData? modalTheme;
        final dialog = showDialog<void>(
          context: launcher,
          builder: (_) => RealtimeGlassDialog(
            title: const Text('Devices'),
            content: Builder(
              builder: (context) {
                modalTheme = Theme.of(context);
                return const ListTile(title: Text('System microphone'));
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          modalTheme!.textTheme.bodyMedium!.fontFamily,
          identical(theme, host) ? 'HostFont' : RealtimeFonts.body,
        );
        expect(modalTheme!.colorScheme.primary, RealtimeUiTokens.accent);
        expect(find.byType(BackdropFilter), findsNothing);
        expect(tester.takeException(), isNull);
        Navigator.pop(launcher);
        await tester.pumpAndSettle();
        await dialog;
        final sheet = showRealtimeGlassBottomSheet<void>(
          context: launcher,
          builder: (context) {
            modalTheme = Theme.of(context);
            return const ListTile(title: Text('Background effects'));
          },
        );
        await tester.pumpAndSettle();
        expect(
          modalTheme!.textTheme.bodyMedium!.fontFamily,
          identical(theme, host) ? 'HostFont' : RealtimeFonts.body,
        );
        expect(find.byType(BackdropFilter), findsNothing);
        expect(tester.takeException(), isNull);
        Navigator.pop(launcher);
        await tester.pumpAndSettle();
        await sheet;
      }
    },
  );

  testWidgets('host-provided lazy lists retain a bounded dialog viewport', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeGlassDialog(
          title: const Text('Device list'),
          content: ListView.builder(
            itemCount: 30,
            itemBuilder: (_, index) => ListTile(title: Text('Device $index')),
          ),
          actions: [TextButton(onPressed: () {}, child: const Text('Done'))],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Done'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Done').hitTestable(), findsOneWidget);
  });

  testWidgets(
    'large text and a keyboard keep dialog actions reachable by scrolling',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 480);
      tester.view.viewInsets = const FakeViewPadding(bottom: 160);
      addTearDown(tester.view.reset);
      late BuildContext launcher;
      var submitted = false;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Builder(
            builder: (context) {
              launcher = context;
              return const Scaffold();
            },
          ),
        ),
      );
      final dialog = showDialog<void>(
        context: launcher,
        builder: (context) => RealtimeGlassDialog(
          icon: Icons.edit_outlined,
          title: const Text('Publish an announcement'),
          content: const TextField(maxLines: 5),
          actions: [
            FilledButton(
              onPressed: () {
                submitted = true;
                Navigator.pop(context);
              },
              child: const Text('Publish'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Publish'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Publish'));
      await tester.pumpAndSettle();
      await dialog;
      expect(submitted, isTrue);
    },
  );

  testWidgets(
    'RealtimeGlassDialog skips BackdropFilter on iOS even when glass is enabled',
    (tester) async {
      final glassTheme = ThemeData(
        useMaterial3: true,
        extensions: const [
          RealtimeUiThemeExtension(glassEnabled: true, blur: 16),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: glassTheme,
          home: RealtimeGlassDialog(
            title: const Text('Leave room?'),
            content: const Text('Confirm leaving'),
            actions: [TextButton(onPressed: () {}, child: const Text('Leave'))],
          ),
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
