import 'package:material_ui/material_ui.dart';

import '../../brand.dart';
import '../../chat/chat.dart';
import '../common/brand_mark.dart';
import '../common/popover.dart';
import '../drawer/chat_drawer.dart'
    show accountAvatar, accountInitials, showAccountMenu;
import '../theme/tokens.dart';
import 'header_pill.dart' show ComposeGlyph;

/// The folded desktop sidebar (wide layouts): a 52 dp icon rail. From the
/// top: the brand mark (shows the sidebar icon on hover and opens the
/// sidebar), New chat, Search, Pinned and Chats (each lists its chats in a
/// menu beside the rail), Tasks; the avatar sits at the bottom.
class SidebarRail extends StatelessWidget {
  const SidebarRail({
    super.key,
    required this.conversations,
    required this.historyAvailable,
    required this.serverHost,
    required this.onExpand,
    required this.onNewChat,
    required this.onSearch,
    required this.onSelect,
    required this.onSettings,
    this.onTasks,
    this.tasksIcon,
    this.tasksLabel = 'Tasks',
    this.expandFocus,
  });

  static const double width = 52;
  static const double button = 40;
  static const double icon = 20;

  final ConversationsController conversations;
  final bool historyAvailable;
  final String serverHost;
  final VoidCallback onExpand;
  final VoidCallback onNewChat;
  final VoidCallback onSearch;
  final ValueChanged<String> onSelect;
  final VoidCallback onSettings;

  /// Null hides Tasks (live mode).
  final VoidCallback? onTasks;
  final Widget? tasksIcon;
  final String tasksLabel;
  final FocusNode? expandFocus;

  Future<void> _list(
    BuildContext anchor, {
    required String title,
    required List<Conversation> chats,
    required String empty,
  }) async {
    final t = HermesTokens.of(anchor);
    final id = await showPopover<String>(
      anchor: anchor,
      width: 260,
      above: false,
      gap: 12,
      label: title,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Text(title, style: t.section),
          ),
          if (chats.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
              child: Text(empty, style: t.label),
            ),
          for (final c in chats.take(12))
            PopoverItem(
              label: c.title,
              height: 36,
              checked: c.id == conversations.currentId,
              onTap: () => Navigator.pop(context, c.id),
            ),
        ],
      ),
    );
    if (id != null) onSelect(id);
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    Widget item({
      Key? key,
      required String tooltip,
      required Widget glyph,
      required void Function(BuildContext anchor) onPressed,
      FocusNode? focusNode,
    }) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Builder(
        builder: (anchor) => IconButton(
          key: key,
          focusNode: focusNode,
          tooltip: tooltip,
          onPressed: () => onPressed(anchor),
          style: IconButton.styleFrom(
            fixedSize: const Size.square(button),
            minimumSize: const Size.square(button),
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Rad.row),
            ),
          ),
          icon: glyph,
        ),
      ),
    );
    Icon ic(IconData d) => Icon(d, size: icon, color: t.text);
    return Material(
      color: t.bgRaised,
      child: FocusTraversalGroup(
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          label: 'Sidebar, folded',
          child: SizedBox(
            width: width,
            child: ListenableBuilder(
              listenable: conversations,
              builder: (context, _) => Column(
                children: [
                  SizedBox(height: MediaQuery.paddingOf(context).top + 8),
                  _ExpandMark(focusNode: expandFocus, onPressed: onExpand),
                  const SizedBox(height: 14),
                  item(
                    key: const ValueKey('rail-new-chat'),
                    tooltip: 'New chat',
                    glyph: ComposeGlyph(color: t.text, size: icon),
                    onPressed: (_) => onNewChat(),
                  ),
                  if (historyAvailable) ...[
                    item(
                      key: const ValueKey('rail-search'),
                      tooltip: 'Search chats',
                      glyph: ic(Icons.search_rounded),
                      onPressed: (_) => onSearch(),
                    ),
                    item(
                      key: const ValueKey('rail-pinned'),
                      tooltip: 'Pinned',
                      glyph: ic(Icons.push_pin_outlined),
                      onPressed: (a) => _list(
                        a,
                        title: 'Pinned',
                        chats: conversations.pinned,
                        empty: 'Pin a chat to keep it here',
                      ),
                    ),
                    item(
                      key: const ValueKey('rail-chats'),
                      tooltip: 'Chats',
                      glyph: ic(Icons.chat_bubble_outline_rounded),
                      onPressed: (a) => _list(
                        a,
                        title: 'Chats',
                        chats: conversations.recent,
                        empty: 'No chats yet',
                      ),
                    ),
                  ],
                  if (onTasks != null)
                    item(
                      key: const ValueKey('rail-tasks'),
                      tooltip: tasksLabel,
                      glyph: tasksIcon ?? ic(Icons.checklist_rounded),
                      onPressed: (_) => onTasks!(),
                    ),
                  const Spacer(),
                  Builder(
                    builder: (anchor) => Padding(
                      padding: EdgeInsets.only(
                        bottom: 10 + MediaQuery.paddingOf(context).bottom,
                      ),
                      child: Tooltip(
                        message: 'Menu',
                        child: Semantics(
                          button: true,
                          label: 'Account and settings menu',
                          hint: 'Connected to $serverHost',
                          excludeSemantics: true,
                          onTap: () => showAccountMenu(
                            anchor,
                            serverHost: serverHost,
                            onSettings: onSettings,
                          ),
                          child: InkResponse(
                            key: const ValueKey('rail-avatar'),
                            radius: 20,
                            onTap: () => showAccountMenu(
                              anchor,
                              serverHost: serverHost,
                              onSettings: onSettings,
                            ),
                            child: SizedBox.square(
                              dimension: button,
                              child: Center(
                                child: Transform.scale(
                                  scale: 0.7,
                                  child: accountAvatar(
                                    t,
                                    accountInitials(serverHost),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The rail's top button: the brand mark, which turns into the sidebar icon
/// while hovered or focused; it opens the sidebar.
class _ExpandMark extends StatefulWidget {
  const _ExpandMark({required this.onPressed, this.focusNode});
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  State<_ExpandMark> createState() => _ExpandMarkState();
}

class _ExpandMarkState extends State<_ExpandMark> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (v) => setState(() => _hover = v),
      child: IconButton(
        key: const ValueKey('sidebar-expand'),
        focusNode: widget.focusNode,
        tooltip: 'Open sidebar',
        onPressed: widget.onPressed,
        onHover: (v) => setState(() => _hover = v),
        style: IconButton.styleFrom(
          fixedSize: const Size.square(SidebarRail.button),
          minimumSize: const Size.square(SidebarRail.button),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Rad.row),
          ),
        ),
        icon: _hover
            ? Icon(
                Icons.view_sidebar_outlined,
                size: SidebarRail.icon,
                color: t.text,
              )
            : Semantics(label: Brand.appName, child: const BrandMark(size: 24)),
      ),
    );
  }
}
