import 'package:flutter/foundation.dart';

import 'chat_api.dart';
import 'chat_errors.dart';
import 'models.dart';

/// The chat history for the drawer: paging, search, pin, rename, delete and
/// the current chat id. UI-agnostic.
class ConversationsController extends ChangeNotifier {
  ConversationsController({required this.api, this.pageSize = 30});

  final ChatApi api;
  final int pageSize;

  final List<Conversation> _items = [];
  String? _cursor;
  bool _hasMore = false;
  bool _loading = false;
  bool _loaded = false;
  ChatException? _error;
  String? _currentId;
  bool _available = true;

  String _query = '';
  List<SearchResult> _results = const [];
  bool _searching = false;
  ChatException? _searchError;
  int _searchSeq = 0;
  int _listSeq = 0;
  bool _disposed = false;

  /// All loaded chats in server order (newest `updated` first).
  List<Conversation> get conversations => List.unmodifiable(_items);
  List<Conversation> get pinned => [
    for (final c in _items)
      if (c.pinned) c,
  ];
  List<Conversation> get recent => [
    for (final c in _items)
      if (!c.pinned) c,
  ];

  bool get loading => _loading;

  /// The first page has been loaded at least once.
  bool get loaded => _loaded;
  bool get hasMore => _hasMore;
  ChatException? get error => _error;

  /// False when the server has no history (old bridge or `history: false`).
  bool get available => _available;

  String? get currentId => _currentId;
  set currentId(String? id) {
    if (_currentId == id) return;
    _currentId = id;
    _notify();
  }

  Conversation? byId(String id) {
    for (final c in _items) {
      if (c.id == id) return c;
    }
    return null;
  }

  String get query => _query;
  List<SearchResult> get results => _results;
  bool get searching => _searching;
  ChatException? get searchError => _searchError;
  bool get isSearching => _query.isNotEmpty;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Applies capabilities: without history the list is emptied and every call
  /// becomes a no-op.
  void setAvailable(bool value) {
    if (_available == value) return;
    _available = value;
    if (!value) {
      _items.clear();
      _cursor = null;
      _hasMore = false;
      _results = const [];
      _query = '';
    }
    _notify();
  }

  /// Reloads the first page.
  Future<void> refresh() => _load(reset: true);

  /// Loads the next page, if there is one.
  Future<void> loadMore() async {
    if (!_hasMore || _loading) return;
    await _load(reset: false);
  }

  Future<void> _load({required bool reset}) async {
    if (!_available) return;
    final seq = ++_listSeq;
    _loading = true;
    _error = null;
    _notify();
    try {
      final page = await api.listConversations(
        limit: pageSize,
        cursor: reset ? null : _cursor,
      );
      if (seq != _listSeq) return;
      if (reset) _items.clear();
      for (final c in page.conversations) {
        _items.removeWhere((e) => e.id == c.id);
        _items.add(c);
      }
      _cursor = page.nextCursor;
      _hasMore = page.nextCursor != null;
      _loaded = true;
    } on ChatException catch (e) {
      if (seq != _listSeq) return;
      _error = e;
    } finally {
      if (seq == _listSeq) {
        _loading = false;
        _notify();
      }
    }
  }

  /// Inserts or replaces [c], keeping the list ordered by `updated`.
  void upsert(Conversation c) {
    _items.removeWhere((e) => e.id == c.id);
    var i = 0;
    while (i < _items.length && !_items[i].updated.isBefore(c.updated)) {
      i++;
    }
    _items.insert(i, c);
    _results = [
      for (final r in _results)
        r.conversation.id == c.id
            ? SearchResult(
                conversation: c,
                messageId: r.messageId,
                snippet: r.snippet,
              )
            : r,
    ];
    _notify();
  }

  void _replace(Conversation c) {
    final i = _items.indexWhere((e) => e.id == c.id);
    if (i >= 0) {
      _items[i] = c;
    } else {
      upsert(c);
      return;
    }
    _notify();
  }

  /// Removes a chat locally (after it was deleted elsewhere).
  void remove(String id) {
    _items.removeWhere((e) => e.id == id);
    _results = [
      for (final r in _results)
        if (r.conversation.id != id) r,
    ];
    if (_currentId == id) _currentId = null;
    _notify();
  }

  /// Renames on the server. Rethrows on failure; the list is unchanged then.
  Future<Conversation> rename(String id, String title) async {
    final c = await api.renameConversation(id, title.trim());
    _replace(c);
    return c;
  }

  /// Pins or unpins, optimistically; restored and rethrown on failure.
  Future<void> setPinned(String id, bool pinned) async {
    final before = byId(id);
    if (before != null) _replace(before.copyWith(pinned: pinned));
    try {
      _replace(await api.setPinned(id, pinned));
    } on ChatException {
      if (before != null) _replace(before);
      rethrow;
    }
  }

  Future<void> togglePin(String id) async {
    final c = byId(id);
    if (c != null) await setPinned(id, !c.pinned);
  }

  /// Deletes, optimistically; restored and rethrown on failure. A 404 counts
  /// as deleted. When it was the current chat, [currentId] becomes null.
  Future<void> delete(String id) async {
    final index = _items.indexWhere((e) => e.id == id);
    final before = index >= 0 ? _items[index] : null;
    final wasCurrent = _currentId == id;
    remove(id);
    try {
      await api.deleteConversation(id);
    } on ChatException catch (e) {
      if (e.kind == ChatErrorKind.notFound) return;
      if (before != null) {
        _items.insert(index.clamp(0, _items.length), before);
      }
      if (wasCurrent) _currentId = id;
      _notify();
      rethrow;
    }
  }

  /// Searches titles and messages. An empty [q] clears the search. Responses
  /// to older queries are ignored. Debouncing is up to the caller.
  Future<void> search(String q) async {
    final limits = api.cachedCapabilities?.limits ?? const ChatLimits();
    var text = q.trim();
    if (text.length > limits.queryChars) {
      text = text.substring(0, limits.queryChars);
    }
    final seq = ++_searchSeq;
    _query = text;
    _searchError = null;
    if (text.isEmpty || !_available) {
      _results = const [];
      _searching = false;
      _notify();
      return;
    }
    _searching = true;
    _notify();
    try {
      final r = await api.search(text);
      if (seq != _searchSeq) return;
      _results = r;
    } on ChatException catch (e) {
      if (seq != _searchSeq) return;
      _results = const [];
      _searchError = e;
    }
    _searching = false;
    _notify();
  }

  void clearSearch() {
    _searchSeq++;
    _query = '';
    _results = const [];
    _searching = false;
    _searchError = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
