import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/chat.dart';
import '../../settings/local_cache.dart';
import '../../settings/settings.dart';
import '../../sync/chat_archive.dart';
import '../common/group_card.dart';
import '../theme/tokens.dart';
import 'settings_widgets.dart';

/// Saves an exported file; returns false when the person cancelled.
typedef SaveExport = Future<bool> Function(String name, Uint8List bytes);

/// The default [SaveExport]: the platform's save dialog (a download on the
/// web, the share/save sheet on phones).
Future<bool> saveWithPicker(String name, Uint8List bytes) async {
  final uri = await FilePicker.saveFile(
    fileName: name,
    bytes: bytes,
    mimeType: 'application/json',
    dialogTitle: 'Export chats',
  );
  return uri != null;
}

/// What Data controls needs from the app.
class DataControls {
  const DataControls({
    this.conversations,
    this.archive,
    this.onOpenChat,
    this.onChatsCleared,
    this.cache = const AppLocalCache(),
    this.save = saveWithPicker,
  });

  /// The chat list; history, export and delete-all need it.
  final ConversationsController? conversations;

  /// Builds the archive client for the current server.
  final ChatArchive Function()? archive;

  /// Opens a chat from the history list (closes Settings).
  final void Function(String id)? onOpenChat;

  /// Every chat was deleted: the shell starts a fresh chat.
  final VoidCallback? onChatsCleared;
  final LocalCache cache;
  final SaveExport save;

  bool get history => conversations != null && archive != null;

  /// The production wiring: history rows only when the server keeps chats.
  factory DataControls.forServer({
    required SettingsController settings,
    required Capabilities capabilities,
    required ConversationsController conversations,
    void Function(String id)? onOpenChat,
    VoidCallback? onChatsCleared,
  }) {
    final history = capabilities.history;
    final base = Uri.tryParse(settings.url);
    return DataControls(
      conversations: history ? conversations : null,
      archive: history && base != null
          ? () => ChatArchive(
              baseUrl: base,
              accessKey: settings.accessKey,
              pageSize: capabilities.limits.pageMax,
              messagesPage: capabilities.limits.messagesPageMax,
            )
          : null,
      onOpenChat: onOpenChat,
      onChatsCleared: onChatsCleared,
    );
  }
}

/// Settings › Data controls.
List<Widget> dataControlsSection(
  BuildContext context, {
  required DataControls data,
}) => [
  if (data.history) ...[
    const SectionHeader('Chats'),
    GroupCard(
      margin: settingsCard,
      children: [
        SettingAnchor(
          id: 'history',
          child: GroupRow(
            key: const ValueKey('settings-history'),
            label: 'Chat history',
            icon: Icons.history_rounded,
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ChatHistoryPage(data: data),
              ),
            ),
          ),
        ),
        SettingAnchor(
          id: 'export',
          child: GroupRow(
            key: const ValueKey('settings-export'),
            label: 'Export all chats',
            icon: Icons.download_rounded,
            subtitle: 'One JSON file with every chat and message.',
            onTap: () => unawaited(exportChats(context, data)),
          ),
        ),
        SettingAnchor(
          id: 'deleteAll',
          child: GroupRow(
            key: const ValueKey('settings-delete-all'),
            label: 'Delete all chats',
            icon: Icons.delete_outline_rounded,
            danger: true,
            onTap: () => unawaited(deleteAllChats(context, data)),
          ),
        ),
      ],
    ),
    const SettingsNote(
      'Chats live on your server. Deleting them removes them for every '
      'device; the export never includes your access key.',
    ),
  ],
  const SectionHeader('On this device'),
  SettingAnchor(
    id: 'cache',
    child: _CacheCard(cache: data.cache),
  ),
  const DeviceOnlyNote(
    text:
        'Images and attachments are downloaded again when needed. Voice '
        'downloads are under Voice.',
  ),
];

/// A small blocking progress dialog for export and delete-all.
class _ProgressDialog extends StatelessWidget {
  const _ProgressDialog({required this.title, required this.progress});
  final String title;
  final ValueNotifier<(int, int)> progress;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      title: Text(title),
      content: ValueListenableBuilder(
        valueListenable: progress,
        builder: (context, p, _) {
          final (done, total) = p;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(value: total == 0 ? null : done / total),
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(total == 0 ? 'Starting…' : '$done of $total chats'),
              ),
            ],
          );
        },
      ),
    ),
  );
}

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));

/// Exports every chat to a JSON file the person saves.
Future<void> exportChats(BuildContext context, DataControls data) async {
  final make = data.archive;
  if (make == null) return;
  final archive = make();
  final progress = ValueNotifier<(int, int)>((0, 0));
  final nav = Navigator.of(context);
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _ProgressDialog(title: 'Exporting chats', progress: progress),
  );
  Uint8List? bytes;
  var count = 0;
  String? problem;
  try {
    final export = await archive.export(
      onProgress: (d, t) => progress.value = (d, t),
    );
    count = (export['conversations'] as List).length;
    bytes = ChatArchive.encode(export);
  } on ChatArchiveException catch (e) {
    problem = e.message;
  } finally {
    archive.close();
    nav.pop();
    unawaited(dialog.whenComplete(progress.dispose));
  }
  if (!context.mounted) return;
  if (bytes == null) {
    _snack(context, 'Couldn’t export: ${problem ?? 'unknown error'}');
    return;
  }
  try {
    final saved = await data.save(ChatArchive.fileName(DateTime.now()), bytes);
    if (context.mounted && saved) {
      _snack(context, 'Exported $count ${count == 1 ? 'chat' : 'chats'}.');
    }
  } catch (_) {
    if (context.mounted) _snack(context, 'Couldn’t save the file.');
  }
}

/// The confirmation word for [deleteAllChats].
const deleteAllWord = 'DELETE';

/// Asks for the typed word, then deletes every chat.
Future<void> deleteAllChats(BuildContext context, DataControls data) async {
  final make = data.archive;
  final conversations = data.conversations;
  if (make == null || conversations == null) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => const _DeleteAllDialog(),
  );
  if (ok != true || !context.mounted) return;
  final archive = make();
  final progress = ValueNotifier<(int, int)>((0, 0));
  final nav = Navigator.of(context);
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _ProgressDialog(title: 'Deleting chats', progress: progress),
  );
  var done = 0;
  String? problem;
  try {
    done = await archive.deleteAll(
      conversations.delete,
      onProgress: (d, t) => progress.value = (d, t),
    );
  } on ChatArchiveException catch (e) {
    problem = e.message;
  } catch (_) {
    problem = 'a chat couldn’t be deleted';
  } finally {
    archive.close();
    nav.pop();
    unawaited(dialog.whenComplete(progress.dispose));
  }
  data.onChatsCleared?.call();
  unawaited(conversations.refresh().catchError((_) {}));
  if (!context.mounted) return;
  _snack(
    context,
    problem == null
        ? 'Deleted $done ${done == 1 ? 'chat' : 'chats'}.'
        : 'Stopped: $problem.',
  );
}

class _DeleteAllDialog extends StatefulWidget {
  const _DeleteAllDialog();

  @override
  State<_DeleteAllDialog> createState() => _DeleteAllDialogState();
}

class _DeleteAllDialogState extends State<_DeleteAllDialog> {
  final _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final ok = _text.text.trim() == deleteAllWord;
    return AlertDialog(
      title: const Text('Delete all chats?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Every chat and its messages are deleted from your server, for '
            'every device. This can’t be undone. Export them first if you '
            'want a copy.',
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('delete-all-confirm'),
            controller: _text,
            autofocus: true,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Type $deleteAllWord to confirm',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('delete-all-go'),
          style: TextButton.styleFrom(foregroundColor: t.danger),
          onPressed: ok ? () => Navigator.pop(context, true) : null,
          child: const Text('Delete all'),
        ),
      ],
    );
  }
}

class _CacheCard extends StatefulWidget {
  const _CacheCard({required this.cache});
  final LocalCache cache;

  @override
  State<_CacheCard> createState() => _CacheCardState();
}

class _CacheCardState extends State<_CacheCard> {
  int? _bytes;
  bool _measured = false;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_measure());
  }

  Future<void> _measure() async {
    int? b;
    try {
      b = await widget.cache.size();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _bytes = b;
        _measured = true;
      });
    }
  }

  Future<void> _clear() async {
    final t = HermesTokens.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear the cache?'),
        content: const Text(
          'Images and attachment copies on this device are removed. They '
          'download again when a chat needs them. Attachments you haven’t '
          'sent yet need adding again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: t.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      await widget.cache.clear();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _clearing = false);
    await _measure();
    if (mounted) _snack(context, 'Cache cleared.');
  }

  @override
  Widget build(BuildContext context) => GroupCard(
    margin: settingsCard,
    children: [
      GroupRow(
        key: const ValueKey('settings-cache-size'),
        label: 'Images and attachments',
        icon: Icons.photo_library_outlined,
        value: !_measured
            ? 'Measuring…'
            : (_bytes == null ? 'Unknown' : formatBytes(_bytes!)),
      ),
      GroupRow(
        key: const ValueKey('settings-cache-clear'),
        label: _clearing ? 'Clearing…' : 'Clear cache',
        icon: Icons.cleaning_services_outlined,
        onTap: _clearing ? null : _clear,
      ),
    ],
  );
}

/// Every chat on the server, searchable; tap to open, or delete one.
class ChatHistoryPage extends StatefulWidget {
  const ChatHistoryPage({super.key, required this.data});
  final DataControls data;

  @override
  State<ChatHistoryPage> createState() => _ChatHistoryPageState();
}

class _ChatHistoryPageState extends State<ChatHistoryPage> {
  final _query = TextEditingController();
  Timer? _debounce;

  ConversationsController get _c => widget.data.conversations!;

  @override
  void initState() {
    super.initState();
    if (!_c.loaded && !_c.loading) unawaited(_c.refresh().catchError((_) {}));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    // Leave the drawer's list as it was.
    if (_c.isSearching) _c.clearSearch();
    super.dispose();
  }

  void _search(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (q.trim().isEmpty) {
        _c.clearSearch();
      } else {
        unawaited(_c.search(q.trim()).catchError((_) {}));
      }
    });
    setState(() {});
  }

  Future<void> _delete(Conversation c) async {
    final t = HermesTokens.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this chat?'),
        content: Text('“${c.title}” is deleted on every device.'),
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
    if (ok != true) return;
    try {
      await _c.delete(c.id);
    } catch (_) {
      if (mounted) _snack(context, 'Couldn’t delete the chat.');
    }
  }

  void _open(String id) {
    final open = widget.data.onOpenChat;
    if (open == null) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    open(id);
  }

  static String _date(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Scaffold(
      appBar: settingsBar(context, 'Chat history'),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListenableBuilder(
            listenable: _c,
            builder: (context, _) {
              final searching = _query.text.trim().isNotEmpty;
              final rows = <Widget>[];
              if (searching) {
                final seen = <String>{};
                for (final r in _c.results) {
                  final c = r.conversation;
                  if (!seen.add(c.id)) continue;
                  rows.add(
                    GroupRow(
                      key: ValueKey('history-${c.id}'),
                      label: c.title,
                      icon: Icons.chat_bubble_outline_rounded,
                      subtitle: r.snippet.isEmpty
                          ? _date(c.updated)
                          : r.snippet,
                      onTap: () => _open(c.id),
                    ),
                  );
                }
              } else {
                for (final c in _c.conversations) {
                  rows.add(
                    GroupRow(
                      key: ValueKey('history-${c.id}'),
                      label: c.title,
                      icon: c.pinned
                          ? Icons.push_pin_outlined
                          : Icons.chat_bubble_outline_rounded,
                      subtitle: _date(c.updated),
                      trailing: IconButton(
                        tooltip: 'Delete “${c.title}”',
                        icon: Icon(
                          Icons.delete_outline_rounded,
                          color: t.textMuted,
                        ),
                        onPressed: () => unawaited(_delete(c)),
                      ),
                      onTap: () => _open(c.id),
                    ),
                  );
                }
              }
              final busy = searching ? _c.searching : _c.loading;
              return ListView(
                key: const ValueKey('settings-history-list'),
                padding: EdgeInsets.only(
                  bottom: 32 + MediaQuery.paddingOf(context).bottom,
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: TextField(
                      key: const ValueKey('history-search'),
                      controller: _query,
                      onChanged: _search,
                      textInputAction: TextInputAction.search,
                      style: t.row.hermesWeight(400),
                      decoration: InputDecoration(
                        hintText: 'Search chats',
                        isDense: true,
                        prefixIcon: Icon(
                          Icons.search_rounded,
                          size: 20,
                          color: t.textMuted,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(999),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  if (rows.isEmpty)
                    Semantics(
                      liveRegion: true,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                        child: Text(
                          busy
                              ? 'Loading…'
                              : searching
                              ? 'No chats match “${_query.text.trim()}”.'
                              : 'No chats yet.',
                          style: t.row.hermesWeight(400),
                        ),
                      ),
                    )
                  else
                    GroupCard(margin: settingsCard, children: rows),
                  if (!searching && _c.hasMore)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: Align(
                        child: TextButton(
                          onPressed: _c.loading
                              ? null
                              : () =>
                                    unawaited(_c.loadMore().catchError((_) {})),
                          child: const Text('Show more'),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
