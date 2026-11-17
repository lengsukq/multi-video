import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';
import 'package:flutter_realtime_shared_content_preset/flutter_realtime_shared_content_preset.dart';

import 'realtime_meeting_session_info.dart';

class RealtimeRoomViewConfig {
  const RealtimeRoomViewConfig({
    this.showProvider = false,
    this.showChat = true,
    this.showRtcDataMessages = false,
    this.confirmBeforeLeave = true,
    this.preventScreenCapture,
    this.initialMediaSettings,
    this.backgroundImageBytes,
    this.backgroundImagePresets = const [],
    this.roomMode,
    this.initialSharedContentMode,
    this.sessionInfo,
    this.brand,
    this.pinnedMessage,
  });
  final bool showProvider;
  final bool showChat;
  final bool showRtcDataMessages;
  final bool confirmBeforeLeave;

  /// Optional UI-level override for screen-capture alert guarding. When `null`,
  /// inherits `room.preventScreenCapture` configured on the SDK.
  final bool? preventScreenCapture;
  final MediaLocalPreviewSettings? initialMediaSettings;
  final Uint8List? backgroundImageBytes;
  final List<MediaBackgroundImagePreset> backgroundImagePresets;

  /// Fallback mode for direct sessions without authoritative backend metadata.
  /// Connected backend mode takes precedence over this hint.
  final MediaRoomMode? roomMode;

  /// Optional shared-content mode requested once the room has connected, for
  /// example when the host entered with "Start with screen share".
  final SharedContentMode? initialSharedContentMode;

  /// Host-provided room identity shown in the meeting header.
  final RealtimeMeetingSessionInfo? sessionInfo;

  /// Product mark shown before the room identity.
  final Widget? brand;

  /// Host-provided pinned message for the side panel chat.
  final String? pinnedMessage;
}
