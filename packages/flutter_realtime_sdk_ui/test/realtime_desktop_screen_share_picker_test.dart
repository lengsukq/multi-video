import 'package:flutter/material.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_realtime_sdk_ui/src/realtime_desktop_screen_share_picker.dart';

void main() {
  const sources = <MediaScreenShareSource>[
    MediaScreenShareSource(
      id: 'screen:0',
      name: 'Primary display',
      kind: MediaScreenShareSourceKind.display,
    ),
    MediaScreenShareSource(
      id: 'window:1204',
      name: 'Editor',
      kind: MediaScreenShareSourceKind.window,
    ),
  ];

  testWidgets('screen picker offers displays and windows with separate labels',
      (tester) async {
    MediaScreenShareSource? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) => TextButton(
          onPressed: () async {
            selected = await showDesktopScreenSharePicker(context, sources);
          },
          child: const Text('Share'),
        )),
      ),
    ));
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(find.text('Primary display'), findsOneWidget);
    expect(find.text('Editor'), findsOneWidget);
    expect(find.text('Application window'), findsOneWidget);
    await tester.tap(find.text('Editor'));
    await tester.pumpAndSettle();
    expect(selected?.id, 'window:1204');
  });

  testWidgets('cancelling picker returns no source', (tester) async {
    MediaScreenShareSource? selected = sources.first;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) => TextButton(
          onPressed: () async {
            selected = await showDesktopScreenSharePicker(context, sources);
          },
          child: const Text('Share'),
        )),
      ),
    ));
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
  });
}
