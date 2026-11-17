import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';

/// Observes [RealtimeRoom.isScreenCaptured] or [RealtimeChatRoom.isScreenCaptured]
/// and presents a blocking alert prompting the participant to stop external OS
/// screen recording or mirroring.
///
/// Automatically respects `preventScreenCapture` configured on the SDK unless
/// explicitly overridden via [enabled], exempts local in-room screen sharing,
/// occludes underlying native platform video views while active, and dismisses
/// itself immediately once external capture stops or the session terminates.
class RealtimeScreenCaptureGuard extends StatefulWidget {
  const RealtimeScreenCaptureGuard({
    super.key,
    required RealtimeRoom this.room,
    required this.child,
    this.enabled,
    this.onLeaveRequested,
  }) : chatRoom = null;

  const RealtimeScreenCaptureGuard.chat({
    super.key,
    required RealtimeChatRoom this.chatRoom,
    required this.child,
    this.enabled,
    this.onLeaveRequested,
  }) : room = null;

  final RealtimeRoom? room;
  final RealtimeChatRoom? chatRoom;
  final Widget child;

  /// Optional UI-level override. When `null`, inherits `preventScreenCapture`
  /// configured on the SDK room or chat room.
  final bool? enabled;

  /// Optional exit callback invoked after leaving/disposing the room when the
  /// user chooses to leave from the blocking alert.
  final VoidCallback? onLeaveRequested;

  @override
  State<RealtimeScreenCaptureGuard> createState() =>
      _RealtimeScreenCaptureGuardState();
}

class _RealtimeScreenCaptureGuardState extends State<RealtimeScreenCaptureGuard>
    with WidgetsBindingObserver {
  StreamSubscription<bool>? _captureSubscription;
  StreamSubscription<Object?>? _sessionStateSubscription;
  bool _leaving = false;

  bool get _defaultEnabled =>
      widget.room?.preventScreenCapture ??
      widget.chatRoom?.preventScreenCapture ??
      false;

  bool get _effectiveEnabled => widget.enabled ?? _defaultEnabled;

  bool get _isSessionActive {
    final mediaRoom = widget.room;
    if (mediaRoom != null) {
      return !mediaRoom.isDisposed && !mediaRoom.snapshot.state.isTerminal;
    }
    final chat = widget.chatRoom;
    if (chat != null) {
      final state = chat.session.state;
      return !chat.isDisposed &&
          state != ChatConnectionState.failed &&
          state != ChatConnectionState.disposed;
    }
    return false;
  }

  bool get _isCaptured =>
      widget.room?.isScreenCaptured ??
      widget.chatRoom?.isScreenCaptured ??
      false;

  bool get _isBlocking => _effectiveEnabled && _isSessionActive && _isCaptured;

  Future<void> _refreshCaptureState() async {
    if (widget.room != null) {
      await widget.room!.refreshScreenCaptureState();
    } else if (widget.chatRoom != null) {
      await widget.chatRoom!.refreshScreenCaptureState();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bindTarget();
  }

  @override
  void didUpdateWidget(covariant RealtimeScreenCaptureGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.room, widget.room) ||
        !identical(oldWidget.chatRoom, widget.chatRoom)) {
      _unbindTarget();
      _leaving = false;
      _bindTarget();
    } else if (oldWidget.enabled != widget.enabled && _effectiveEnabled) {
      unawaited(_refreshCaptureState());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _effectiveEnabled) {
      unawaited(_refreshCaptureState());
    }
  }

  void _bindTarget() {
    final mediaRoom = widget.room;
    final chat = widget.chatRoom;
    if (mediaRoom != null) {
      _captureSubscription = mediaRoom.screenCaptureChanges.listen((_) {
        if (mounted) setState(() {});
      });
      _sessionStateSubscription = mediaRoom.snapshots.listen((_) {
        if (mounted) setState(() {});
      });
    } else if (chat != null) {
      _captureSubscription = chat.screenCaptureChanges.listen((_) {
        if (mounted) setState(() {});
      });
      _sessionStateSubscription = chat.session.states.listen((_) {
        if (mounted) setState(() {});
      });
    }
    if (_effectiveEnabled) {
      unawaited(_refreshCaptureState());
    }
  }

  void _unbindTarget() {
    unawaited(_captureSubscription?.cancel());
    unawaited(_sessionStateSubscription?.cancel());
    _captureSubscription = null;
    _sessionStateSubscription = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unbindTarget();
    super.dispose();
  }

  Future<void> _handleLeave() async {
    if (_leaving || !mounted) return;
    setState(() => _leaving = true);
    try {
      if (widget.room != null) {
        await widget.room!.leaveRoom();
      } else if (widget.chatRoom != null) {
        await widget.chatRoom!.dispose();
      }
      if (!mounted) return;
      if (widget.onLeaveRequested != null) {
        widget.onLeaveRequested!();
      } else if (Navigator.canPop(context)) {
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) setState(() => _leaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocking = _isBlocking;
    final parentOccluded = MediaPlatformViewOcclusion.of(context);
    final strings = RealtimeStrings.of(context);
    final style = RealtimeStyle.of(context);

    final content = MediaPlatformViewOcclusion(
      occluded: parentOccluded || blocking,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (blocking) ...[
            ModalBarrier(
              key: const ValueKey('realtime-screen-capture-barrier'),
              dismissible: false,
              color: Colors.black.withValues(alpha: 0.62),
            ),
            Center(
              child: RealtimeGlassDialog(
                key: const ValueKey('realtime-screen-capture-alert'),
                icon: Icons.stop_screen_share_rounded,
                iconColor: style.danger,
                iconBackground: style.dangerSubtle,
                title: Text(strings.screenCaptureDetectedTitle),
                content: Text(
                  strings.screenCaptureDetectedMessage,
                  style: TextStyle(
                    color: style.textSecondary,
                    fontSize: 14.5,
                    height: 1.45,
                  ),
                ),
                actions: [
                  TextButton(
                    key: const ValueKey('realtime-screen-capture-leave'),
                    onPressed: _leaving ? null : () => unawaited(_handleLeave()),
                    child: Text(strings.leave),
                  ),
                  FilledButton(
                    key: const ValueKey('realtime-screen-capture-recheck'),
                    onPressed: _leaving
                        ? null
                        : () => unawaited(_refreshCaptureState()),
                    child: Text(strings.recheckScreenCapture),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );

    if (!blocking) return content;
    return PopScope<void>(canPop: false, child: content);
  }
}
