import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';

/// Participant item model for the sidebar list.
class RealtimeMeetingMemberItem {
  const RealtimeMeetingMemberItem({
    required this.id,
    required this.name,
    this.roleTitle,
    this.avatarUrl,
    this.isMuted = true,
    this.isVideoOff = false,
    this.isSpeaking = false,
    this.handRaised = false,
  });

  final String id;
  final String name;
  final String? roleTitle;
  final String? avatarUrl;
  final bool isMuted;
  final bool isVideoOff;
  final bool isSpeaking;
  final bool handRaised;
}

/// Right integrated sidebar with flat, underlined Chat / Participants tabs.
class RealtimeMeetingSidebar extends StatefulWidget {
  const RealtimeMeetingSidebar({
    super.key,
    required this.members,
    this.invitedMembers = const [],
    this.chatWidget,
    this.membersWidget,
    this.initialTab = 0,
    this.showChat = true,
    this.onTabChanged,
    this.onClose,
  });

  final List<RealtimeMeetingMemberItem> members;
  final List<RealtimeMeetingMemberItem> invitedMembers;
  final Widget? chatWidget;
  final Widget? membersWidget;
  final int initialTab;

  /// Hide the chat destination when no chat session is available.
  final bool showChat;
  final ValueChanged<int>? onTabChanged;
  final VoidCallback? onClose;

  @override
  State<RealtimeMeetingSidebar> createState() => _RealtimeMeetingSidebarState();
}

class _RealtimeMeetingSidebarState extends State<RealtimeMeetingSidebar> {
  late int _selectedTab;
  final TextEditingController _searchController = TextEditingController();
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _selectedTab = widget.showChat ? widget.initialTab : 1;
  }

  Widget _buildTab(
    BuildContext context,
    int index,
    String label, {
    int? badge,
  }) {
    final style = RealtimeStyle.of(context);
    final selected = _selectedTab == index;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: () {
          setState(() => _selectedTab = index);
          widget.onTabChanged?.call(index);
        },
        child: AnimatedContainer(
          duration: RealtimeUiTokens.animFast,
          height: 51,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? style.text : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? style.text : style.textMuted,
                ),
              ),
              if (badge != null && badge > 0) ...[
                const SizedBox(width: 6),
                RealtimeBadge(
                  text: '$badge',
                  fontSize: 10,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant RealtimeMeetingSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialTab != oldWidget.initialTab) {
      _selectedTab = widget.showChat ? widget.initialTab : 1;
    } else if (!widget.showChat) {
      _selectedTab = 1;
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    final strings = RealtimeStrings.of(context);

    return ColoredBox(
      color: style.surface,
      child: Column(
        children: [
          Container(
            height: 52,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: style.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        if (widget.showChat)
                          _buildTab(context, 0, strings.chat),
                        _buildTab(
                          context,
                          1,
                          strings.participants,
                          badge: widget.members.length,
                        ),
                      ],
                    ),
                  ),
                ),
                if (widget.onClose != null) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Close Sidebar',
                    onPressed: widget.onClose,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                  const SizedBox(width: 4),
                ],
              ],
            ),
          ),
          Expanded(
            child: widget.showChat && _selectedTab == 0
                ? (widget.chatWidget ?? const Center(child: Text('Chat Feed')))
                : widget.membersWidget ?? _buildParticipantsView(context),
          ),
        ],
      ),
    );
  }

  Widget _buildParticipantsView(BuildContext context) {
    final style = RealtimeStyle.of(context);
    final strings = RealtimeStrings.of(context);

    final raised = widget.members
        .where((m) => m.handRaised)
        .where((m) => m.name.toLowerCase().contains(_filter.toLowerCase()))
        .toList();
    final active = widget.members
        .where((m) => !m.handRaised)
        .where((m) => m.name.toLowerCase().contains(_filter.toLowerCase()))
        .toList();
    final invited = widget.invitedMembers
        .where((m) => m.name.toLowerCase().contains(_filter.toLowerCase()))
        .toList();

    Widget handleRow(RealtimeMeetingMemberItem member) => Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: style.surfaceSubtle,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          RealtimeAvatar(
            name: member.name,
            avatarUrl: member.avatarUrl,
            size: 30,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              member.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: style.text,
              ),
            ),
          ),
          Icon(Icons.pan_tool_rounded, size: 16, color: style.onAccent),
        ],
      ),
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Container(
            height: 38,
            decoration: BoxDecoration(
              color: style.surfaceSubtle,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: style.border),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Icon(Icons.search_rounded, size: 18, color: style.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: (val) => setState(() => _filter = val),
                    style: TextStyle(fontSize: 13, color: style.text),
                    decoration: InputDecoration(
                      hintText: strings.searchMembers,
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: style.textMuted,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            children: [
              if (raised.isNotEmpty) ...[
                RealtimeSectionHeader(
                  title: strings.isZh
                      ? '举手（${raised.length}）'
                      : 'Raised hands (${raised.length})',
                ),
                ...raised.map(handleRow),
              ],
              RealtimeSectionHeader(
                title: strings.isZh
                    ? '在会中（${active.length}）'
                    : 'In meeting (${active.length})',
              ),
              ...active.map((m) => _buildMemberTile(m, isInvited: false)),
              if (invited.isNotEmpty) ...[
                const SizedBox(height: 16),
                RealtimeSectionHeader(
                  title: strings.isZh
                      ? '已邀请（${invited.length}）'
                      : 'Invited (${invited.length})',
                ),
                ...invited.map((m) => _buildMemberTile(m, isInvited: true)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMemberTile(
    RealtimeMeetingMemberItem member, {
    required bool isInvited,
  }) {
    final style = RealtimeStyle.of(context);
    final strings = RealtimeStrings.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          RealtimeAvatar(
            name: member.name,
            avatarUrl: member.avatarUrl,
            size: 32,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  member.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: style.text,
                  ),
                ),
                if (member.roleTitle != null)
                  Text(
                    member.roleTitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: style.textMuted),
                  )
                else if (member.isSpeaking)
                  Text(
                    strings.speaking,
                    style: TextStyle(fontSize: 11, color: style.speakStrong),
                  ),
              ],
            ),
          ),
          if (!isInvited) ...[
            Icon(
              member.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
              size: 15,
              color: member.isMuted ? style.textMuted : style.speak,
            ),
            const SizedBox(width: 6),
            Icon(
              member.isVideoOff
                  ? Icons.videocam_off_outlined
                  : Icons.videocam_outlined,
              size: 15,
              color: member.isVideoOff ? style.textMuted : style.speak,
            ),
          ],
        ],
      ),
    );
  }
}
