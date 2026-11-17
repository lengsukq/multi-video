import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

/// Active protection lease acquired by a room or session.
abstract interface class ScreenCaptureProtectionLease {
  /// Latest external screen-recording / mirroring state observed by OS.
  bool get isCaptured;

  /// Broadcast stream emitting external capture state transitions.
  Stream<bool> get changes;

  /// Suspends or resumes OS window secure flag (`FLAG_SECURE`) while local
  /// in-room screen sharing is active.
  Future<void> setSuspendSecureWindow(bool suspend);

  /// Queries the latest external capture state on demand.
  Future<bool> refresh();

  /// Releases this lease; disables native protection once no leases remain.
  Future<void> release();
}

/// Platform-neutral contract for acquiring OS screen-capture protection and
/// observing external recording/mirroring notifications.
abstract interface class ScreenCaptureProtectionService {
  bool get isSupportedPlatform;

  Future<ScreenCaptureProtectionLease> acquire({
    bool suspendSecureWindow = false,
  });
}

/// Default native MethodChannel implementation shared across iOS and Android.
///
/// Desktop (macOS, Windows, Linux) and Web platforms operate as safe no-ops.
final class SystemScreenCaptureProtection
    implements ScreenCaptureProtectionService {
  SystemScreenCaptureProtection({
    MethodChannel? channel,
    bool Function()? isSupportedPlatformResolver,
  }) : _channel =
           channel ??
           const MethodChannel(
             'flutter_realtime_processed_video/screen_capture_protection',
           ),
       _isSupportedPlatformResolver =
           isSupportedPlatformResolver ?? _defaultSupportedPlatform {
    _channel.setMethodCallHandler(_handleCall);
  }

  static final SystemScreenCaptureProtection instance =
      SystemScreenCaptureProtection();

  static bool _defaultSupportedPlatform() =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  final MethodChannel _channel;
  final bool Function() _isSupportedPlatformResolver;
  final Map<int, _ProtectionLeaseImpl> _leases = <int, _ProtectionLeaseImpl>{};
  final StreamController<bool> _changes = StreamController<bool>.broadcast();
  int _nextLeaseId = 0;
  bool _captured = false;
  Future<void> _syncChain = Future<void>.value();

  @override
  bool get isSupportedPlatform => _isSupportedPlatformResolver();

  @override
  Future<ScreenCaptureProtectionLease> acquire({
    bool suspendSecureWindow = false,
  }) async {
    final id = ++_nextLeaseId;
    final lease = _ProtectionLeaseImpl(
      owner: this,
      id: id,
      suspendSecureWindow: suspendSecureWindow,
    );
    _leases[id] = lease;
    await _enqueueSync();
    return lease;
  }

  Future<void> _updateLease(int id, {required bool suspendSecureWindow}) async {
    final lease = _leases[id];
    if (lease == null || lease.suspendSecureWindow == suspendSecureWindow) {
      return;
    }
    lease.suspendSecureWindow = suspendSecureWindow;
    await _enqueueSync();
  }

  Future<void> _releaseLease(int id) async {
    if (_leases.remove(id) == null) return;
    await _enqueueSync();
  }

  Future<bool> _refresh() async {
    if (!isSupportedPlatform || _leases.isEmpty) {
      _updateCaptured(false);
      return false;
    }
    try {
      final result =
          await _channel.invokeMethod<bool>('isExternalScreenCaptured') ??
          false;
      if (_leases.isNotEmpty) {
        _updateCaptured(result);
      }
      return _captured;
    } on MissingPluginException {
      _updateCaptured(false);
      return false;
    } on PlatformException {
      return _captured;
    }
  }

  Future<void> _enqueueSync() {
    return _syncChain = _syncChain.then((_) => _syncNative());
  }

  Future<void> _syncNative() async {
    if (!isSupportedPlatform) {
      _updateCaptured(false);
      return;
    }
    final enabled = _leases.isNotEmpty;
    final suspendSecureWindow = _leases.values.any(
      (lease) => lease.suspendSecureWindow,
    );
    try {
      final result = await _channel.invokeMethod<bool>(
        'setProtectionEnabled',
        <String, Object?>{
          'enabled': enabled,
          'suspendSecureWindow': suspendSecureWindow,
        },
      );
      _updateCaptured(enabled && (result ?? false));
    } on MissingPluginException {
      _updateCaptured(false);
    } on PlatformException {
      if (!enabled) _updateCaptured(false);
    }
  }

  Future<void> _handleCall(MethodCall call) async {
    if (call.method != 'screenCaptureStateChanged') return;
    if (!isSupportedPlatform || _leases.isEmpty) return;
    final args = call.arguments;
    final captured = args is Map ? args['captured'] == true : args == true;
    _updateCaptured(captured);
  }

  void _updateCaptured(bool next) {
    if (_captured == next) return;
    _captured = next;
    if (!_changes.isClosed) {
      _changes.add(next);
    }
  }
}

final class _ProtectionLeaseImpl implements ScreenCaptureProtectionLease {
  _ProtectionLeaseImpl({
    required this.owner,
    required this.id,
    required this.suspendSecureWindow,
  });

  final SystemScreenCaptureProtection owner;
  final int id;
  bool suspendSecureWindow;
  bool _released = false;

  @override
  bool get isCaptured => _released ? false : owner._captured;

  @override
  Stream<bool> get changes => owner._changes.stream.where((_) => !_released);

  @override
  Future<void> setSuspendSecureWindow(bool suspend) {
    if (_released) return Future<void>.value();
    return owner._updateLease(id, suspendSecureWindow: suspend);
  }

  @override
  Future<bool> refresh() {
    if (_released) return Future<bool>.value(false);
    return owner._refresh();
  }

  @override
  Future<void> release() {
    if (_released) return Future<void>.value();
    _released = true;
    return owner._releaseLease(id);
  }
}
