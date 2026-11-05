import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';
import 'package:flutter_realtime_sdk_ui/src/classroom_sidebar_visuals.dart';

/// One raise-hand entry per role and a teacher queue that actually opens.
void main() {
  testWidgets(
    'classroom metrics grow at 200% text without fixed-height overflow',
    (tester) async {
      final room = await _room(
        tester,
        _RaisedHandRepository(ClassroomRole.teacher, 'teacher'),
      );
      addTearDown(room.dispose);
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
                child: RealtimeRoomUiScope(
                  room: room,
                  child: const RealtimeClassroomWorkspace(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final metrics = find.byType(ClassroomSidebarMetric);
      expect(metrics, findsWidgets);
      expect(tester.getSize(metrics.first).height, greaterThan(100));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'teacher is notified outside panels and student receives speaking permission',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(780, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final authority = _ClassAuthority();
      final teacher = await _room(tester, _ClassClient(authority, true));
      final student = await _room(tester, _ClassClient(authority, false));
      addTearDown(teacher.dispose);
      addTearDown(student.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Row(
            children: [
              Expanded(child: RealtimeMeetingPage(room: teacher)),
              Expanded(child: RealtimeMeetingPage(room: student)),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RealtimeMeetingSidePanel), findsNothing);
      await student.classroom!.raiseHand();
      await teacher.classroom!.refresh();
      await tester.pump();
      expect(find.text('Student raised a hand'), findsOneWidget);
      expect(find.byTooltip('Hand requests'), findsOneWidget);
      await teacher.classroom!.refresh();
      await tester.pump();
      expect(find.text('Student raised a hand'), findsOneWidget);
      await teacher.classroom!.grantSpeak('student');
      await student.classroom!.refresh();
      await tester.pump();
      expect(
        find.text('Teacher allowed you to speak. Turn on your microphone.'),
        findsOneWidget,
      );
      expect(find.byTooltip('Hand requests'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await teacher.dispose();
        await student.dispose();
      });
    },
  );

  Future<RealtimeRoom> teacherRoom(WidgetTester tester) async =>
      _room(tester, _RaisedHandRepository(ClassroomRole.teacher, 'teacher'));

  Future<RealtimeRoom> studentRoom(WidgetTester tester) async =>
      _room(tester, _RaisedHandRepository(ClassroomRole.student, 'student'));

  for (final size in const [Size(390, 844), Size(768, 900), Size(1280, 820)]) {
    testWidgets('teacher sees a single hand queue entry at ${size.width}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final room = await teacherRoom(tester);
      addTearDown(room.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: RealtimeStrings.supportedLocales,
          localizationsDelegates: RealtimeStrings.localizationsDelegates,
          theme: RealtimeUiTheme.light(),
          home: RealtimeMeetingPage(room: room),
        ),
      );
      await tester.pumpAndSettle();

      // Teacher queue is now in the tool rail, not the high-frequency dock.
      expect(find.text('Raise hand'), findsNothing);
      expect(find.byType(RealtimeDockHandQueueButton), findsNothing);
      expect(
        find.descendant(
          of: find.byType(RealtimeMeetingRail),
          matching: find.byTooltip('Hand requests'),
        ),
        findsOneWidget,
      );
      // The student raise action must not leak onto the teacher rail or the
      // More menu as a second, inert entry.
      expect(
        find.descendant(
          of: find.byType(RealtimeMeetingRail),
          matching: find.byTooltip('Raise hand'),
        ),
        findsNothing,
      );
    });

    testWidgets('student sees a single raise hand entry at ${size.width}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final room = await studentRoom(tester);
      addTearDown(room.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: RealtimeStrings.supportedLocales,
          localizationsDelegates: RealtimeStrings.localizationsDelegates,
          theme: RealtimeUiTheme.light(),
          home: RealtimeMeetingPage(room: room),
        ),
      );
      await tester.pumpAndSettle();

      // Dock controls are icon-only below the large breakpoint, so the label
      // lives in the tooltip.
      expect(find.byTooltip('Raise hand'), findsOneWidget);
      expect(find.byType(RealtimeDockHandQueueButton), findsNothing);
      expect(find.byTooltip('Hand requests'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(RealtimeMeetingDock),
          matching: find.byType(RealtimeDockRaiseHandButton),
        ),
        findsOneWidget,
      );
      expect(find.byType(RealtimeDockMoreButton), findsNothing);
    });
  }

  testWidgets('teacher hand queue opens from the desktop tool rail', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final room = await teacherRoom(tester);
    addTearDown(room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: RealtimeStrings.supportedLocales,
        localizationsDelegates: RealtimeStrings.localizationsDelegates,
        theme: RealtimeUiTheme.light(),
        home: RealtimeMeetingPage(room: room),
      ),
    );
    await tester.pumpAndSettle();

    final handRequests = find.byTooltip('Hand requests');
    await tester.ensureVisible(handRequests);
    await tester.pumpAndSettle();
    await tester.tap(handRequests);
    await tester.pumpAndSettle();

    expect(find.byType(RealtimeMeetingSidePanel), findsOneWidget);
    expect(find.byType(RealtimeClassroomSidePanel), findsOneWidget);
    // The queue content, not Q&A or People, must be the visible tab.
    expect(find.byType(RealtimeClassroomHandQueue), findsOneWidget);
    expect(find.text('Student'), findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);
  });

  testWidgets('classroom tab groups overview, hands and real Q&A for teacher', (
    tester,
  ) async {
    final room = await teacherRoom(tester);
    addTearDown(room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: RealtimeStrings.supportedLocales,
        localizationsDelegates: RealtimeStrings.localizationsDelegates,
        home: Scaffold(
          body: RealtimeRoomUiScope(
            room: room,
            child: const SizedBox(
              width: 340,
              child: RealtimeClassroomSidePanel(
                initialTabId: RealtimeWorkspaceTab.classroom,
                notesPanel: Text('Host-persisted notes'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RealtimeClassroomWorkspace), findsOneWidget);
    expect(find.byKey(const ValueKey('classroom-overview')), findsOneWidget);
    expect(find.text('Classroom workspace'), findsOneWidget);
    expect(find.text('Hands'), findsWidgets);
    expect(
      find.text('Recording'),
      findsNothing,
      reason: 'No recorder configured for this room',
    );
    expect(find.text('Notes'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('classroom-section-hands')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('classroom-back-to-overview')),
      findsOneWidget,
    );
    expect(find.text('Student'), findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('classroom-back-to-overview')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('classroom-overview')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('classroom-back-to-overview')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('classroom-section-questions')));
    await tester.pumpAndSettle();
    expect(find.byType(RealtimeClassroomQuestions), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('classroom-back-to-overview')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('classroom-overview')), findsOneWidget);
    expect(find.byTooltip('Next sidebar tabs'), findsOneWidget);
    await tester.ensureVisible(find.text('Notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();
    expect(find.text('Host-persisted notes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('classroom activities return to overview without closing panel', (
    tester,
  ) async {
    final room = await _room(tester, _ActivityRepository(teacher: true));
    addTearDown(room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: RealtimeStrings.supportedLocales,
        localizationsDelegates: RealtimeStrings.localizationsDelegates,
        home: Scaffold(
          body: RealtimeRoomUiScope(
            room: room,
            child: const SizedBox(
              width: 340,
              child: RealtimeClassroomSidePanel(
                initialTabId: RealtimeWorkspaceTab.classroom,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final activities = find.byKey(
      const ValueKey('classroom-section-activities'),
    );
    await tester.ensureVisible(activities);
    await tester.pumpAndSettle();
    await tester.tap(activities);
    await tester.pumpAndSettle();
    expect(find.byType(RealtimeClassroomActivityList), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('classroom-back-to-overview')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('classroom-overview')), findsOneWidget);
    expect(find.byType(RealtimeClassroomSidePanel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('student classroom hides teacher hand queue and changes locale', (
    tester,
  ) async {
    final room = await studentRoom(tester);
    addTearDown(room.dispose);
    Widget app(Locale locale) => MaterialApp(
      locale: locale,
      supportedLocales: RealtimeStrings.supportedLocales,
      localizationsDelegates: RealtimeStrings.localizationsDelegates,
      home: Scaffold(
        body: RealtimeRoomUiScope(
          room: room,
          child: const SizedBox(
            width: 340,
            child: RealtimeClassroomSidePanel(
              initialTabId: RealtimeWorkspaceTab.classroom,
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(const Locale('en')));
    await tester.pumpAndSettle();
    expect(find.text('Classroom workspace'), findsOneWidget);
    expect(find.byKey(const ValueKey('classroom-section-hands')), findsNothing);
    expect(find.byType(RealtimeClassroomHandQueue), findsNothing);
    await tester.tap(find.byKey(const ValueKey('classroom-section-questions')));
    await tester.pumpAndSettle();
    expect(find.byType(RealtimeClassroomQuestionComposer), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    await tester.pumpWidget(app(const Locale('zh', 'CN')));
    await tester.pumpAndSettle();
    expect(find.text('课堂工作台'), findsOneWidget);
    expect(find.byType(RealtimeClassroomQuestionComposer), findsOneWidget);
    expect(find.text('返回'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('classroom-back-to-overview')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('classroom-overview')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('directly opened classroom subpage can return at narrow width', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final room = await teacherRoom(tester);
    addTearDown(room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: RealtimeStrings.supportedLocales,
        localizationsDelegates: RealtimeStrings.localizationsDelegates,
        home: Scaffold(
          body: RealtimeRoomUiScope(
            room: room,
            child: const RealtimeClassroomSidePanel(
              initialTabId: RealtimeWorkspaceTab.classroom,
              initialClassroomSection: RealtimeClassroomSection.hands,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RealtimeClassroomHandQueue), findsOneWidget);
    final back = find.byKey(const ValueKey('classroom-back-to-overview'));
    expect(back, findsOneWidget);
    expect(find.text('返回'), findsOneWidget);
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('classroom-overview')), findsOneWidget);
    expect(back, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'server-backed notes and chapter markers are editable and exportable',
    (tester) async {
      final repository = _NotesRepository();
      final room = await _room(tester, repository);
      addTearDown(room.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: RealtimeStrings.supportedLocales,
          localizationsDelegates: RealtimeStrings.localizationsDelegates,
          home: RealtimeRoomUiScope(
            room: room,
            child: const Scaffold(
              body: SizedBox(
                width: 340,
                child: RealtimeClassroomSidePanel(
                  initialTabId: RealtimeWorkspaceTab.notes,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RealtimeClassroomNotesPanel), findsOneWidget);
      expect(find.textContaining('Session-only storage'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('classroom-note-compose')),
        'Student follow-up',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('classroom-note-save')));
      await tester.pumpAndSettle();
      expect(repository.notes, hasLength(1));
      expect(repository.notes.single.text, 'Student follow-up');
      await tester.tap(find.text('Chapter').first);
      await tester.enterText(
        find.byKey(const ValueKey('classroom-note-compose')),
        'Factoring practice',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('classroom-note-save')));
      await tester.pumpAndSettle();
      expect(repository.notes, hasLength(2));
      expect(repository.notes.last.kind, ClassroomNoteKind.chapter);
      expect(
        buildClassroomLessonMinutes(repository.current),
        contains('Factoring practice'),
      );
      expect(
        buildClassroomLessonMinutes(repository.current),
        contains('Student follow-up'),
      );
      final edit = find.byTooltip('Edit note').first;
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextFormField),
        ),
        'Student follow-up confirmed',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Save'),
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.notes.first.text, 'Student follow-up confirmed');

      final delete = find.byTooltip('Delete note').first;
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Delete'),
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.notes, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('notes and tab navigation fit a narrow desktop sidebar', (
    tester,
  ) async {
    final room = await _room(tester, _NotesRepository());
    addTearDown(room.dispose);
    await tester.binding.setSurfaceSize(const Size(320, 460));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: RealtimeStrings.supportedLocales,
        localizationsDelegates: RealtimeStrings.localizationsDelegates,
        home: Scaffold(
          body: RealtimeRoomUiScope(
            room: room,
            child: const RealtimeClassroomSidePanel(
              initialTabId: RealtimeWorkspaceTab.notes,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RealtimeClassroomNotesPanel), findsOneWidget);
    expect(find.byTooltip('Previous sidebar tabs'), findsOneWidget);
    expect(find.byKey(const ValueKey('classroom-note-save')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('classroom-minutes-copy')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'recording chapter action persists through classroom repository and updates live',
    (tester) async {
      final repository = _NotesRepository();
      final room = await _room(tester, repository);
      addTearDown(room.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: RealtimeStrings.supportedLocales,
          localizationsDelegates: RealtimeStrings.localizationsDelegates,
          home: Scaffold(
            body: RealtimeRoomUiScope(
              room: room,
              child: RealtimeRecordingPanel(
                room: room,
                onToggleRecording: () {},
                onOpenResult: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final add = find.byKey(const ValueKey('recording-add-chapter'));
      expect(add, findsOneWidget);
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Exercise review');
      await tester.tap(find.byKey(const ValueKey('recording-confirm-chapter')));
      await tester.pumpAndSettle();
      expect(repository.notes, hasLength(1));
      expect(repository.notes.single.kind, ClassroomNoteKind.chapter);
      expect(repository.notes.single.text, 'Exercise review');
      expect(find.text('Exercise review'), findsOneWidget);
      expect(find.textContaining('Offsets are room-relative'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('student has no teacher recording chapter action', (
    tester,
  ) async {
    final room = await studentRoom(tester);
    addTearDown(room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: RealtimeStrings.supportedLocales,
        localizationsDelegates: RealtimeStrings.localizationsDelegates,
        home: Scaffold(
          body: RealtimeRoomUiScope(
            room: room,
            child: RealtimeRecordingPanel(
              room: room,
              onToggleRecording: () {},
              onOpenResult: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recording-add-chapter')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'teacher creates a real quiz through classroom activity publish',
    (tester) async {
      final repository = _ActivityRepository(teacher: true);
      final room = await _room(tester, repository);
      addTearDown(room.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: RealtimeStrings.supportedLocales,
          localizationsDelegates: RealtimeStrings.localizationsDelegates,
          home: Scaffold(
            body: RealtimeRoomUiScope(
              room: room,
              child: const RealtimeClassroomActivityList(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final create = find.byKey(const ValueKey('classroom-create-activity'));
      expect(create, findsOneWidget);
      await tester.tap(create);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Quiz').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('classroom-activity-title')),
        'What is 2 + 2?',
      );
      await tester.enterText(
        find.byKey(const ValueKey('classroom-activity-option-0')),
        '4',
      );
      await tester.enterText(
        find.byKey(const ValueKey('classroom-activity-option-1')),
        '5',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('classroom-activity-publish')),
      );
      await tester.pumpAndSettle();
      expect(repository.activities, hasLength(1));
      expect(repository.activities.single.title, 'What is 2 + 2?');
      expect(repository.activities.single.kind, ClassroomActivityKind.quiz);
      expect(repository.activities.single.options, ['4', '5']);
      expect(repository.activities.single.correctOption, 0);
      expect(find.text('What is 2 + 2?'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('student cannot create a classroom activity', (tester) async {
    final room = await _room(tester, _ActivityRepository(teacher: false));
    addTearDown(room.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: RealtimeStrings.supportedLocales,
        localizationsDelegates: RealtimeStrings.localizationsDelegates,
        home: Scaffold(
          body: RealtimeRoomUiScope(
            room: room,
            child: const RealtimeClassroomActivityList(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('classroom-create-activity')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

class _ActivityRepository implements ClassroomRepository {
  _ActivityRepository({required this.teacher});
  final bool teacher;
  int revision = 0;
  final activities = <ClassroomActivity>[];

  ClassroomState get current => ClassroomState(
    roomCode: 'activity-room',
    role: teacher ? ClassroomRole.teacher : ClassroomRole.student,
    selfUserId: teacher ? 'teacher' : 'student',
    revision: revision,
    students: const [],
    questions: const [],
    stats: const ClassroomStats(),
    tools: ClassroomToolsState(activities: activities),
  );

  @override
  Future<ClassroomState> snapshot() async => current;

  @override
  Future<ClassroomState> action(ClassroomCommand command) async {
    if (command.tool == ClassroomToolAction.activityPublish.wireName) {
      if (!teacher) throw StateError('Student cannot publish activities');
      activities.add(
        ClassroomActivity(
          id: 'activity-${activities.length}',
          kind: command.payload['kind'] == 'quiz'
              ? ClassroomActivityKind.quiz
              : ClassroomActivityKind.poll,
          title: command.payload['title']! as String,
          options: (command.payload['options']! as List).cast<String>(),
          correctOption: command.payload['correctOption'] as int?,
          closed: false,
        ),
      );
    }
    revision++;
    return current;
  }

  @override
  void close() {}
}

class _NotesRepository implements ClassroomRepository {
  final notes = <ClassroomNote>[];
  int revision = 0;
  ClassroomState get current => ClassroomState(
    roomCode: 'note-room',
    role: ClassroomRole.teacher,
    selfUserId: 'teacher',
    revision: revision,
    students: const [],
    questions: const [],
    stats: const ClassroomStats(),
    notes: List.unmodifiable(notes),
    notesPersistence: 'session',
  );
  @override
  Future<ClassroomState> snapshot() async => current;
  @override
  Future<ClassroomState> action(ClassroomCommand command) async {
    if (command.action == ClassroomAction.noteAdd) {
      notes.add(
        ClassroomNote(
          id: 'note-${notes.length}',
          text: command.arguments['text']!,
          kind: command.arguments['kind'] == 'chapter'
              ? ClassroomNoteKind.chapter
              : ClassroomNoteKind.note,
          authorUserId: 'teacher',
          createdAt: DateTime.utc(2026, 10, 21),
          elapsedSeconds: 90,
        ),
      );
    }
    if (command.action == ClassroomAction.noteUpdate) {
      final index = notes.indexWhere(
        (n) => n.id == command.arguments['noteId'],
      );
      if (index >= 0) {
        final old = notes[index];
        notes[index] = ClassroomNote(
          id: old.id,
          text: command.arguments['text']!,
          kind: old.kind,
          authorUserId: old.authorUserId,
          createdAt: old.createdAt,
          elapsedSeconds: old.elapsedSeconds,
        );
      }
    }
    if (command.action == ClassroomAction.noteDelete) {
      notes.removeWhere((n) => n.id == command.arguments['noteId']);
    }
    revision++;
    return current;
  }

  @override
  void close() {}
}

class _Renderer extends MediaTrackRenderer {
  const _Renderer();
  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      const SizedBox.shrink();
}

class _MediaSession extends Fake implements MediaSession {
  @override
  String get providerId => 'fake';
  @override
  MediaRole get role => MediaRole.participant;
  @override
  MediaCapabilities get capabilities => const MediaCapabilities.meeting();
  @override
  MediaSessionState get state => MediaSessionState.connected;
  @override
  MediaSnapshot get snapshot => MediaSnapshot(
    state: MediaSessionState.connected,
    capabilities: capabilities,
  );
  @override
  Stream<MediaSessionState> get states => const Stream.empty();
  @override
  Stream<MediaSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<MediaEvent> get events => const Stream.empty();
  @override
  Future<void> leave() async {}
  @override
  Future<void> dispose() async {}
}

class _RaisedHandRepository implements ClassroomRepository {
  _RaisedHandRepository(this.role, this.selfUserId);

  final ClassroomRole role;
  final String selfUserId;

  ClassroomState _snapshot() => ClassroomState(
    roomCode: 'classroom-1',
    role: role,
    selfUserId: selfUserId,
    revision: 1,
    students: [
      ClassroomStudent(
        userId: role == ClassroomRole.teacher ? 'student' : selfUserId,
        participantId: role == ClassroomRole.teacher ? 'student' : selfUserId,
        displayName: 'Student',
        online: true,
        handRaised: role == ClassroomRole.teacher,
        canSpeak: false,
      ),
    ],
    questions: const [],
    stats: const ClassroomStats(),
  );

  @override
  Future<ClassroomState> snapshot() async => _snapshot();

  @override
  Future<ClassroomState> action(ClassroomCommand command) async => _snapshot();

  @override
  void close() {}
}

Future<RealtimeRoom> _room(
  WidgetTester tester,
  ClassroomRepository repository,
) async => (await tester.runAsync(() async {
  final room = RealtimeRoom(
    media: MediaRoomSession.direct(
      roomCode: 'classroom-1',
      participantId: repository is _RaisedHandRepository
          ? repository.selfUserId
          : 'self',
      session: _MediaSession(),
    ),
    renderer: const _Renderer(),
    featurePlugins: [
      ClassroomPreset(
        enableForDirectRooms: true,
        repositoryFactory: (_) => repository,
        pollInterval: const Duration(hours: 1),
      ),
    ],
    disposeClients: () {},
  );
  await room.initialize();
  return room;
}))!;

class _ClassAuthority {
  bool raised = false, canSpeak = false;
  int revision = 0;
}

class _ClassClient implements ClassroomRepository {
  _ClassClient(this.authority, this.teacher);
  final _ClassAuthority authority;
  final bool teacher;
  @override
  Future<ClassroomState> snapshot() async => ClassroomState(
    roomCode: 'class',
    role: teacher ? ClassroomRole.teacher : ClassroomRole.student,
    selfUserId: teacher ? 'teacher' : 'student',
    revision: authority.revision,
    students: [
      ClassroomStudent(
        userId: 'student',
        participantId: 'student',
        displayName: 'Student',
        online: true,
        handRaised: authority.raised,
        canSpeak: authority.canSpeak,
      ),
    ],
    questions: const [],
    stats: const ClassroomStats(),
  );
  @override
  Future<ClassroomState> action(ClassroomCommand command) async {
    if (command.action == ClassroomAction.handRaise) authority.raised = true;
    if (command.action == ClassroomAction.speakGrant) {
      authority.canSpeak = true;
      authority.raised = false;
    }
    authority.revision++;
    return snapshot();
  }

  @override
  void close() {}
}
