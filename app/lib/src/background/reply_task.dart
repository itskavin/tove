// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../chat/chat_api.dart';
import '../chat/chat_errors.dart';
import '../chat/models.dart';
import '../chat/steps.dart';
import '../chat/tool_calls.dart';

/// Where a reply is in its life.
enum ReplyPhase {
  /// The request is out; no event yet.
  connecting,

  /// Events are arriving.
  streaming,

  /// The connection dropped; the reply keeps running on the bridge and the
  /// app is reconnecting (`resumable_stream` bridges only).
  reconnecting,

  /// Complete and saved.
  done,

  /// Hermes or the bridge failed, or the request was refused.
  failed,

  /// Stopped: the Stop button, a retry, a delete.
  stopped,

  /// Cut off without a failure: the bridge restarted, or an old bridge lost
  /// the connection while the app was in the background.
  interrupted;

  bool get terminal => index >= done.index;
}

/// One reply being written, owned by `BackgroundReplies` and independent of
/// which chat is on screen. Read-only for everyone else.
class ReplyTask {
  ReplyTask.internal({
    required this.localId,
    required this.api,
    required this.created,
    String? conversationId,
    String? messageId,
    this.clientMsgId,
    this.effort,
    String? title,
    String seedText = '',
    int? lastEventId,
    this.resumed = false,
    this.alreadyNotified = false,
  }) : _conversationId = conversationId,
       _messageId = messageId,
       _title = title,
       _seed = seedText,
       _lastEventId = lastEventId;

  /// `local-…` id until `meta` names the message.
  final String localId;

  /// The bridge client the reply runs on.
  final ChatApi api;
  final DateTime created;
  final String? clientMsgId;
  final ChatEffort? effort;

  /// Started by a resume (cold start, or opening a chat whose reply is still
  /// streaming), not by a send on this device.
  final bool resumed;

  /// A push or the periodic check already announced this reply's end.
  final bool alreadyNotified;

  String? _conversationId;
  String? _messageId;
  String? _userMessageId;
  String? _title;
  final StringBuffer _text = StringBuffer();
  String _seed;
  int? _lastEventId;
  ReplyPhase _phase = ReplyPhase.connecting;
  ChatProgress? _progress;
  ChatException? _error;
  ChatDoneEvent? _done;
  String? _stopReason;
  int _reconnects = 0;
  final ToolCallLog tools = ToolCallLog();

  /// The bridge's step timeline (`step.*` events). Empty on bridges without
  /// steps; [tools] is the fallback then.
  final StepLog steps = StepLog();
  final Completer<void> _finished = Completer<void>();

  // Connection state, managed by BackgroundReplies.
  ChatStream? reader;
  StreamSubscription<ChatStreamItem>? subscription;
  Timer? retryTimer;
  int attempt = 0;
  DateTime? dropSince;
  DateTime? lastItemAt;
  int itemsSinceAttach = 0;
  bool stopAfterMeta = false;

  String? get conversationId => _conversationId;

  /// The assistant message id (from `meta`, or the resumed id).
  String? get messageId => _messageId;
  String? get userMessageId => _userMessageId;

  /// The chat title as last reported (send time, `meta`, `done`).
  String? get title => _title;

  /// The reply text so far. While a resume replays from the start, the
  /// server's saved copy is shown until the replay has caught up.
  String get text {
    final t = _text.toString();
    return t.length >= _seed.length ? t : _seed;
  }

  int? get lastEventId => _lastEventId;

  /// The text received on this device, without the saved-copy seed.
  String get rawText => _text.toString();

  /// A replay from the start is still catching up with the saved copy.
  bool get hasSeed => _seed.isNotEmpty;
  ReplyPhase get phase => _phase;
  ChatProgress? get progress => _progress;

  /// Why it failed ([ReplyPhase.failed]).
  ChatException? get error => _error;

  /// The `done` event ([ReplyPhase.done]).
  ChatDoneEvent? get doneEvent => _done;

  /// `user`, `retry`, `deleted`, `disconnect` ([ReplyPhase.stopped]).
  String? get stopReason => _stopReason;

  /// How many times the stream was resumed after a drop.
  int get reconnects => _reconnects;

  bool get inFlight => !_phase.terminal;
  bool get finished => _phase.terminal;

  /// Completes when the reply reaches a terminal phase.
  Future<void> get whenFinished => _finished.future;

  /// The message for the thread.
  ChatMessage build({String? fallbackConversation}) {
    final d = _done;
    return ChatMessage(
      id: _messageId ?? localId,
      conversationId: _conversationId ?? fallbackConversation ?? '',
      role: MessageRole.assistant,
      text: text,
      status: switch (_phase) {
        ReplyPhase.connecting ||
        ReplyPhase.streaming ||
        ReplyPhase.reconnecting => MessageStatus.streaming,
        ReplyPhase.done => MessageStatus.done,
        ReplyPhase.failed => MessageStatus.failed,
        ReplyPhase.stopped => MessageStatus.stopped,
        ReplyPhase.interrupted => MessageStatus.interrupted,
      },
      created: created,
      meta: {
        'effort': ?effort?.wire,
        if (d != null) 'finish_reason': ?d.finishReason,
        if (d?.usage != null) 'usage': d!.usage!.toMeta(),
      },
      progress: inFlight ? _progress : null,
      error: _phase == ReplyPhase.failed ? _error : null,
    );
  }

  /// A short plain-text preview of the reply for notifications.
  String preview([int max = 140]) {
    final t = text
        .replaceAll(RegExp(r'```[a-zA-Z0-9_-]*'), '')
        .replaceAll(RegExp(r'[*_`#>]+'), '')
        .replaceAll(RegExp(r'\[([^\]]*)\]\([^)]*\)'), r'$1')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return t.length > max ? '${t.substring(0, max - 1).trimRight()}…' : t;
  }

  // --- mutation (BackgroundReplies only) -----------------------------------

  void applyMeta(ChatMetaEvent m) {
    _conversationId = m.conversationId;
    _messageId = m.messageId;
    _userMessageId = m.userMessageId ?? _userMessageId;
    if (m.title != null) _title = m.title;
  }

  void setIds({String? conversationId, String? messageId}) {
    _conversationId = conversationId ?? _conversationId;
    _messageId = messageId ?? _messageId;
  }

  void setTitle(String? t) {
    if (t != null && t.isNotEmpty) _title = t;
  }

  void appendText(String t) => _text.write(t);

  void replaceText(String t) {
    _text
      ..clear()
      ..write(t);
    _seed = '';
  }

  void setProgress(ChatProgress? p) => _progress = p;

  void noteEventId(int id) {
    if (_lastEventId == null || id > _lastEventId!) _lastEventId = id;
  }

  void resetEventId() => _lastEventId = null;

  void setPhase(ReplyPhase p) => _phase = p;

  void countReconnect() => _reconnects++;

  /// Moves to a terminal phase once. Returns false if it already had one.
  bool finish(
    ReplyPhase p, {
    ChatException? error,
    ChatDoneEvent? done,
    String? stopReason,
  }) {
    if (_phase.terminal) return false;
    assert(p.terminal);
    _phase = p;
    _error = error;
    _done = done;
    _stopReason = stopReason;
    if (_text.isEmpty && _seed.isNotEmpty) {
      _text.write(_seed);
    }
    _seed = '';
    if (!_finished.isCompleted) _finished.complete();
    return true;
  }

  /// After a stop that raced the end of the reply: the bridge says it had
  /// already completed.
  void reviseToDone(String text) {
    _phase = ReplyPhase.done;
    _stopReason = null;
    replaceText(text);
  }

  @override
  String toString() =>
      'ReplyTask(${_messageId ?? localId}, ${_phase.name}, conv $_conversationId)';
}
