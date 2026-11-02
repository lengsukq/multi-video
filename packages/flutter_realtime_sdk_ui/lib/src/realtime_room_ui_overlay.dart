import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';

import 'room_ui_controller.dart';

/// Opens a room sheet in the Navigator overlay while preserving the exact
/// [RealtimeRoomUiController] used by the hosting room page.
///
/// A dialog/sheet is mounted under the Navigator, *not* under the room page's
/// inherited scope. Pass the controller captured from a descendant of the
/// room scope, even when [context] belongs to the host page above the scope.
/// The [builder] receives a fresh descendant context which can safely call
/// [RealtimeRoomUiScope.of]. The controller is borrowed, never disposed here.
Future<T?> showRealtimeRoomUiBottomSheet<T>(
  BuildContext context, {
  required RealtimeRoomUiController controller,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
}) {
  return showRealtimeGlassBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    builder: (_) => RealtimeRoomUiScope(
      room: controller.room,
      controller: controller,
      child: Builder(builder: builder),
    ),
  );
}

/// Like [showRealtimeRoomUiBottomSheet], but for Navigator dialog routes.
///
/// Pass a controller owned by the host room scope; never create a second
/// controller just to show a dialog. Dismiss transient routes before disposing
/// their room to avoid rendering a disposed controller.
Future<T?> showRealtimeRoomUiDialog<T>(
  BuildContext context, {
  required RealtimeRoomUiController controller,
  required WidgetBuilder builder,
  bool useRootNavigator = true,
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    barrierDismissible: barrierDismissible,
    builder: (_) => RealtimeRoomUiScope(
      room: controller.room,
      controller: controller,
      child: Builder(builder: builder),
    ),
  );
}
