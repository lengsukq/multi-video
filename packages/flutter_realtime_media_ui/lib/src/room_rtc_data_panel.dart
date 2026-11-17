import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'realtime_strings.dart';
import 'realtime_ui_style.dart';

typedef RtcDataSender =
    Future<void> Function(String message, {MediaSendOptions options});

/// Optional RTC data debug console, intentionally independent from Product IM.
///
/// Owns its input, send-in-flight guard and cleanup; errors are projected
/// to the surrounding room rather than becoming unhandled Future failures.
class RoomRtcDataPanel extends StatefulWidget {
  const RoomRtcDataPanel({
    super.key,
    required MediaSession this.session,
    required this.onError,
  }) : _canSendData = null,
       _sendData = null;

  /// Room-facade friendly constructor avoiding direct `MediaSession` exposure.
  const RoomRtcDataPanel.sender({
    super.key,
    required bool this._canSendData,
    required RtcDataSender this._sendData,
    required this.onError,
  }) : session = null;

  final MediaSession? session;
  final bool? _canSendData;
  final RtcDataSender? _sendData;
  final ValueChanged<String?> onError;

  bool get canSendData => _canSendData ?? session!.capabilities.canSendData;
  Object get _targetToken => session ?? _sendData!;

  @override
  State<RoomRtcDataPanel> createState() => _RoomRtcDataPanelState();
}

class _RoomRtcDataPanelState extends State<RoomRtcDataPanel> {
  final _message = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _message.text.trim();
    if (text.isEmpty || _sending) return;
    final token = widget._targetToken;
    final sender = widget._sendData;
    final session = widget.session;
    setState(() => _sending = true);
    try {
      if (sender != null) {
        await sender(text, options: const MediaSendOptions(topic: 'debug'));
      } else {
        await session!.sendData(
          text,
          options: const MediaSendOptions(topic: 'debug'),
        );
      }
      if (!mounted || token != widget._targetToken) return;
      _message.clear();
      widget.onError(null);
    } catch (error) {
      if (mounted && token == widget._targetToken) {
        widget.onError(error.toString());
      }
    } finally {
      if (mounted && token == widget._targetToken) {
        setState(() => _sending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.canSendData) {
      return const SizedBox.shrink();
    }
    final strings = RealtimeStrings.of(context);
    return RealtimeGlassSurface(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      radius: RealtimeUiTokens.controlRadius,
      opacity: .88,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: RealtimePill(
              label: strings.rtcData,
              foreground: RealtimeUiTokens.text,
              background: RealtimeUiTokens.primarySubtle,
              borderColor: RealtimeUiTokens.primaryBorder,
            ),
          ),
          Expanded(
            child: TextField(
              controller: _message,
              decoration: InputDecoration(
                hintText: strings.debugDataPayload,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
              onSubmitted: (_) => unawaited(_send()),
            ),
          ),
          IconButton(
            onPressed: _sending ? null : () => unawaited(_send()),
            icon: const Icon(Icons.send_rounded, color: RealtimeUiTokens.text),
          ),
        ],
      ),
    );
  }
}
