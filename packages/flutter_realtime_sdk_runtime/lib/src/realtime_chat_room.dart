import 'dart:async';

import 'package:flutter_realtime_chat_core/flutter_realtime_chat_core.dart';
import 'package:flutter_realtime_processed_video/flutter_realtime_processed_video.dart'
    show
        ScreenCaptureProtectionLease,
        ScreenCaptureProtectionService,
        SystemScreenCaptureProtection;

import 'realtime_moderation.dart';

// ignore_for_file: prefer_initializing_formals

/// High-level owner for a standalone product-chat room.
class RealtimeChatRoom {
  RealtimeChatRoom({
    required this.room,
    required void Function() disposeClient,
    this.preventScreenCapture = false,
    ScreenCaptureProtectionService? screenCaptureProtection,
  }) : _disposeClient = disposeClient,
       _screenCaptureProtection = preventScreenCapture
           ? (screenCaptureProtection ?? SystemScreenCaptureProtection.instance)
           : null {
    _stateSubscription = room.session.states.listen(_onChatState);
    if (_screenCaptureProtection != null) {
      unawaited(_startScreenProtection());
    }
  }

  final ChatRoomSession room;
  final void Function() _disposeClient;

  /// Whether SDK screen-capture protection & external recording alerts are
  /// enabled for this standalone chat room.
  final bool preventScreenCapture;
  final ScreenCaptureProtectionService? _screenCaptureProtection;

  final StreamController<bool> _screenCaptureController =
      StreamController<bool>.broadcast();
  StreamSubscription<ChatConnectionState>? _stateSubscription;
  ScreenCaptureProtectionLease? _screenProtectionLease;
  StreamSubscription<bool>? _screenProtectionSubscription;
  bool _externalScreenCaptured = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;
  Duration cleanupTimeout = const Duration(seconds: 10);

  ChatSession get session => room.session;
  String get roomCode => room.roomCode;
  String get providerId => session.providerId;
  bool get isDisposed => _disposed;
  RealtimeChatModeration get moderation =>
      RealtimeChatModeration(session, room.moderation);

  /// Whether external OS screen recording or mirroring is currently active
  /// while [preventScreenCapture] is enabled.
  bool get isScreenCaptured => _externalScreenCaptured;

  /// Emits transitions of [isScreenCaptured].
  Stream<bool> get screenCaptureChanges => _screenCaptureController.stream;

  /// Re-evaluates OS screen-capture state on demand.
  Future<bool> refreshScreenCaptureState() async {
    if (_disposed || !preventScreenCapture) return false;
    final lease = _screenProtectionLease;
    if (lease == null) return _externalScreenCaptured;
    await lease.refresh();
    _recomputeExternalCaptureState();
    return _externalScreenCaptured;
  }

  Future<void> _startScreenProtection() async {
    final service = _screenCaptureProtection;
    if (service == null || _disposed || _isTerminalChatState(session.state)) {
      return;
    }
    final lease = await service.acquire();
    if (_disposed || _isTerminalChatState(session.state)) {
      await lease.release();
      return;
    }
    _screenProtectionLease = lease;
    _screenProtectionSubscription = lease.changes.listen((_) {
      _recomputeExternalCaptureState();
    });
    _recomputeExternalCaptureState();
  }

  void _onChatState(ChatConnectionState state) {
    if (_isTerminalChatState(state)) {
      unawaited(_releaseScreenProtection());
    }
  }

  bool _isTerminalChatState(ChatConnectionState state) =>
      state == ChatConnectionState.failed ||
      state == ChatConnectionState.disposed;

  void _recomputeExternalCaptureState() {
    final lease = _screenProtectionLease;
    final next =
        !_disposed &&
        preventScreenCapture &&
        !_isTerminalChatState(session.state) &&
        (lease?.isCaptured ?? false);
    if (_externalScreenCaptured == next) return;
    _externalScreenCaptured = next;
    if (!_screenCaptureController.isClosed) {
      _screenCaptureController.add(next);
    }
  }

  Future<void> _releaseScreenProtection() async {
    final sub = _screenProtectionSubscription;
    final lease = _screenProtectionLease;
    _screenProtectionSubscription = null;
    _screenProtectionLease = null;
    _recomputeExternalCaptureState();
    await sub?.cancel();
    await lease?.release();
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    final cleanup = Cleanup(timeout: cleanupTimeout);
    await cleanup.run('screen.protection', _releaseScreenProtection);
    await cleanup.run('chat.states', () async {
      await _stateSubscription?.cancel();
    });
    await cleanup.run('chat.session', () async {
      await room.dispose();
    });
    await cleanup.run('screen.protection.stream', () async {
      await _screenCaptureController.close();
    });
    await cleanup.run('chat.client', () {
      _disposeClient();
    });
    cleanup.finish(domain: 'chat');
  }
}
