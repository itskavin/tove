import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../markdown/footnotes.dart';
import '../markdown/links.dart';
import 'checklist_store.dart' show ChecklistScope;
import 'ui_model.dart';

/// Wires hermes-ui actions into the app (chat-rendering-v2 §3.2). Place one
/// above each assistant message (or once above the thread with
/// [nextUserMessage] left null and per-message scopes below it).
///
/// Every callback is optional. Without [onSend], `send` controls are shown
/// disabled; links default to the host confirm sheet; copy defaults to the
/// clipboard.
class HermesUiScope extends InheritedWidget {
  const HermesUiScope({
    super.key,
    this.onSend,
    this.onOpenLink,
    this.onCopy,
    this.onFocusComposer,
    this.onSelectionHaptic,
    this.nextUserMessage,
    this.enabled = true,
    this.onEntityDetails,
    this.stateKey,
    required super.child,
  });

  /// Posts [text] as a visible user message (options, `send` buttons).
  final ValueChanged<String>? onSend;

  /// Opens a safe http(s)/mailto [url]. Must confirm with the user first;
  /// defaults to [confirmAndOpen].
  final ValueChanged<String>? onOpenLink;

  /// Copies [text] and tells the user (a toast). Defaults to the clipboard
  /// without a toast; the button shows a check either way.
  final ValueChanged<String>? onCopy;

  /// The "Other…" option chip: focus the composer.
  final VoidCallback? onFocusComposer;

  /// A selection-click haptic (slider steps), so the app's haptics setting
  /// applies. Defaults to [HapticFeedback.selectionClick].
  final VoidCallback? onSelectionHaptic;

  /// The text of the first user message after this reply, or null when this
  /// is the latest reply. Options and `send` buttons lock once it is set and
  /// show which answer was chosen.
  final String? nextUserMessage;

  /// False disables every `send` control (for example while a reply
  /// streams or offline).
  final bool enabled;

  /// Fetches more about an entity for its details sheet (bridge round 3
  /// `POST /api/entity`, capability `entity_details`). Null, or a null
  /// answer, keeps what the reply embedded.
  final Future<UiEntity?> Function(UiEntity entity)? onEntityDetails;

  /// Identifies the message (its id), so blocks that keep state across
  /// rebuilds and devices (checklist ticks, [ChecklistScope]) can key it.
  /// Null: such state lives only in the widget.
  final String? stateKey;

  static HermesUiScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HermesUiScope>();

  @override
  bool updateShouldNotify(HermesUiScope old) =>
      old.onSend != onSend ||
      old.onOpenLink != onOpenLink ||
      old.onCopy != onCopy ||
      old.onFocusComposer != onFocusComposer ||
      old.onSelectionHaptic != onSelectionHaptic ||
      old.nextUserMessage != nextUserMessage ||
      old.enabled != enabled ||
      old.onEntityDetails != onEntityDetails ||
      old.stateKey != stateKey;
}

/// Resolved actions for a widget below an optional [HermesUiScope].
class UiActionHandler {
  UiActionHandler._(this._context, this._scope);

  factory UiActionHandler.of(BuildContext context) =>
      UiActionHandler._(context, HermesUiScope.maybeOf(context));

  final BuildContext _context;
  final HermesUiScope? _scope;

  bool get canSend => _scope?.onSend != null && (_scope?.enabled ?? false);
  bool get canFocusComposer => _scope?.onFocusComposer != null;
  String? get nextUserMessage => _scope?.nextUserMessage;

  void send(String text) {
    if (canSend) _scope!.onSend!(text);
  }

  void openLink(String url) {
    if (safeLink(url) == null) return;
    final cb = _scope?.onOpenLink;
    if (cb != null) {
      cb(url);
    } else {
      confirmAndOpen(_context, url);
    }
  }

  void copy(String text) {
    final cb = _scope?.onCopy;
    if (cb != null) {
      cb(text);
    } else {
      Clipboard.setData(ClipboardData(text: text));
    }
  }

  void focusComposer() => _scope?.onFocusComposer?.call();

  /// More about [e] for its sheet, or null.
  Future<UiEntity?> entityDetails(UiEntity e) async {
    final cb = _scope?.onEntityDetails;
    if (cb == null) return null;
    try {
      return await cb(e);
    } catch (_) {
      return null;
    }
  }

  bool get canFetchEntityDetails => _scope?.onEntityDetails != null;

  void selectionHaptic() {
    final cb = _scope?.onSelectionHaptic;
    if (cb != null) {
      cb();
    } else {
      HapticFeedback.selectionClick();
    }
  }
}

/// Marks a subtree (a `details` body) where hermes-ui blocks are not
/// allowed; they render the fallback instead.
class NoNestedUiBlocks extends InheritedWidget {
  const NoNestedUiBlocks({super.key, required super.child});

  static bool isNested(BuildContext context) =>
      context.getInheritedWidgetOfExactType<NoNestedUiBlocks>() != null;

  @override
  bool updateShouldNotify(NoNestedUiBlocks old) => false;
}

/// The reply's footnote definitions and link handler, for hermes-ui
/// elements that cite sources (entity summaries).
class UiCitations extends InheritedWidget {
  const UiCitations({super.key, required this.footnotes, required super.child});

  final Map<String, Footnote> footnotes;

  static Map<String, Footnote> of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiCitations>()?.footnotes ??
      const {};

  @override
  bool updateShouldNotify(UiCitations old) => old.footnotes != footnotes;
}
