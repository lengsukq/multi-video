import 'dart:async';
import 'package:flutter_realtime_foundation/flutter_realtime_foundation.dart';
import 'realtime_feature_context.dart';
import 'realtime_feature_key.dart';
import 'realtime_feature_plugin.dart';
import 'realtime_feature_state.dart';

class _AttachedFeature {
  const _AttachedFeature(this.plugin, this.value);
  final RealtimeFeaturePlugin<Object> plugin;
  final Object value;
}

/// Starts independent features concurrently and releases in dependency order.
class RealtimeFeatureRegistry {
  RealtimeFeatureRegistry(
    Iterable<RealtimeFeaturePlugin<Object>> plugins, {
    this.onError,
    this.cleanupTimeout = const Duration(seconds: 10),
  }) : _plugins = _order(plugins) {
    for (final plugin in _plugins) {
      _states[plugin.id] = const RealtimeFeatureRegistered();
    }
  }
  final List<RealtimeFeaturePlugin<Object>> _plugins;
  final Duration cleanupTimeout;
  final void Function(String featureId, Object error, StackTrace stack)?
  onError;
  final _attached = <String, _AttachedFeature>{};
  final _states = <String, RealtimeFeatureState>{};
  final _changes =
      StreamController<Map<String, RealtimeFeatureState>>.broadcast();
  final _attaches = <String, Future<void>>{};
  final _starts = <String, Future<void>>{};
  final _generations = <String, int>{};
  RealtimeFeatureContext? _context;
  Future<void>? _initialization;
  Future<void>? _disposal;
  bool _startRequested = false;
  bool _disposed = false;

  List<String> get registeredIds =>
      List.unmodifiable(_plugins.map((plugin) => plugin.id));
  List<String> get activeIds => List.unmodifiable(_attached.keys);
  Map<String, RealtimeFeatureState> get states => Map.unmodifiable(_states);
  Stream<Map<String, RealtimeFeatureState>> get changes => _changes.stream;

  RealtimeFeaturePlugin<Object> _plugin(RealtimeFeatureKey<Object> key) {
    for (final plugin in _plugins) {
      if (plugin.id != key.id) continue;
      if (plugin.key.valueType != key.valueType) {
        throw const RealtimeException(
          code: RealtimeErrorCode.invalidArgument,
          message: 'feature.key.type',
        );
      }
      return plugin;
    }
    throw const RealtimeException(
      code: RealtimeErrorCode.invalidArgument,
      message: 'feature.key.unregistered',
    );
  }

  T? get<T extends Object>(RealtimeFeatureKey<T> key) {
    if (!_plugins.any((plugin) => plugin.id == key.id)) return null;
    _plugin(key);
    return _attached[key.id]?.value as T?;
  }

  bool contains(String id) => _attached.containsKey(id);

  void _set(String id, RealtimeFeatureState state) {
    _states[id] = state;
    if (!_disposed) _changes.add(states);
  }

  void _failed(String id, Object error, StackTrace stack) {
    final failure = normalizeRealtimeException(
      error,
      domain: 'feature',
      operation: id,
      stackTrace: stack,
    );
    if (!_disposed) _set(id, RealtimeFeatureFailed(failure));
    onError?.call(id, failure, stack);
  }

  Future<void> initialize(RealtimeFeatureContext context) {
    _ensureOpen();
    _context ??= RealtimeFeatureContext(
      media: context.media,
      chat: context.chat,
      interactions: context.interactions,
      backendUrl: context.backendUrl,
      tokenProvider: context.tokenProvider,
      requestTimeout: context.requestTimeout,
      reportError: context.reportError,
      features: this,
    );
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    for (final plugin in _plugins) {
      if (_disposed) break;
      _attaches[plugin.id] = _attach(plugin);
    }
    await Future.wait(_attaches.values);
  }

  Future<void> _attach(RealtimeFeaturePlugin<Object> plugin) {
    final generation = (_generations[plugin.id] ?? 0) + 1;
    _generations[plugin.id] = generation;
    _set(plugin.id, const RealtimeFeatureAttaching());
    final availableDependencies = [
      ...plugin.requiredFeatures,
      ...plugin.optionalFeatures.where(
        (key) => _plugins.any((candidate) => candidate.id == key.id),
      ),
    ];
    final pending = availableDependencies.where(
      (key) => !_attached.containsKey(key.id),
    );
    if (pending.isEmpty) return _attachNow(plugin, generation);
    return Future.wait(pending.map((key) => _attaches[key.id]!)).then<void>((
      _,
    ) async {
      if (_disposed) return;
      if (plugin.requiredFeatures.any(
        (key) => !_attached.containsKey(key.id),
      )) {
        _set(plugin.id, const RealtimeFeatureUnavailable());
        return;
      }
      await _attachNow(plugin, generation);
    });
  }

  Future<void> _attachNow(
    RealtimeFeaturePlugin<Object> plugin,
    int generation,
  ) {
    try {
      final result = plugin.attach(_context!);
      if (result is Future<Object?>) {
        return result
            .then((value) => _accept(plugin, value, generation))
            .catchError((Object error, StackTrace stack) {
              _failed(plugin.id, error, stack);
            });
      }
      return _accept(plugin, result, generation);
    } catch (error, stack) {
      _failed(plugin.id, error, stack);
      return Future.value();
    }
  }

  Future<void> _accept(
    RealtimeFeaturePlugin<Object> plugin,
    Object? value,
    int generation,
  ) async {
    if (value == null) {
      if (!_disposed) _set(plugin.id, const RealtimeFeatureUnavailable());
      return;
    }
    if (_disposed || _generations[plugin.id] != generation) {
      final cleanup = Cleanup(timeout: cleanupTimeout);
      await cleanup.run(
        'feature.${plugin.id}.late',
        () => plugin.detach(value),
      );
      try {
        cleanup.finish(domain: 'features');
      } catch (error, stack) {
        _failed(plugin.id, error, stack);
      }
      return;
    }
    _attached[plugin.id] = _AttachedFeature(plugin, value);
    _set(plugin.id, const RealtimeFeatureAttached());
    if (_startRequested) await _startOnce(plugin, value);
  }

  Future<void> startAttached() async {
    _ensureOpen();
    _startRequested = true;
    await Future.wait([
      for (final plugin in _plugins)
        if (_attached[plugin.id] case final entry?)
          _startOnce(plugin, entry.value),
    ]);
  }

  Future<void> _startOnce(RealtimeFeaturePlugin<Object> plugin, Object value) =>
      _starts.putIfAbsent(plugin.id, () => _start(plugin, value));
  Future<void> _start(
    RealtimeFeaturePlugin<Object> plugin,
    Object value,
  ) async {
    try {
      _set(plugin.id, const RealtimeFeatureStarting());
      await Future.wait(
        plugin.requiredFeatures.map(
          (key) => _starts[key.id] ?? Future<void>.value(),
        ),
      );
      if (_disposed) return;
      if (plugin.requiredFeatures.any(
        (key) => _states[key.id] is RealtimeFeatureFailed,
      )) {
        throw const RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'feature.dependency.failed',
        );
      }
      await plugin.start(value);
      if (!_disposed) _set(plugin.id, const RealtimeFeatureReady());
    } catch (error, stack) {
      _failed(plugin.id, error, stack);
    }
  }

  Future<void> retry<T extends Object>(RealtimeFeatureKey<T> key) async {
    _ensureOpen();
    final plugin = _plugin(key);
    if (_states[key.id] is! RealtimeFeatureFailed || _context == null) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'feature.retry.state',
      );
    }
    final entry = _attached.remove(key.id);
    if (entry != null) {
      final cleanup = Cleanup(timeout: cleanupTimeout);
      await cleanup.run('feature.${key.id}', () => plugin.detach(entry.value));
      cleanup.finish(domain: 'features');
    }
    final previousStart = _starts.remove(key.id);
    if (previousStart != null) await previousStart;
    final operation = _attach(plugin);
    _attaches[key.id] = operation;
    await operation;
  }

  Future<void> dispose() => _disposal ??= _dispose();
  Future<void> _dispose() async {
    _disposed = true;
    final cleanup = Cleanup(timeout: cleanupTimeout);
    for (final plugin in _plugins.reversed) {
      final entry = _attached.remove(plugin.id);
      if (entry != null) {
        await cleanup.run(
          'feature.${plugin.id}',
          () => plugin.detach(entry.value),
        );
      }
      _set(plugin.id, const RealtimeFeatureDisposed());
    }
    await cleanup.run('feature.changes', _changes.close);
    cleanup.finish(domain: 'features');
  }

  void _ensureOpen() {
    if (_disposed) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'feature.disposed',
      );
    }
  }

  static List<RealtimeFeaturePlugin<Object>> _order(
    Iterable<RealtimeFeaturePlugin<Object>> plugins,
  ) {
    final byId = <String, RealtimeFeaturePlugin<Object>>{};
    for (final plugin in plugins) {
      if (plugin.id.trim().isEmpty || byId.containsKey(plugin.id)) {
        throw ArgumentError('Duplicate/empty feature ID');
      }
      byId[plugin.id] = plugin;
    }
    final ordered = <RealtimeFeaturePlugin<Object>>[];
    final visiting = <String>{};
    final visited = <String>{};
    void visit(RealtimeFeaturePlugin<Object> plugin) {
      if (visited.contains(plugin.id)) return;
      if (!visiting.add(plugin.id)) {
        throw ArgumentError('Feature dependency cycle');
      }
      for (final key in plugin.requiredFeatures) {
        final dependency = byId[key.id];
        if (dependency == null || dependency.key.valueType != key.valueType) {
          throw ArgumentError('Missing/invalid feature dependency');
        }
        visit(dependency);
      }
      for (final key in plugin.optionalFeatures) {
        final dependency = byId[key.id];
        if (dependency == null) continue;
        if (dependency.key.valueType != key.valueType) {
          throw ArgumentError('Invalid optional feature dependency');
        }
        visit(dependency);
      }
      visiting.remove(plugin.id);
      visited.add(plugin.id);
      ordered.add(plugin);
    }

    for (final plugin in byId.values) {
      visit(plugin);
    }
    return List.unmodifiable(ordered);
  }
}
