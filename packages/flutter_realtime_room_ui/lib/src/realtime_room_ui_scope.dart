import 'package:flutter/widgets.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_chat_ui/flutter_realtime_chat_ui.dart';
import 'realtime_room_ui_controller.dart';

/// Exposes one room UI controller to arbitrarily composed descendant widgets.
///
/// Multiple room layouts can use the same controller. Supply [controller] to
/// retain presentation state across layout changes, or let the scope own it.
class RealtimeRoomUiScope extends StatefulWidget {
  const RealtimeRoomUiScope({
    super.key,
    required this.room,
    required this.child,
    this.controller,
    this.controllerFactory,
    this.onActionError,
  });

  final RealtimeRoom room;
  final Widget child;
  final RealtimeRoomUiController? controller;
  final RealtimeRoomUiController Function(RealtimeRoom room)? controllerFactory;
  final void Function(RealtimeException error)? onActionError;

  static RealtimeRoomUiController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_RealtimeRoomUiInherited>();
    assert(scope != null, 'RealtimeRoomUiScope is required above this widget');
    return scope!.controller;
  }

  static RealtimeRoomUiController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_RealtimeRoomUiInherited>()
        ?.controller;
  }

  @override
  State<RealtimeRoomUiScope> createState() => _RealtimeRoomUiScopeState();
}

class _RealtimeRoomUiScopeState extends State<RealtimeRoomUiScope> {
  late RealtimeRoomUiController _controller;
  bool _ownsController = false;

  // During a room/controller swap Flutter updates the inherited descendants
  // later in the same frame. Disposing the previous ChangeNotifier here would
  // leave those descendants temporarily subscribed to a dead notifier (and a
  // newly-mounted ListenableBuilder throws "used after being disposed").
  // Release owned controllers only after descendants have detached.
  void _releaseAfterFrame(RealtimeRoomUiController controller) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.dispose();
    });
  }

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  void _initialize() {
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ??
        widget.controllerFactory?.call(widget.room) ??
        RealtimeRoomUiController(
          widget.room,
          onActionError: widget.onActionError,
        );
    assert(identical(_controller.room, widget.room));
  }

  @override
  void didUpdateWidget(covariant RealtimeRoomUiScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.room, widget.room) ||
        !identical(oldWidget.controller, widget.controller)) {
      final previous = _controller;
      final previouslyOwned = _ownsController;
      _initialize();
      // It is legal for a host to take over ownership of the same controller
      // on update. In that case the new externally-owned scope still uses it.
      if (previouslyOwned && !identical(previous, _controller)) {
        _releaseAfterFrame(previous);
      }
    }
  }

  @override
  void dispose() {
    if (_ownsController) _releaseAfterFrame(_controller);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = _RealtimeRoomUiInherited(
      controller: _controller,
      child: widget.child,
    );
    final chat = _controller.chatUiController;
    return chat == null
        ? content
        : ChatUiScope(
            session: chat.session,
            moderation: chat.moderation,
            controller: chat,
            child: content,
          );
  }
}

class _RealtimeRoomUiInherited extends InheritedWidget {
  const _RealtimeRoomUiInherited({
    required this.controller,
    required super.child,
  });

  final RealtimeRoomUiController controller;

  @override
  bool updateShouldNotify(_RealtimeRoomUiInherited oldWidget) =>
      !identical(controller, oldWidget.controller);
}
