import 'dart:async';

import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

class _Media implements MediaSession {
  final lifecycle = StreamController<MediaSessionState>.broadcast();
  final notifications = StreamController<MediaEvent>.broadcast();
  @override
  String get providerId => 'test';
  @override
  Stream<MediaSessionState> get states => lifecycle.stream;
  @override
  Stream<MediaEvent> get events => notifications.stream;
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SlowStartingPlugin extends _Plugin {
  _SlowStartingPlugin(super.id, super.log, {required super.gate});
  @override
  Future<void> start(String feature) async {
    log.add('start:$id');
  }
}

class _SyncPlugin extends RealtimeFeaturePlugin<String> {
  _SyncPlugin(this.id, this.log);
  @override
  final String id;
  @override
  RealtimeFeatureKey<String> get key => RealtimeFeatureKey<String>(id);
  final List<String> log;
  @override
  String attach(RealtimeFeatureContext context) {
    log.add('attach:$id:${context.roomCode}');
    return id;
  }

  @override
  void detach(String feature) => log.add('detach:$id');
}

class _Plugin extends RealtimeFeaturePlugin<String> {
  _Plugin(this.id, this.log, {this.failure = false, this.gate});
  @override
  final String id;
  @override
  RealtimeFeatureKey<String> get key => RealtimeFeatureKey<String>(id);
  final List<String> log;
  final bool failure;
  final Completer<void>? gate;
  @override
  Future<String> attach(RealtimeFeatureContext context) async {
    log.add('attach:$id:${context.roomCode}');
    await gate?.future;
    if (failure) throw StateError('broken $id');
    return id;
  }

  @override
  Future<void> detach(String feature) async {
    log.add('detach:$id');
  }
}

class _RecoveringPlugin extends RealtimeFeaturePlugin<String> {
  static const featureKey = RealtimeFeatureKey<String>('recovering');
  @override
  RealtimeFeatureKey<String> get key => featureKey;
  int starts = 0;
  int attachments = 0;
  int releases = 0;
  @override
  String attach(RealtimeFeatureContext context) {
    attachments++;
    return 'feature';
  }

  @override
  void start(String feature) {
    starts++;
    if (starts == 1) throw StateError('initial start failed');
  }

  @override
  void detach(String feature) {
    releases++;
  }
}

class _DependentPlugin extends _SyncPlugin {
  _DependentPlugin(super.id, super.log, this.dependencies);
  final List<RealtimeFeatureKey<Object>> dependencies;
  @override
  List<RealtimeFeatureKey<Object>> get requiredFeatures => dependencies;
}

class _OptionalClassroomPlugin extends _SyncPlugin {
  _OptionalClassroomPlugin(super.id, super.log);
  @override
  List<RealtimeFeatureKey<Object>> get optionalFeatures => const [
    RealtimeFeatureKey<String>('classroom'),
  ];
}

void main() {
  late _Media media;
  late MediaRoomSession room;
  late RealtimeFeatureContext context;
  setUp(() {
    media = _Media();
    room = MediaRoomSession.direct(
      roomCode: 'demo-1',
      participantId: 'user-1',
      session: media,
    );
    context = RealtimeFeatureContext(
      media: room,
      interactions: () => throw StateError('not used'),
    );
  });

  test(
    'a pending slow plugin cannot hide or delay a following sync preset',
    () async {
      final log = <String>[];
      final gate = Completer<void>();
      final registry = RealtimeFeatureRegistry([
        _Plugin('slow', log, gate: gate),
        _SyncPlugin('classroom', log),
      ]);
      final initialization = registry.initialize(context);
      expect(
        registry.get(const RealtimeFeatureKey<String>('classroom')),
        'classroom',
      );
      expect(registry.get(const RealtimeFeatureKey<String>('slow')), isNull);
      await registry.dispose();
      gate.complete();
      await initialization;
      expect(log, [
        'attach:slow:demo-1',
        'attach:classroom:demo-1',
        'detach:classroom',
        'detach:slow',
      ]);
    },
  );

  test(
    'optional classroom dependency attaches first even if declared last',
    () async {
      final log = <String>[];
      final registry = RealtimeFeatureRegistry([
        _OptionalClassroomPlugin('shared-content', log),
        _SyncPlugin('classroom', log),
      ]);
      await registry.initialize(context);
      expect(log.take(2).toList(), [
        'attach:classroom:demo-1',
        'attach:shared-content:demo-1',
      ]);
      await registry.dispose();
      expect(log.skip(2).toList(), [
        'detach:shared-content',
        'detach:classroom',
      ]);
    },
  );

  test(
    'shared content still works with no classroom preset registered',
    () async {
      final log = <String>[];
      final registry = RealtimeFeatureRegistry([
        _OptionalClassroomPlugin('shared-content', log),
      ]);
      await registry.initialize(context);
      expect(registry.contains('shared-content'), isTrue);
      await registry.dispose();
      expect(log, ['attach:shared-content:demo-1', 'detach:shared-content']);
    },
  );

  test(
    'optional classroom finishes asynchronous attach before shared content',
    () async {
      final log = <String>[];
      final gate = Completer<void>();
      final registry = RealtimeFeatureRegistry([
        _OptionalClassroomPlugin('shared-content', log),
        _Plugin('classroom', log, gate: gate),
      ]);
      final attaching = registry.initialize(context);
      expect(registry.contains('shared-content'), isFalse);
      gate.complete();
      await attaching;
      expect(log, ['attach:classroom:demo-1', 'attach:shared-content:demo-1']);
      await registry.dispose();
    },
  );
  test('late async feature starts once after ready sync presets', () async {
    final log = <String>[];
    final gate = Completer<void>();
    final registry = RealtimeFeatureRegistry([
      _SlowStartingPlugin('slow', log, gate: gate),
      _SyncPlugin('classroom', log),
    ]);
    final initialization = registry.initialize(context);
    await registry.startAttached();
    expect(registry.contains('classroom'), isTrue);
    expect(registry.contains('slow'), isFalse);
    gate.complete();
    await initialization;
    await registry.startAttached();
    expect(log.where((entry) => entry == 'start:slow'), hasLength(1));
    await registry.dispose();
  });
  tearDown(() async {
    await room.dispose();
    await media.lifecycle.close();
    await media.notifications.close();
  });

  test(
    'empty plugin set stays unloaded without creating extra sessions',
    () async {
      final registry = RealtimeFeatureRegistry(const []);
      await registry.initialize(context);
      expect(registry.registeredIds, isEmpty);
      expect(registry.activeIds, isEmpty);
      await registry.dispose();
      await registry.dispose();
    },
  );

  test(
    'failed startup is observable and retry releases the old instance',
    () async {
      final plugin = _RecoveringPlugin();
      final registry = RealtimeFeatureRegistry([plugin]);
      await registry.initialize(context);
      await registry.startAttached();
      expect(registry.states['recovering'], isA<RealtimeFeatureFailed>());
      final snapshot = registry.states;
      await registry.retry(_RecoveringPlugin.featureKey);
      expect(registry.states['recovering'], isA<RealtimeFeatureReady>());
      expect(
        snapshot['recovering'],
        isA<RealtimeFeatureFailed>(),
        reason: 'Public state maps are immutable snapshots',
      );
      expect(plugin.attachments, 2);
      expect(plugin.releases, 1);
      await registry.dispose();
      expect(plugin.releases, 2);
    },
  );

  test(
    'missing dependencies and dependency cycles are rejected before attachment',
    () {
      expect(
        () => RealtimeFeatureRegistry([
          _DependentPlugin('a', [], const [
            RealtimeFeatureKey<String>('missing'),
          ]),
        ]),
        throwsArgumentError,
      );
      expect(
        () => RealtimeFeatureRegistry([
          _DependentPlugin('a', [], const [RealtimeFeatureKey<String>('b')]),
          _DependentPlugin('b', [], const [RealtimeFeatureKey<String>('a')]),
        ]),
        throwsArgumentError,
      );
    },
  );

  test(
    'dependencies attach first and dispose after their dependents',
    () async {
      final log = <String>[];
      final registry = RealtimeFeatureRegistry([
        _DependentPlugin('dependent', log, const [
          RealtimeFeatureKey<String>('base'),
        ]),
        _SyncPlugin('base', log),
      ]);
      await registry.initialize(context);
      await registry.startAttached();
      await registry.dispose();
      expect(log, [
        'attach:base:demo-1',
        'attach:dependent:demo-1',
        'detach:dependent',
        'detach:base',
      ]);
    },
  );

  test(
    'attaches explicitly opted-in features and disposes in reverse order',
    () async {
      final log = <String>[];
      final registry = RealtimeFeatureRegistry([
        _Plugin('classroom', log),
        _Plugin('live', log),
      ]);
      await registry.initialize(context);
      expect(
        registry.get(const RealtimeFeatureKey<String>('classroom')),
        'classroom',
      );
      expect(registry.get(const RealtimeFeatureKey<String>('live')), 'live');
      expect(
        () => registry.get(const RealtimeFeatureKey<int>('live')),
        throwsA(isA<RealtimeException>()),
      );
      await registry.dispose();
      expect(log, [
        'attach:classroom:demo-1',
        'attach:live:demo-1',
        'detach:live',
        'detach:classroom',
      ]);
    },
  );

  test('rejects duplicate IDs without starting any feature', () {
    expect(
      () => RealtimeFeatureRegistry([_Plugin('a', []), _Plugin('a', [])]),
      throwsArgumentError,
    );
  });

  test(
    'isolates attach failures and reports them without breaking other features',
    () async {
      final errors = <String>[];
      final registry = RealtimeFeatureRegistry([
        _Plugin('broken', [], failure: true),
        _Plugin('working', []),
      ], onError: (id, error, stack) => errors.add(id));
      await registry.initialize(context);
      expect(errors, ['broken']);
      expect(registry.contains('working'), isTrue);
      expect(registry.contains('broken'), isFalse);
      await registry.dispose();
    },
  );

  test(
    'late attach is released if room registry was disposed meanwhile',
    () async {
      final log = <String>[];
      final gate = Completer<void>();
      final registry = RealtimeFeatureRegistry([
        _Plugin('slow', log, gate: gate),
      ]);
      final initialization = registry.initialize(context);
      await Future<void>.delayed(Duration.zero);
      await registry.dispose();
      gate.complete();
      await initialization;
      expect(registry.activeIds, isEmpty);
      expect(log, ['attach:slow:demo-1', 'detach:slow']);
    },
  );
}
