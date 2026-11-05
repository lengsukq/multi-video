import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_realtime_design_ui/flutter_realtime_design_ui.dart';
import 'package:flutter_realtime_classroom_core/flutter_realtime_classroom_core.dart';
import 'package:flutter_realtime_classroom_ui/flutter_realtime_classroom_ui.dart';
import 'package:flutter_test/flutter_test.dart';

class Repository implements ClassroomRepository {
  Repository(this.teacher);
  final bool teacher;
  bool fail = false;
  final calls = <(String, Map<String, dynamic>)>[];
  @override
  Future<ClassroomState> snapshot() async => ClassroomState(
    roomCode: 'room1',
    selfUserId: teacher ? 'teacher' : 'alice',
    role: teacher ? ClassroomRole.teacher : ClassroomRole.student,
    revision: 1,
    students: const [],
    questions: const [],
    stats: const ClassroomStats(),
    tools: ClassroomToolsState(
      annotation: AnnotationCanvas(
        canvasId: 'c1',
        sourceKey: 'share1',
        participantId: 'teacher1',
      ),
      activities: [
        ClassroomActivity(
          id: 'quiz1',
          kind: ClassroomActivityKind.quiz,
          title: '2+2?',
          options: const ['3', '4'],
          closed: false,
        ),
      ],
    ),
  );
  @override
  Future<ClassroomState> action(ClassroomCommand command) {
    final type = command.wireName;
    final data = command.toWireData();
    calls.add((
      type,
      Map<String, dynamic>.from(jsonDecode(data['payload'] ?? '{}') as Map),
    ));
    if (fail) {
      throw const RealtimeException(
        code: RealtimeErrorCode.serverError,
        message: 'Publish failed',
      );
    }
    return snapshot();
  }

  @override
  void close() {}
}

void main() {
  testWidgets('tools sheet header fits 320px at 200% text scaling', (
    tester,
  ) async {
    final repository = Repository(true);
    final session = ClassroomSession(
      repository,
      pollInterval: const Duration(hours: 1),
    );
    await session.start();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 460,
              child: ClassroomToolsPanel(
                classroom: session,
                showHeader: true,
                onClose: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Wrap), findsWidgets);
    expect(find.byIcon(Icons.close_rounded), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await session.dispose();
  });

  testWidgets(
    'teacher publishes tools and student answers without teacher controls',
    (tester) async {
      for (final teacher in [true, false]) {
        final repository = Repository(teacher);
        final session = ClassroomSession(
          repository,
          pollInterval: const Duration(hours: 1),
        );
        await session.start();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ClassroomToolsPanel(classroom: session)),
          ),
        );
        await tester.pump();
        if (teacher) {
          await tester.tap(find.text('Announcement'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'Hello class');
          await tester.tap(find.text('Publish'));
          await tester.pumpAndSettle();
          expect(repository.calls.single.$1, 'tool.notice.publish');
          expect(repository.calls.single.$2['text'], 'Hello class');
        } else {
          expect(find.text('Announcement'), findsNothing);
          await tester.tap(find.text('4'));
          await tester.pump();
          expect(repository.calls.single.$1, 'tool.activity.answer');
          expect(repository.calls.single.$2['option'], 1);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await session.dispose();
      }
    },
  );
  testWidgets('annotation toolbar fits a phone and students cannot edit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final teacher in [true, false]) {
      final repository = Repository(teacher);
      final session = ClassroomSession(
        repository,
        pollInterval: const Duration(hours: 1),
      );
      await session.start();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 180,
                child: ClassroomAnnotationOverlay(
                  session: session.annotations,
                  participantId: 'teacher1',
                  localShare: teacher,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      if (teacher) {
        await tester.tap(find.byTooltip('Annotate'));
        await tester.pump();
        expect(find.byTooltip('Pen'), findsOneWidget);
        expect(find.byTooltip('Undo'), findsOneWidget);
      } else {
        expect(find.byTooltip('Annotate'), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await session.dispose();
    }
  });
  for (final count in [2, 8]) {
    testWidgets(
      'quiz publishes $count options and the selected numbered answer',
      (tester) async {
        final repo = Repository(true);
        final session = ClassroomSession(
          repo,
          pollInterval: const Duration(hours: 1),
        );
        await session.start();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ClassroomToolsPanel(classroom: session)),
          ),
        );
        await tester.tap(find.text('Quiz'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).at(0), 'Question');
        final options = List.generate(count, (i) => 'Option ${i + 1}');
        await tester.enterText(
          find.byType(TextField).at(1),
          '\n${options.join('\n\n')}\n',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButtonFormField<int>));
        await tester.pumpAndSettle();
        final answer = find.text('$count. Option $count').last;
        await tester.ensureVisible(answer);
        await tester.tap(answer);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Publish'));
        await tester.pumpAndSettle();
        expect(repo.calls.single.$2['options'], options);
        expect(repo.calls.single.$2['correctOption'], count - 1);
        expect(find.byType(RealtimeGlassDialog), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await session.dispose();
      },
    );
  }

  testWidgets(
    'quiz validation and publication failures retain the dialog and its input',
    (tester) async {
      final repo = Repository(true);
      final session = ClassroomSession(
        repo,
        pollInterval: const Duration(hours: 1),
      );
      await session.start();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ClassroomToolsPanel(classroom: session)),
        ),
      );
      await tester.tap(find.text('Quiz'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).at(0),
        'Keep this question',
      );
      await tester.enterText(find.byType(TextField).at(1), 'A\nA');
      await tester.tap(find.text('Publish'));
      await tester.pumpAndSettle();
      expect(find.text('Options must be distinct.'), findsOneWidget);
      expect(repo.calls, isEmpty);
      await tester.enterText(find.byType(TextField).at(1), 'A\nB');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2. B').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), 'A\nC');
      await tester.tap(find.text('Publish'));
      await tester.pumpAndSettle();
      expect(find.text('Select a valid correct answer.'), findsOneWidget);
      expect(repo.calls, isEmpty);
      await tester.enterText(find.byType(TextField).at(1), 'A');
      await tester.tap(find.text('Publish'));
      await tester.pumpAndSettle();
      expect(find.text('Enter 2–8 options.'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(1), 'A\nC');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2. C').last);
      await tester.pumpAndSettle();
      repo.fail = true;
      await tester.tap(find.text('Publish'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Publish failed'), findsOneWidget);
      expect(find.byType(RealtimeGlassDialog), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
        'Keep this question',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        'A\nC',
      );
      repo.fail = false;
      await tester.tap(find.text('Publish'));
      await tester.pumpAndSettle();
      expect(find.byType(RealtimeGlassDialog), findsNothing);
      expect(repo.calls.last.$2['correctOption'], 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await session.dispose();
    },
  );
}
