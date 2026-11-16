import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multi_video/demo_aws_provider_panel.dart';

void main() {
  testWidgets('AWS macOS Demo shows both routes and opens backend dashboard', (
    tester,
  ) async {
    Uri? opened;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DemoAwsProviderPanel(
          backendUrl: 'http://192.168.31.2:3000/health?secret=discard',
          activeProviderId: 'aws',
          online: true,
          openDashboard: (uri) async {
            opened = uri;
            return true;
          },
        ),
      ),
    ));

    expect(find.textContaining('AWS Chime SDK'), findsOneWidget);
    expect(find.textContaining('Amazon IVS Real-Time'), findsOneWidget);
    expect(find.text('AWS selected on backend'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('demo-manage-aws-provider')));
    await tester.pump();
    expect(opened.toString(), 'http://192.168.31.2:3000/');
  });

  testWidgets('AWS macOS Demo does not open invalid backend URLs', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: DemoAwsProviderPanel(
          backendUrl: 'not a backend URL',
          activeProviderId: null,
          online: false,
        ),
      ),
    ));
    expect(find.text('Backend not verified'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('demo-manage-aws-provider')),
    );
    expect(button.onPressed, isNull);
  });
}
