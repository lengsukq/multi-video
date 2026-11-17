import 'package:flutter/material.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';

import 'realtime_room_view_config.dart';
import 'realtime_meeting_page.dart';
import 'realtime_live_page.dart';

/// Ready-to-use SDK UI, also used by the repository Demo.
///
/// Backend room mode is authoritative. Applications can still compose the
/// individual public widgets when they need a different presentation.
class RealtimeRoomView extends StatelessWidget {
  const RealtimeRoomView({
    super.key,
    required this.room,
    this.config = const RealtimeRoomViewConfig(),
    this.header,
    this.participantBuilder,
    this.onLeave,
    this.showClassroom = true,
    this.showLiveInteractions = true,
    this.showAnnotations = true,
    this.loadImagePresets,
    this.onCustomReaction,
    this.stageOverlayBuilder,
  });

  final RealtimeRoom room;
  final RealtimeRoomViewConfig config;
  final Widget? header;
  final MediaParticipantBuilder? participantBuilder;
  final VoidCallback? onLeave;
  final bool showClassroom;
  final bool showLiveInteractions;
  final bool showAnnotations;
  final Future<List<MediaBackgroundImagePreset>> Function()? loadImagePresets;
  final Future<void> Function(BuildContext context)? onCustomReaction;
  final WidgetBuilder? stageOverlayBuilder;

  static bool isLiveSession(RealtimeRoom room, {MediaRoomMode? fallbackMode}) {
    final mode = room.media.backendMetadata['roomMode'];
    if (mode == MediaRoomMode.broadcast.wireName) return true;
    if (mode == MediaRoomMode.meeting.wireName) return false;
    if (room.media.role == MediaRole.viewer) return true;
    if (room.media.role == MediaRole.participant) return false;
    return fallbackMode == MediaRoomMode.broadcast;
  }

  List<MediaBackgroundImagePreset> get _imagePresets => [
    ...config.backgroundImagePresets,
    if (config.backgroundImageBytes case final bytes?)
      MediaBackgroundImagePreset(
        id: 'host-background',
        label: 'Background',
        imageBytes: bytes,
      ),
  ];

  @override
  Widget build(BuildContext context) {
    if (isLiveSession(room, fallbackMode: config.roomMode)) {
      return RealtimeLivePage(
        room: room,
        initialSettings: config.initialMediaSettings,
        imagePresets: _imagePresets,
        loadImagePresets: loadImagePresets,
        onLeft: onLeave,
        confirmBeforeLeave: config.confirmBeforeLeave,
        preventScreenCapture: config.preventScreenCapture,
        header: header,
        showChat: config.showChat,
        showProvider: config.showProvider,
        showLiveInteractions: showLiveInteractions,
      );
    }
    return RealtimeMeetingPage(
      room: room,
      initialSettings: config.initialMediaSettings,
      imagePresets: _imagePresets,
      loadImagePresets: loadImagePresets,
      onLeft: onLeave,
      confirmBeforeLeave: config.confirmBeforeLeave,
      preventScreenCapture: config.preventScreenCapture,
      header: header,
      participantBuilder: participantBuilder,
      showChat: config.showChat,
      showProvider: config.showProvider,
      showRtcDataMessages: config.showRtcDataMessages,
      showClassroom: showClassroom,
      showAnnotations: showAnnotations,
      onCustomReaction: onCustomReaction,
      stageOverlayBuilder: stageOverlayBuilder,
      initialSharedContentMode: config.initialSharedContentMode,
      sessionInfo: config.sessionInfo,
      brand: config.brand,
      pinnedMessage: config.pinnedMessage,
    );
  }
}
