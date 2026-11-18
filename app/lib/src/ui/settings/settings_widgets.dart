import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../sync/settings_sync.dart';
import '../common/glass.dart';
import '../common/group_card.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

/// Tells [SettingAnchor]s which setting a search result pointed at.
class SettingsFocusScope extends InheritedWidget {
  const SettingsFocusScope({
    super.key,
    required this.target,
    required this.token,
    required super.child,
  });

  /// The [SettingsEntry.id] to show, or null.
  final String? target;

  /// Changes with every request, so the same result can be shown again.
  final int token;

  static SettingsFocusScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsFocusScope>();

  @override
  bool updateShouldNotify(SettingsFocusScope old) =>
      target != old.target || token != old.token;
}

/// A setting a search result can point at: when it is the target, it
/// scrolls into view and its background glows briefly.
class SettingAnchor extends StatefulWidget {
  const SettingAnchor({super.key, required this.id, required this.child});

  final String id;
  final Widget child;

  @override
  State<SettingAnchor> createState() => _SettingAnchorState();
}

class _SettingAnchorState extends State<SettingAnchor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  int? _seen;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = SettingsFocusScope.maybeOf(context);
    if (scope == null || scope.target != widget.id || scope.token == _seen) {
      return;
    }
    _seen = scope.token;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final reduced = Motion.reduced(context);
      unawaited(
        Scrollable.ensureVisible(
          context,
          alignment: 0.2,
          duration: reduced ? Duration.zero : const Duration(milliseconds: 300),
          curve: Motion.standard,
        ),
      );
      _glow.value = 1;
      unawaited(_glow.animateTo(0, curve: Curves.easeIn));
    });
  }

  @override
  void dispose() {
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return AnimatedBuilder(
      animation: _glow,
      builder: (context, child) => _glow.value == 0
          ? child!
          : DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                color: t.accent.withValues(alpha: 0.16 * _glow.value),
                borderRadius: BorderRadius.circular(Rad.card),
              ),
              child: child,
            ),
      child: widget.child,
    );
  }
}

/// The margin of every card in a settings page.
const settingsCard = EdgeInsets.symmetric(horizontal: 16);

/// A muted explanation under a card.
class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final style = t.label.copyWith(height: 1.4).hermesWeight(400);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 10, 32, 0),
      child: icon == null
          ? Text(text, style: style)
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1, right: 6),
                  child: Icon(icon, size: 14, color: t.textMuted),
                ),
                Expanded(child: Text(text, style: style)),
              ],
            ),
    );
  }
}

/// "On this device only", under the groups that never sync.
class DeviceOnlyNote extends StatelessWidget {
  const DeviceOnlyNote({super.key, this.text = 'On this device only.'});
  final String text;

  @override
  Widget build(BuildContext context) =>
      SettingsNote(text, icon: Icons.smartphone_rounded);
}

/// A note under the groups that sync, shown only when the server syncs
/// settings and there is something to say beyond "synced" (which is the
/// default and needs no label).
class SyncedNote extends StatelessWidget {
  const SyncedNote({super.key, required this.sync, this.text});
  final SettingsSync sync;
  final String? text;

  @override
  Widget build(BuildContext context) => sync.enabled && text != null
      ? SettingsNote(text!, icon: Icons.cloud_outlined)
      : const SizedBox.shrink();
}

/// One line on the sync state, for the hub and Connection.
String syncStatusText(SettingsSync sync) => switch (sync.state) {
  SyncState.localOnly =>
    'Settings are kept on this device. This server doesn’t sync them.',
  SyncState.connecting => 'Checking for settings from your other devices…',
  SyncState.synced => 'Up to date.',
  SyncState.saving => 'Saving your settings…',
  SyncState.offline =>
    'Offline. Changes are kept and sync when the server is back.',
  SyncState.error => sync.problem ?? 'Settings couldn’t be synced.',
};

/// A short form of [syncStatusText] for a row value.
String syncStatusShort(SettingsSync sync) => switch (sync.state) {
  SyncState.localOnly => 'This device only',
  SyncState.connecting => 'Checking…',
  SyncState.synced => 'Synced',
  SyncState.saving => 'Saving…',
  SyncState.offline => 'Waiting to sync',
  SyncState.error => 'Not synced',
};

/// The subtle sync line at the foot of the hub.
class SyncStatusLine extends StatelessWidget {
  const SyncStatusLine({super.key, required this.sync});
  final SettingsSync sync;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: sync,
    builder: (context, _) {
      // Synced is the normal state: no line for it.
      if (sync.state == SyncState.synced) return const SizedBox.shrink();
      final t = HermesTokens.of(context);
      final icon = switch (sync.state) {
        SyncState.synced => Icons.cloud_done_outlined,
        SyncState.saving || SyncState.connecting => Icons.sync_rounded,
        SyncState.offline => Icons.cloud_off_outlined,
        SyncState.error => Icons.error_outline_rounded,
        SyncState.localOnly => Icons.smartphone_rounded,
      };
      return Semantics(
        key: const ValueKey('settings-sync-status'),
        liveRegion: true,
        container: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 14,
                color: sync.state == SyncState.error ? t.danger : t.textMuted,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  syncStatusText(sync),
                  style: t.label.hermesWeight(400),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// The settings app bar: centred title and the glass Back button.
AppBar settingsBar(
  BuildContext context,
  String title, {
  List<Widget>? actions,
}) {
  final t = HermesTokens.of(context);
  return AppBar(
    centerTitle: true,
    title: Text(title),
    leading: Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Center(
        child: GlassButton(
          label: 'Back',
          onPressed: () => Navigator.of(context).maybePop(),
          child: Icon(Icons.arrow_back_rounded, size: 20, color: t.text),
        ),
      ),
    ),
    leadingWidth: 64,
    actions: actions,
  );
}

/// A settings sub-page: the bar and a centred, scrolling column.
class SettingsSubPage extends StatelessWidget {
  const SettingsSubPage({
    super.key,
    required this.title,
    required this.children,
    this.actions,
    this.listKey,
  });

  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  final Key? listKey;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: settingsBar(context, title, actions: actions),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          key: listKey,
          padding: EdgeInsets.only(
            top: 8,
            bottom: 32 + MediaQuery.paddingOf(context).bottom,
          ),
          children: children,
        ),
      ),
    ),
  );
}

/// A one-choice list on its own page (text size, dictation language).
class ChoicePage<T> extends StatelessWidget {
  const ChoicePage({
    super.key,
    required this.title,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.note,
  });

  final String title;
  final List<(T, String, String?)> options;
  final T Function() selected;
  final ValueChanged<T> onSelected;
  final Widget? note;

  static Future<void> open<T>(
    BuildContext context, {
    required String title,
    required List<(T, String, String?)> options,
    required T Function() selected,
    required ValueChanged<T> onSelected,
    Listenable? listenable,
    Widget? note,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => listenable == null
          ? ChoicePage<T>(
              title: title,
              options: options,
              selected: selected,
              onSelected: onSelected,
              note: note,
            )
          : ListenableBuilder(
              listenable: listenable,
              builder: (_, _) => ChoicePage<T>(
                title: title,
                options: options,
                selected: selected,
                onSelected: onSelected,
                note: note,
              ),
            ),
    ),
  );

  @override
  Widget build(BuildContext context) => SettingsSubPage(
    title: title,
    children: [
      GroupCard(
        margin: settingsCard,
        children: [
          for (final (v, label, subtitle) in options)
            GroupRow(
              label: label,
              subtitle: subtitle,
              selected: selected() == v,
              onTap: () => onSelected(v),
            ),
        ],
      ),
      ?note,
    ],
  );
}

/// Edits one text preference on its own page; saves when leaving or on
/// Done.
class TextSettingPage extends StatefulWidget {
  const TextSettingPage({
    super.key,
    required this.title,
    required this.initial,
    required this.onSave,
    this.hint,
    this.help,
    this.maxLength,
    this.multiline = true,
    this.fieldKey,
  });

  final String title;
  final String initial;
  final Future<void> Function(String value) onSave;
  final String? hint;
  final String? help;
  final int? maxLength;
  final bool multiline;
  final Key? fieldKey;

  static Future<void> open(
    BuildContext context, {
    required String title,
    required String initial,
    required Future<void> Function(String value) onSave,
    String? hint,
    String? help,
    int? maxLength,
    bool multiline = true,
    Key? fieldKey,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => TextSettingPage(
        title: title,
        initial: initial,
        onSave: onSave,
        hint: hint,
        help: help,
        maxLength: maxLength,
        multiline: multiline,
        fieldKey: fieldKey,
      ),
    ),
  );

  @override
  State<TextSettingPage> createState() => _TextSettingPageState();
}

class _TextSettingPageState extends State<TextSettingPage> {
  late final _text = TextEditingController(text: widget.initial);
  bool _saved = false;

  Future<void> _save() async {
    if (_saved) return;
    _saved = true;
    await widget.onSave(_text.text);
  }

  @override
  void dispose() {
    // Removed without a pop (rare): save after the tree is unlocked.
    if (!_saved) {
      _saved = true;
      final text = _text.text;
      final save = widget.onSave;
      Future.microtask(() => save(text));
    }
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    // Leaving with Back keeps what was typed.
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(_save());
      },
      child: _page(context, t),
    );
  }

  Widget _page(BuildContext context, HermesTokens t) {
    return SettingsSubPage(
      title: widget.title,
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: TextButton(
            key: const ValueKey('settings-text-done'),
            onPressed: () async {
              await _save();
              if (context.mounted) Navigator.of(context).maybePop();
            },
            child: const Text('Done'),
          ),
        ),
      ],
      children: [
        Padding(
          padding: settingsCard,
          child: TextField(
            key: widget.fieldKey,
            controller: _text,
            autofocus: true,
            minLines: widget.multiline ? 6 : 1,
            maxLines: widget.multiline ? 14 : 1,
            maxLength: widget.maxLength,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: widget.multiline
                ? TextInputAction.newline
                : TextInputAction.done,
            onSubmitted: widget.multiline
                ? null
                : (_) async {
                    await _save();
                    if (context.mounted) Navigator.of(context).maybePop();
                  },
            style: t.row.hermesWeight(400).copyWith(height: 1.4),
            decoration: InputDecoration(hintText: widget.hint, hintMaxLines: 6),
          ),
        ),
        if (widget.help != null) SettingsNote(widget.help!),
      ],
    );
  }
}
