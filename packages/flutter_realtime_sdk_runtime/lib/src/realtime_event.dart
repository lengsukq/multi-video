import 'package:flutter_realtime_chat_core/flutter_realtime_chat_core.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'realtime_room_state.dart';

sealed class RealtimeEvent {
  const RealtimeEvent();
}

class RealtimeStateChanged extends RealtimeEvent {
  const RealtimeStateChanged(this.state);
  final RealtimeRoomState state;
}

class RealtimeMediaEvent extends RealtimeEvent {
  const RealtimeMediaEvent(this.event);
  final MediaEvent event;
}

class RealtimeChatEvent extends RealtimeEvent {
  const RealtimeChatEvent(this.event);
  final ChatEvent event;
}

class RealtimeBackendFailure extends RealtimeEvent {
  const RealtimeBackendFailure(this.error);
  final RealtimeException error;
}

class RealtimeScreenCaptureChanged extends RealtimeEvent {
  const RealtimeScreenCaptureChanged({required this.isCaptured});
  final bool isCaptured;
}
