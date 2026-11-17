import 'package:flutter/material.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import '../flutter_realtime_sdk_ui.dart';

/// Responsive standalone chat page built from the public SDK widgets.
///
/// Header: back, identity, room code and management. Body: search and a flat
/// message stream. Wide screens cap the content at 900 pt; phones use the full
/// width with a compact header.
class RealtimeChatPage extends StatelessWidget {
  const RealtimeChatPage({
    super.key,
    required this.chatRoom,
    this.title = 'Chat',
    this.onBack,
    this.preventScreenCapture,
  });

  final RealtimeChatRoom chatRoom;
  final String title;
  final VoidCallback? onBack;

  /// Optional UI-level override; defaults to `chatRoom.preventScreenCapture`.
  final bool? preventScreenCapture;

  @override
  Widget build(BuildContext context) {
    final strings = RealtimeStrings.of(context);
    final style = RealtimeStyle.of(context);
    final roleLabel = RealtimePresentationRole.forChat(
      chatRoom.session.role,
    ).label(isZh: strings.isZh);
    return ChatUiScope(
      session: chatRoom.session,
      moderation: chatRoom.moderation,
      child: RealtimeScreenCaptureGuard.chat(
        chatRoom: chatRoom,
        enabled: preventScreenCapture,
        onLeaveRequested: onBack,
        child: Scaffold(
          backgroundColor: style.background,
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact =
                    constraints.maxWidth < RealtimeBreakpoints.compactMaxWidth;
                final padding = compact ? 12.0 : 24.0;
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(padding, 12, padding, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: compact ? 8 : 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: style.surface,
                              borderRadius: BorderRadius.circular(
                                RealtimeUiTokens.cardRadius,
                              ),
                              border: Border.all(color: style.border),
                              boxShadow: style.cardShadow,
                            ),
                            child: Row(
                              children: [
                                IconButton(
                                  tooltip: strings.back,
                                  onPressed:
                                      onBack ??
                                      () => Navigator.maybePop(context),
                                  icon: const Icon(Icons.arrow_back_rounded),
                                ),
                                RealtimeAvatar(name: title, size: 40),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        title == 'Chat'
                                            ? (strings.isZh
                                                  ? '独立聊天'
                                                  : 'Standalone Chat')
                                            : title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: -0.2,
                                          color: style.text,
                                        ),
                                      ),
                                      Text(
                                        '${strings.roomCode} · ${chatRoom.roomCode} · $roleLabel',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: style.textMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (!compact) ...[
                                  const ChatConnectionIndicator(),
                                  const SizedBox(width: 8),
                                ],
                                ChatRoomCodeCopy(roomCode: chatRoom.roomCode),
                                const ChatManagementButton(),
                              ],
                            ),
                          ),
                          SizedBox(height: compact ? 10 : 14),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Row(
                              children: [
                                Text(
                                  strings.conversation,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: style.textSecondary,
                                  ),
                                ),
                                const Spacer(),
                                if (compact) const ChatConnectionIndicator(),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(height: 42, child: const ChatSearchField()),
                          const SizedBox(height: 10),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(
                                RealtimeUiTokens.cardRadius,
                              ),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: style.surface,
                                  borderRadius: BorderRadius.circular(
                                    RealtimeUiTokens.cardRadius,
                                  ),
                                  border: Border.all(color: style.border),
                                  boxShadow: style.cardShadow,
                                ),
                                child: const ChatPanel(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
