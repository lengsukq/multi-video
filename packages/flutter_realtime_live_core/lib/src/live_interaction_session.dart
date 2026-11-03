import 'dart:async';
import 'dart:math';
import 'package:flutter_realtime_foundation/flutter_realtime_foundation.dart';
import 'live_interaction_repository.dart';
import 'live_revision_transport.dart';
import 'live_interaction_state.dart';
import 'live_gift_event.dart';
import 'live_like_event.dart';

class LiveInteractionSession {
  LiveInteractionSession(
    this.repository, {
    this.pollInterval = const Duration(seconds: 2),
    this.revisionTransport,
  });
  final LiveInteractionRepository repository;
  final Duration pollInterval;
  final LiveRevisionTransport? revisionTransport;
  final _states = StreamController<LiveInteractionState>.broadcast();
  final _events = StreamController<LiveGiftEvent>.broadcast();
  final _likes = StreamController<LiveLikeEvent>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  static final _random = Random.secure();
  LiveInteractionState? _state;
  bool _disposed = false;
  Future<void>? _disposeFuture;
  Duration cleanupTimeout = const Duration(seconds: 10);
  Timer? _timer;
  StreamSubscription<int>? _hints;
  Future<void>? _pending;
  Timer? _automaticRefreshTimer;
  bool _automaticRefreshRequested = false;
  LiveInteractionState? get state => _state;
  Stream<LiveInteractionState> get states => _states.stream;
  Stream<LiveGiftEvent> get events => _events.stream;
  Stream<LiveLikeEvent> get likes => _likes.stream;
  Stream<Object> get errors => _errors.stream;
  String newEventId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(0x100000000)}';
  Future<void> start() async {
    if (_disposed) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'Live interactions disposed',
      );
    }
    _hints ??= revisionTransport?.revisions.listen(
      (revision) {
        if (revision > (_state?.revision ?? -1)) _requestAutomaticRefresh();
      },
      onError: (Object error) {
        if (!_disposed) _errors.add(error);
      },
    );
    _timer ??= Timer.periodic(pollInterval, (_) => _requestAutomaticRefresh());
    await refresh();
  }

  void _requestAutomaticRefresh() {
    if (_disposed) return;
    _automaticRefreshRequested = true;
    _drainAutomaticRefresh();
  }

  void _drainAutomaticRefresh() {
    if (_disposed ||
        !_automaticRefreshRequested ||
        _pending != null ||
        _automaticRefreshTimer != null) {
      return;
    }
    unawaited(
      refresh().catchError((Object error) {
        if (!_disposed) _errors.add(error);
      }),
    );
  }

  /// Explicit reads bypass the automatic cooldown; all reads share one flight.
  Future<void> refresh() {
    if (_disposed) {
      return Future.error(
        const RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'Live interactions disposed',
        ),
      );
    }
    if (_pending != null) return _pending!;
    _automaticRefreshRequested = false;
    _automaticRefreshTimer?.cancel();
    _automaticRefreshTimer = Timer(const Duration(seconds: 1), () {
      _automaticRefreshTimer = null;
      _drainAutomaticRefresh();
    });
    return _pending = _reload().whenComplete(() {
      _pending = null;
      _drainAutomaticRefresh();
    });
  }

  Future<void> _reload() async {
    try {
      _setState(await repository.snapshot());
    } catch (error, stack) {
      Error.throwWithStackTrace(
        normalizeRealtimeException(
          error,
          domain: 'live',
          operation: 'snapshot',
          stackTrace: stack,
        ),
        stack,
      );
    }
  }

  void _setState(LiveInteractionState next) {
    if (_disposed || (_state != null && next.revision < _state!.revision)) {
      return;
    }
    final previous = _state;
    _state = next;
    if (previous != null) {
      for (final event in next.events) {
        if (event.sequence > previous.revision) _events.add(event);
      }
      for (final event in next.likeEvents) {
        if (event.sequence > previous.revision) _likes.add(event);
      }
    }
    _states.add(next);
  }

  Future<void> sendGift(
    String giftId, {
    int quantity = 1,
    String? eventId,
  }) async {
    if (_disposed) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'Live interactions disposed',
      );
    }
    if (quantity < 1 || quantity > 99) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Gift quantity must be between 1 and 99.',
        domain: 'live',
        operation: 'sendGift',
      );
    }
    if (_state == null) await start();
    if (_state?.canSendGift != true) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'The host is offline',
      );
    }
    try {
      _setState(
        await repository.sendGift(
          giftId,
          quantity,
          eventId: eventId ?? newEventId(),
        ),
      );
    } catch (error, stack) {
      Error.throwWithStackTrace(
        normalizeRealtimeException(
          error,
          domain: 'live',
          operation: 'sendGift',
          stackTrace: stack,
        ),
        stack,
      );
    }
    if (_disposed) return;
    try {
      await revisionTransport?.publish(_state!.revision);
    } catch (e) {
      if (!_disposed) _errors.add(e);
    }
  }

  /// Send one authenticated like. Retrying with the same event ID is safe.
  Future<void> sendLike({String? eventId}) async {
    if (_disposed) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'Live interactions disposed',
      );
    }
    if (_state == null) await start();
    try {
      _setState(await repository.sendLike(eventId: eventId ?? newEventId()));
    } catch (error, stack) {
      Error.throwWithStackTrace(
        normalizeRealtimeException(
          error,
          domain: 'live',
          operation: 'sendLike',
          stackTrace: stack,
        ),
        stack,
      );
    }
    if (_disposed) return;
    try {
      await revisionTransport?.publish(_state!.revision);
    } catch (error) {
      if (!_disposed) _errors.add(error);
    }
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run('poll.timer', () async {
      _timer?.cancel();
    });
    await cleanup.run('refresh.timer', () async {
      _automaticRefreshTimer?.cancel();
      _automaticRefreshRequested = false;
    });
    await cleanup.run('revision.subscription', () async {
      await _hints?.cancel();
    });
    await cleanup.run('refresh.pending', () async {
      try {
        await _pending;
      } catch (_) {
        /* The refresh caller receives its failure. */
      }
    });
    await cleanup.run('revision.transport', () async {
      await revisionTransport?.dispose();
    });
    await cleanup.run('repository', () async {
      repository.close();
    });
    await cleanup.run('states', () async {
      await _states.close();
    });
    await cleanup.run('events', () async {
      await _events.close();
    });
    await cleanup.run('likes', () async {
      await _likes.close();
    });
    await cleanup.run('errors', () async {
      await _errors.close();
    });
    cleanup.finish(domain: 'live');
  }
}
