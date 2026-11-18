import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../chat/chat.dart';
import '../shell/edge_feather.dart';
import '../shell/header_pill.dart' show ComposeGlyph;
import '../../settings/profile.dart';
import '../common/brand_mark.dart';
import '../common/glyphs.dart';
import '../common/group_card.dart';
import '../common/popover.dart';
import '../common/profile_avatar.dart';
import '../feedback.dart';
import '../theme/tokens.dart';
import 'snippet.dart';
import '../../brand.dart';

/// The chat drawer (spec §4.4): a large brand title with a round search
/// button, one list (Pinned on top with bubble glyphs, then Chats; no date
/// groups), and a floating "Chat" pill with the user's avatar over a
/// feathered fade. The avatar opens Settings ([onProfile]; round 8), or the
/// small account menu when there is none.
/// On phones a pull down reloads the chats from the bridge.
///
/// Wide layouts ([onCollapse] set) get the desktop sidebar: the name with
/// search and collapse icons, New chat and Tasks rows, Pinned and Chats in
/// compact 36 dp rows, and an account row at the bottom.
class ChatDrawer extends StatefulWidget {
  const ChatDrawer({
    super.key,
    required this.conversations,
    required this.historyAvailable,
    required this.serverHost,
    required this.onSelect,
    required this.onNewChat,
    required this.onSettings,
    required this.onDelete,
    this.searchRequests,
    this.streaming = const {},
    this.onCollapse,
    this.collapseFocus,
    this.onRefresh,
    this.onTasks,
    this.tasksGlyph,
    this.tasksLabel = 'Tasks',
    this.profile = Profile.empty,
    this.displayName = '',
    this.onProfile,
    this.profileSource,
  });

  final ConversationsController conversations;
  final bool historyAvailable;

  /// For the avatar's initials.
  final String serverHost;
  final ValueChanged<String> onSelect;
  final VoidCallback onNewChat;
  final VoidCallback onSettings;

  /// Confirmed deletion of a chat (the shell resets the thread if needed).
  final ValueChanged<String> onDelete;

  /// Fires when the shell wants the search field focused (Ctrl/Cmd+K).
  final Listenable? searchRequests;

  /// Chats with a reply still being written (a small spinner on the row).
  final Set<String> streaming;

  /// Wide layouts: folds the sidebar into its icon rail. Null hides the
  /// button (the phone drawer).
  final VoidCallback? onCollapse;
  final FocusNode? collapseFocus;

  /// Pull to refresh (phones); defaults to reloading [conversations].
  final Future<void> Function()? onRefresh;

  /// Desktop: the Tasks row (null hides it), its glyph and label.
  final VoidCallback? onTasks;
  final Widget? tasksGlyph;
  final String tasksLabel;

  /// The user's synced profile and name, for the avatar.
  final Profile profile;
  final String displayName;

  /// Opens the Profile page; null falls back to the account menu.
  final VoidCallback? onProfile;

  /// Rebuilds the avatar when the profile changes (the settings).
  final Listenable? profileSource;

  bool get desktop => onCollapse != null;

  @override
  State<ChatDrawer> createState() => ChatDrawerState();
}

class ChatDrawerState extends State<ChatDrawer> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'search chats');
  final _scroll = ScrollController();
  bool _searching = false;
  Timer? _debounce;

  ConversationsController get c => widget.conversations;

  @override
  void initState() {
    super.initState();
    widget.searchRequests?.addListener(openSearch);
  }

  @override
  void dispose() {
    widget.searchRequests?.removeListener(openSearch);
    _debounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void openSearch() {
    if (!widget.historyAvailable) return;
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    _debounce?.cancel();
    _search.clear();
    c.clearSearch();
    setState(() => _searching = false);
  }

  void _onQuery(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => c.search(q));
  }

  Future<void> _rename(Conversation conv) async {
    final ctl = TextEditingController(text: conv.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename chat'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 120,
          decoration: const InputDecoration(hintText: 'Title'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ctl.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (title == null || title.trim().isEmpty) return;
    try {
      await c.rename(conv.id, title.trim());
    } catch (_) {}
  }

  Future<void> _menu(BuildContext anchor, Conversation conv) async {
    FeedbackScope.haptic(anchor, Haptic.medium);
    final choice = await showPopover<String>(
      anchor: anchor,
      width: 200,
      label: 'Chat options',
      above: false,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopoverItem(
            label: 'Rename',
            icon: Icons.edit_outlined,
            onTap: () => Navigator.pop(context, 'rename'),
          ),
          PopoverItem(
            label: conv.pinned ? 'Unpin' : 'Pin',
            icon: Icons.push_pin_outlined,
            onTap: () => Navigator.pop(context, 'pin'),
          ),
          PopoverItem(
            label: 'Delete',
            icon: Icons.delete_outline_rounded,
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'rename':
        await _rename(conv);
      case 'pin':
        try {
          await c.togglePin(conv.id);
        } catch (_) {}
      case 'delete':
        final ok = await confirmDeleteChat(context, conv.title);
        if (ok) widget.onDelete(conv.id);
    }
  }

  Future<void> _refresh() async {
    FeedbackScope.haptic(context, Haptic.light);
    await (widget.onRefresh ?? c.refresh)();
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final desktop = widget.desktop;
    return Material(
      color: t.bgRaised,
      child: ListenableBuilder(
        listenable: Listenable.merge([c, ?widget.profileSource]),
        builder: (context, _) {
          // Phones: the header stays put over the chat screen's top feather
          // and the list scrolls under it (round 6). Desktop: it scrolls.
          Widget listFrom(double inset) {
            Widget list = CustomScrollView(
              key: const ValueKey('drawer-list'),
              controller: _scroll,
              // Always scrollable, so a short list can still be pulled.
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: SizedBox(height: inset)),
                if (desktop) SliverToBoxAdapter(child: _desktopHeader(t)),
                if (desktop && !_searching) ..._desktopNav(t),
                if (_searching) ..._searchSlivers(t) else ..._listSlivers(t),
                SliverToBoxAdapter(
                  child: SizedBox(height: (desktop ? 72 : 96) + bottom),
                ),
              ],
            );
            if (!desktop && widget.historyAvailable && !_searching) {
              list = RefreshIndicator.adaptive(
                key: const ValueKey('drawer-refresh'),
                edgeOffset: inset,
                onRefresh: _refresh,
                child: list,
              );
            }
            return list;
          }

          return Stack(
            children: [
              Positioned.fill(
                child: desktop
                    ? listFrom(top)
                    : FeatheredHeader(
                        color: t.bgRaised,
                        estimate: 72,
                        header: _header(t),
                        body: listFrom,
                      ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: desktop ? _accountRow(t, bottom) : _bottomBar(t, bottom),
              ),
            ],
          );
        },
      ),
    );
  }

  // --- desktop sidebar ------------------------------------------------------

  /// 44 dp: the name (title style) at 14 dp, then 36 dp search and collapse
  /// buttons with 20 dp icons.
  Widget _desktopHeader(HermesTokens t) {
    final searching = _searching && widget.historyAvailable;
    Widget button({
      required Key key,
      required String tooltip,
      required IconData icon,
      required VoidCallback onPressed,
      FocusNode? focusNode,
    }) => IconButton(
      key: key,
      focusNode: focusNode,
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(36),
        minimumSize: const Size.square(36),
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Rad.row),
        ),
      ),
      icon: Icon(icon, size: 20, color: t.text),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(searching ? 8 : 14, 8, 8, 8),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            Expanded(
              child: searching
                  ? _searchField(t)
                  : Semantics(
                      header: true,
                      child: Row(
                        children: [
                          const BrandMark(size: 22),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              Brand.appName,
                              style: t.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            if (widget.historyAvailable)
              button(
                key: const ValueKey('drawer-search'),
                tooltip: searching ? 'Close search' : 'Search chats',
                icon: searching ? Icons.close_rounded : Icons.search_rounded,
                onPressed: searching ? _closeSearch : openSearch,
              ),
            button(
              key: const ValueKey('sidebar-collapse'),
              focusNode: widget.collapseFocus,
              tooltip: 'Collapse sidebar',
              icon: Icons.view_sidebar_outlined,
              onPressed: widget.onCollapse!,
            ),
          ],
        ),
      ),
    );
  }

  /// New chat and Tasks as 36 dp rows under the header.
  List<Widget> _desktopNav(HermesTokens t) => [
    SliverToBoxAdapter(
      child: _navRow(
        t,
        key: const ValueKey('sidebar-new-chat'),
        label: 'Chat',
        semanticsLabel: 'New chat',
        glyph: ComposeGlyph(color: t.text, size: 18),
        onTap: widget.onNewChat,
      ),
    ),
    if (widget.onTasks != null)
      SliverToBoxAdapter(
        child: _navRow(
          t,
          key: const ValueKey('sidebar-tasks'),
          label: widget.tasksLabel,
          glyph:
              widget.tasksGlyph ??
              Icon(Icons.checklist_rounded, size: 18, color: t.text),
          onTap: widget.onTasks!,
        ),
      ),
  ];

  Widget _navRow(
    HermesTokens t, {
    Key? key,
    required String label,
    String? semanticsLabel,
    required Widget glyph,
    required VoidCallback onTap,
  }) => Padding(
    key: key,
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    child: Semantics(
      button: true,
      label: semanticsLabel ?? label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(Rad.row),
          onTap: onTap,
          child: SizedBox(
            height: 36,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  SizedBox.square(dimension: 20, child: Center(child: glyph)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      style: _desktopText(t),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  static TextStyle _desktopText(HermesTokens t) => t.row
      .copyWith(fontSize: 14, height: 20 / 14, color: t.text)
      .hermesWeight(400);

  static const _desktopSection = EdgeInsets.fromLTRB(16, 20, 16, 6);

  void _openProfile(BuildContext anchor) =>
      widget.onProfile != null ? widget.onProfile!() : _accountMenu(anchor);

  String get _name =>
      widget.displayName.isNotEmpty ? widget.displayName : 'Profile';

  /// The account row: avatar, the user's name and the server; opens the
  /// Profile page.
  Widget _accountRow(HermesTokens t, double bottom) => Builder(
    builder: (anchor) => DecoratedBox(
      decoration: BoxDecoration(
        color: t.bgRaised,
        border: Border(top: BorderSide(color: t.hairline)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(6, 6, 6, 6 + bottom),
        child: Semantics(
          button: true,
          label: widget.onProfile != null
              ? '$_name, settings'
              : 'Account and settings menu',
          hint: 'Connected to ${widget.serverHost}',
          excludeSemantics: true,
          onTap: () => _openProfile(anchor),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: const ValueKey('drawer-avatar'),
              borderRadius: BorderRadius.circular(Rad.row),
              onTap: () => _openProfile(anchor),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    ProfileAvatar(
                      profile: widget.profile,
                      name: widget.displayName,
                      size: 30,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _name,
                            style: _desktopText(t),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            widget.serverHost,
                            style: t.label.copyWith(fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _searchField(HermesTokens t) => TextField(
    key: const ValueKey('drawer-search-field'),
    controller: _search,
    focusNode: _searchFocus,
    onChanged: _onQuery,
    textInputAction: TextInputAction.search,
    style: t.row.hermesWeight(400),
    decoration: InputDecoration(
      hintText: 'Search chats',
      isDense: true,
      filled: true,
      fillColor: t.surface,
      prefixIcon: Icon(Icons.search_rounded, size: 20, color: t.textMuted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(999),
        borderSide: BorderSide.none,
      ),
    ),
  );

  /// The header: the app's name, large, and one round search button
  /// (Ctrl/Cmd+K too), which turns the header into the search field; on
  /// wide layouts also the collapse button.
  Widget _header(HermesTokens t) {
    final collapse = widget.onCollapse;
    final searching = _searching && widget.historyAvailable;
    Widget round({
      required Key key,
      required String tooltip,
      required IconData icon,
      required VoidCallback onPressed,
      FocusNode? focusNode,
    }) => IconButton(
      key: key,
      focusNode: focusNode,
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: t.surface,
        fixedSize: const Size.square(44),
        shape: const CircleBorder(),
      ),
      icon: Icon(icon, size: 22, color: t.text),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 72),
      child: Padding(
        padding: EdgeInsets.fromLTRB(searching ? 12 : 20, 10, 12, 10),
        child: Row(
          children: [
            Expanded(
              child: searching
                  ? _searchField(t)
                  : Semantics(
                      header: true,
                      child: Text(
                        Brand.appName,
                        key: const ValueKey('drawer-title'),
                        style: t.display.copyWith(fontSize: 32, height: 1.1),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
            ),
            if (widget.historyAvailable) ...[
              const SizedBox(width: 8),
              round(
                key: const ValueKey('drawer-search'),
                tooltip: searching ? 'Close search' : 'Search chats',
                icon: searching ? Icons.close_rounded : Icons.search_rounded,
                onPressed: searching ? _closeSearch : openSearch,
              ),
            ],
            if (collapse != null) ...[
              const SizedBox(width: 8),
              round(
                key: const ValueKey('sidebar-collapse'),
                focusNode: widget.collapseFocus,
                tooltip: 'Collapse sidebar',
                icon: Icons.view_sidebar_outlined,
                onPressed: collapse,
              ),
            ],
          ],
        ),
      ),
    );
  }

  static const _phoneSection = EdgeInsets.fromLTRB(20, 18, 20, 6);

  List<Widget> _listSlivers(HermesTokens t) {
    if (!widget.historyAvailable) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
            child: Text(
              'This ${Brand.serverName} keeps no chat history yet, so only live '
              'voice and this device’s current thread are available.',
              style: t.label.hermesWeight(400),
            ),
          ),
        ),
      ];
    }
    final pinned = c.pinned;
    final recent = c.recent;
    if (widget.desktop) {
      return [
        if (pinned.isNotEmpty) ...[
          const SliverToBoxAdapter(
            child: SectionHeader('Pinned', padding: _desktopSection),
          ),
          SliverList.builder(
            itemCount: pinned.length,
            itemBuilder: (context, i) => _chatRow(t, pinned[i]),
          ),
        ],
        const SliverToBoxAdapter(
          child: SectionHeader('Chats', padding: _desktopSection),
        ),
        if (recent.isEmpty && pinned.isEmpty && c.loaded)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text('No chats yet', style: t.label),
            ),
          ),
        SliverList.builder(
          itemCount: recent.length,
          itemBuilder: (context, i) => _chatRow(t, recent[i]),
        ),
        ..._listFooter(t),
      ];
    }
    // One list, no date groups: Pinned (with bubble glyphs), then Chats.
    return [
      if (pinned.isNotEmpty) ...[
        const SliverToBoxAdapter(
          child: SectionHeader('Pinned', padding: _phoneSection),
        ),
        SliverList.builder(
          itemCount: pinned.length,
          itemBuilder: (context, i) => _chatRow(t, pinned[i], bubble: true),
        ),
      ],
      if (recent.isNotEmpty || pinned.isEmpty)
        const SliverToBoxAdapter(
          child: SectionHeader('Chats', padding: _phoneSection),
        ),
      if (recent.isEmpty && pinned.isEmpty && c.loaded)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text('No chats yet', style: t.label),
          ),
        ),
      SliverList.builder(
        itemCount: recent.length,
        itemBuilder: (context, i) => _chatRow(t, recent[i]),
      ),
      ..._listFooter(t),
    ];
  }

  /// "See all" and the load error, under either list.
  List<Widget> _listFooter(HermesTokens t) {
    return [
      if (c.hasMore)
        SliverToBoxAdapter(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: TextButton(
                onPressed: c.loading ? null : c.loadMore,
                child: Text(c.loading ? 'Loading…' : 'See all'),
              ),
            ),
          ),
        ),
      if (c.error != null && c.conversations.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Couldn’t load chats.',
                    style: t.label.copyWith(color: t.danger),
                  ),
                ),
                TextButton(onPressed: c.refresh, child: const Text('Retry')),
              ],
            ),
          ),
        ),
    ];
  }

  /// A chat row. Phones: large 56 dp rows across the full width (the open
  /// chat gets a light full-width highlight), pinned ones with a bubble.
  /// Desktop: compact 36 dp rounded rows.
  Widget _chatRow(HermesTokens t, Conversation conv, {bool bubble = false}) {
    final current = conv.id == c.currentId;
    final desktop = widget.desktop;
    final radius = BorderRadius.circular(desktop ? Rad.row : 0);
    return Builder(
      builder: (anchor) => Padding(
        padding: EdgeInsets.symmetric(
          horizontal: desktop ? 6 : 0,
          vertical: desktop ? 1 : 0,
        ),
        child: Semantics(
          selected: current,
          button: true,
          label: [
            conv.title,
            if (bubble) 'pinned',
            if (conv.isLive) 'live voice chat',
            if (widget.streaming.contains(conv.id)) 'reply in progress',
          ].join(', '),
          excludeSemantics: true,
          onLongPress: () => _menu(anchor, conv),
          onTap: () => widget.onSelect(conv.id),
          child: Material(
            key: ValueKey('chat-row-${conv.id}'),
            color: current
                ? (desktop ? t.surfaceHigh : t.surface)
                : Colors.transparent,
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              onTap: () => widget.onSelect(conv.id),
              onLongPress: () => _menu(anchor, conv),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: desktop ? 36 : 56),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: desktop ? 10 : 20,
                    vertical: desktop ? 8 : 14,
                  ),
                  child: Row(
                    children: [
                      if (bubble && !desktop) ...[
                        Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 20,
                          color: t.text,
                        ),
                        const SizedBox(width: 14),
                      ],
                      if (conv.isLive) ...[
                        WaveGlyph(color: t.textMuted, size: 16),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          conv.title,
                          style: desktop
                              ? _desktopText(t)
                              : t.row.copyWith(fontSize: 17).hermesWeight(400),
                          maxLines:
                              MediaQuery.textScalerOf(context).scale(1) > 1.3
                              ? 2
                              : 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (widget.streaming.contains(conv.id)) ...[
                        const SizedBox(width: 8),
                        SizedBox.square(
                          dimension: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: t.textMuted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _searchSlivers(HermesTokens t) {
    final q = c.query;
    if (q.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text('Search titles and messages', style: t.label),
          ),
        ),
      ];
    }
    if (c.searchError != null) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text(
              'Search failed.',
              style: t.label.copyWith(color: t.danger),
            ),
          ),
        ),
      ];
    }
    final results = c.results;
    return [
      if (results.isEmpty && !c.searching)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text('No matches', style: t.label),
          ),
        ),
      SliverList.builder(
        itemCount: results.length,
        itemBuilder: (context, i) {
          final r = results[i];
          return InkWell(
            onTap: () {
              _closeSearch();
              widget.onSelect(r.conversation.id);
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.conversation.title,
                    style: t.row,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!r.titleMatch) ...[
                    const SizedBox(height: 2),
                    Text.rich(
                      highlight(searchSnippet(r.snippet, q), q, t),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    ];
  }

  /// The floating "Chat" pill (new chat) and the avatar, over the chat
  /// screen's composer feather (same stops and levels), so the list scrolls
  /// softly underneath with no solid band. The feather takes no touches.
  Widget _bottomBar(HermesTokens t, double bottom) {
    // The row (a 48 dp pill) and the space under it.
    final extent = 48 + 12 + bottom;
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: EdgeFeather.gradient(
                  EdgeFeather.bottomStops(composerExtent: extent),
                  t.bgRaised,
                ),
              ),
            ),
          ),
        ),
        _bottomRow(t, bottom),
      ],
    );
  }

  Widget _bottomRow(HermesTokens t, double bottom) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        EdgeFeather.aboveComposer,
        16,
        12 + bottom,
      ),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: 'New chat',
            excludeSemantics: true,
            onTap: widget.onNewChat,
            child: Material(
              key: const ValueKey('drawer-new-chat'),
              color: t.accent,
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              elevation: 2,
              shadowColor: t.accent.withValues(alpha: 0.4),
              child: InkWell(
                onTap: widget.onNewChat,
                child: SizedBox(
                  height: 52,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit_outlined, size: 20, color: t.onAccent),
                        const SizedBox(width: 10),
                        Text(
                          'Chat',
                          style: t.row.copyWith(
                            color: t.onAccent,
                            fontSize: 17,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          Builder(
            builder: (anchor) => Semantics(
              button: true,
              label: widget.onProfile != null
                  ? '$_name, settings'
                  : 'Account and settings menu',
              hint: 'Connected to ${widget.serverHost}',
              excludeSemantics: true,
              onTap: () => _openProfile(anchor),
              child: Tooltip(
                message: widget.onProfile != null ? 'Settings' : 'Menu',
                child: InkResponse(
                  key: const ValueKey('drawer-avatar'),
                  onTap: () => _openProfile(anchor),
                  radius: 28,
                  child: SizedBox.square(
                    dimension: 52,
                    child: Center(
                      child: ProfileAvatar(
                        profile: widget.profile,
                        name: widget.displayName,
                        size: 44,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _accountMenu(BuildContext anchor) => showAccountMenu(
    anchor,
    serverHost: widget.serverHost,
    onSettings: widget.onSettings,
  );
}

/// The avatar's initials, from the server's host name (there are no user
/// accounts).
String accountInitials(String host) {
  final h = host.split('.').first;
  final parts = h.split(RegExp(r'[-_\s]+')).where((p) => p.isNotEmpty);
  final s = parts.map((p) => p[0].toUpperCase()).take(2).join();
  return s.isEmpty ? 'H' : s;
}

Widget accountAvatar(HermesTokens t, String initials) => CircleAvatar(
  radius: 20,
  backgroundColor: t.surfaceHigh,
  child: Text(
    initials,
    style: t.label.copyWith(color: t.text).hermesWeight(600),
  ),
);

/// The avatar's menu: which server this app talks to (there are no user
/// accounts), and Settings. It opens above the avatar.
Future<void> showAccountMenu(
  BuildContext anchor, {
  required String serverHost,
  required VoidCallback onSettings,
}) async {
  final t = HermesTokens.of(anchor);
  final choice = await showPopover<String>(
    anchor: anchor,
    width: 264,
    align: PopoverAlign.end,
    label: 'Account and settings',
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          container: true,
          label: '${Brand.appName}, connected to $serverHost',
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                accountAvatar(t, accountInitials(serverHost)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(Brand.appName, style: t.row),
                      Text(
                        serverHost,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: t.label,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: t.hairline),
        PopoverItem(
          label: 'Settings',
          icon: Icons.settings_outlined,
          onTap: () => Navigator.pop(context, 'settings'),
        ),
      ],
    ),
  );
  if (choice == 'settings') onSettings();
}

/// Highlights [query]'s words in [text] (API.md: snippets have no markers).
TextSpan highlight(String text, String query, HermesTokens t) {
  final base = t.label.hermesWeight(400);
  final words = query
      .split(RegExp(r'\s+'))
      .where((w) => w.length > 1)
      .map(RegExp.escape)
      .toList();
  if (words.isEmpty) return TextSpan(text: text, style: base);
  final re = RegExp(words.join('|'), caseSensitive: false);
  final spans = <TextSpan>[];
  var i = 0;
  for (final m in re.allMatches(text)) {
    if (m.start > i) spans.add(TextSpan(text: text.substring(i, m.start)));
    spans.add(
      TextSpan(
        text: m[0],
        style: base.hermesWeight(600).copyWith(color: t.text),
      ),
    );
    i = m.end;
  }
  if (i < text.length) spans.add(TextSpan(text: text.substring(i)));
  return TextSpan(style: base, children: spans);
}

Future<bool> confirmDeleteChat(BuildContext context, String title) async {
  final t = HermesTokens.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete chat?'),
      content: Text('“$title” and its messages will be deleted.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: t.danger),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return ok == true;
}
