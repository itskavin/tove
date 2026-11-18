import 'steps.dart';
import 'chat_errors.dart';

// Wire format: infra/core/gpt-live-bridge/API.md (version 2). Timestamps are
// integer Unix milliseconds.

DateTime _time(Object? v) => v is num
    ? DateTime.fromMillisecondsSinceEpoch(v.round())
    : DateTime.fromMillisecondsSinceEpoch(0);

String _s(Object? v, [String fallback = '']) => v is String ? v : fallback;
String? _sn(Object? v) => v is String && v.isNotEmpty ? v : null;
bool _b(Object? v, [bool fallback = false]) => v is bool ? v : fallback;
int _i(Object? v, [int fallback = 0]) => v is num ? v.round() : fallback;
Map<String, dynamic> _m(Object? v) =>
    v is Map<String, dynamic> ? v : const <String, dynamic>{};

/// Reply effort (`effort` on `/api/chat`).
enum ChatEffort {
  instant,
  medium,
  high;

  String get wire => name;

  static ChatEffort? parse(Object? v) {
    for (final e in values) {
      if (e.name == v) return e;
    }
    return null;
  }
}

class ChatLimits {
  const ChatLimits({
    this.messageChars = 8000,
    this.titleChars = 120,
    this.queryChars = 200,
    this.pageMax = 100,
    this.messagesPageMax = 200,
    this.transcriptTurns = 500,
    this.transcriptTasks = 50,
    this.taskChars = 32000,
    this.keepalive = const Duration(seconds: 15),
    this.concurrentChats = 2,
    this.streamKeep = const Duration(seconds: 300),
  });

  factory ChatLimits.fromJson(Map<String, dynamic> j) {
    const d = ChatLimits();
    final ka = j['keepalive_s'];
    return ChatLimits(
      messageChars: _i(j['message_chars'], d.messageChars),
      titleChars: _i(j['title_chars'], d.titleChars),
      queryChars: _i(j['query_chars'], d.queryChars),
      pageMax: _i(j['page_max'], d.pageMax),
      messagesPageMax: _i(j['messages_page_max'], d.messagesPageMax),
      transcriptTurns: _i(j['transcript_turns'], d.transcriptTurns),
      transcriptTasks: _i(j['transcript_tasks'], d.transcriptTasks),
      taskChars: _i(j['task_chars'], d.taskChars),
      keepalive: ka is num && ka > 0
          ? Duration(milliseconds: (ka * 1000).round())
          : d.keepalive,
      concurrentChats: _i(j['concurrent_chats'], d.concurrentChats),
      streamKeep: j['stream_keep_s'] is num && (j['stream_keep_s'] as num) > 0
          ? Duration(milliseconds: ((j['stream_keep_s'] as num) * 1000).round())
          : d.streamKeep,
    );
  }

  final int messageChars;
  final int titleChars;
  final int queryChars;
  final int pageMax;
  final int messagesPageMax;
  final int transcriptTurns;
  final int transcriptTasks;
  final int taskChars;
  final Duration keepalive;

  /// Replies the bridge writes at once (one key, so global).
  final int concurrentChats;

  /// How long a finished reply's events stay replayable (`stream_keep_s`).
  final Duration streamKeep;
}

/// `GET /api/capabilities`. A 404 there means a version 1 bridge: live only.
class Capabilities {
  const Capabilities({
    this.known = true,
    this.version = 2,
    this.chat = false,
    this.history = false,
    this.search = false,
    this.effort = false,
    this.efforts = const [],
    this.attachments = false,
    this.language = false,
    this.statusEvents = false,
    this.liveLink = false,
    this.liveTranscript = false,
    this.titles = 'simple',
    this.errorCodes = false,
    this.voices = const [],
    this.defaultVoice,
    this.limits = const ChatLimits(),
    this.resumableStream = false,
    this.stopEndpoint = false,
    this.disconnectCancels = false,
    this.push,
    this.pushPreviews = true,
    this.webSearch = false,
    this.vision = false,
    this.raw = const {},
  });

  /// Live only. [known] is false when the server could not be asked (network
  /// error), so the app should try again later; true for a real 404.
  const Capabilities.liveOnly({required bool known})
    : this(known: known, version: known ? 1 : 0);

  factory Capabilities.fromJson(Map<String, dynamic> j) => Capabilities(
    version: _i(j['version'], 2),
    chat: _b(j['chat']),
    history: _b(j['history']),
    search: _b(j['search']),
    effort: _b(j['effort']),
    efforts: [
      for (final e in (j['efforts'] is List ? j['efforts'] as List : const []))
        ?ChatEffort.parse(e),
    ],
    attachments: _b(j['attachments']),
    language: _b(j['language']),
    statusEvents: _b(j['status_events']),
    liveLink: _b(j['live_link']),
    liveTranscript: _b(j['live_transcript']),
    titles: _s(j['titles'], 'simple'),
    errorCodes: _b(j['error_codes']),
    voices: [
      for (final v in (j['voices'] is List ? j['voices'] as List : const []))
        if (v is String) v,
    ],
    defaultVoice: _sn(j['default_voice']),
    limits: ChatLimits.fromJson(_m(j['limits'])),
    resumableStream: _b(j['resumable_stream']),
    stopEndpoint: _b(j['stop_endpoint']),
    disconnectCancels: _b(j['disconnect_cancels']),
    push: _sn(j['push']),
    pushPreviews: j['push_previews'] != false,
    webSearch: _b(j['web_search']),
    vision: _b(j['vision']),
    raw: Map.unmodifiable(j),
  );

  /// False when the server was not reached; the flags are then all off.
  final bool known;

  /// 2 for the current bridge, 1 for an old one (404), 0 when unknown.
  final int version;
  final bool chat;
  final bool history;
  final bool search;
  final bool effort;
  final List<ChatEffort> efforts;
  final bool attachments;
  final bool language;
  final bool statusEvents;
  final bool liveLink;
  final bool liveTranscript;

  /// `hermes` or `simple`.
  final String titles;

  /// `/api/session` returns `usage_limit` / `login_expired` codes.
  final bool errorCodes;
  final List<String> voices;
  final String? defaultVoice;
  final ChatLimits limits;

  /// `GET /api/events` works (API.md "Events"): the app's own notification
  /// stream, so no distributor app is needed.
  bool get events => raw['events'] is Map;

  /// `GET /api/usage/limits` works (the "Usage and limits" page).
  bool get usageLimits => raw['usage_limits'] == true;

  /// The bridge's default seconds between events heartbeats.
  int get eventsHeartbeat {
    final e = raw['events'];
    final v = e is Map ? e['heartbeat_s'] : null;
    return v is num ? v.round().clamp(15, 600) : 80;
  }

  /// Live-call tasks of linked calls are chat messages that stream from
  /// their start (API.md "Live tasks in the chat").
  bool get taskMessages => raw['task_messages'] == true;

  /// Replies keep running after a disconnect; events carry SSE ids and
  /// `GET /api/chat/{id}/stream` resumes them (bridges from 15 Nov 2026).
  final bool resumableStream;

  /// `POST /api/chat/{id}/stop` exists; closing the connection is not a stop.
  final bool stopEndpoint;

  /// The operator kept the old "disconnect cancels" behaviour.
  final bool disconnectCancels;

  /// The push transport the bridge offers (`"unifiedpush"`), or null.
  final String? push;

  /// False when the operator keeps titles and text out of pushes.
  final bool pushPreviews;

  /// `POST /api/chat` honours `web_search: true` (bridge-requests.md §5).
  final bool webSearch;

  /// Hermes' model accepts images (bridge-requests.md §4.1).
  final bool vision;

  /// The whole capabilities object, for modules with their own parsers
  /// (attachment limits).
  final Map<String, dynamic> raw;

  /// Push via `POST /api/push/register` with a UnifiedPush endpoint.
  bool get unifiedPush => push == 'unifiedpush';

  /// Text chat can neither send nor read history: run live only.
  bool get liveOnly => !chat && !history;
}

enum ConversationKind { text, live }

enum TitleSource { auto, hermes, user }

class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    this.titleSource = TitleSource.auto,
    this.pinned = false,
    this.kind = ConversationKind.text,
    required this.created,
    required this.updated,
    this.preview = '',
    this.messageCount = 0,
  });

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
    id: _s(j['id']),
    title: _s(j['title'], 'New chat'),
    titleSource: switch (j['title_source']) {
      'hermes' => TitleSource.hermes,
      'user' => TitleSource.user,
      _ => TitleSource.auto,
    },
    pinned: _b(j['pinned']),
    kind: j['kind'] == 'live' ? ConversationKind.live : ConversationKind.text,
    created: _time(j['created']),
    updated: _time(j['updated']),
    preview: _s(j['preview']),
    messageCount: _i(j['message_count']),
  );

  final String id;
  final String title;
  final TitleSource titleSource;
  final bool pinned;
  final ConversationKind kind;
  final DateTime created;

  /// Changes with every message and live link, not on rename or pin.
  final DateTime updated;
  final String preview;
  final int messageCount;

  bool get isLive => kind == ConversationKind.live;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'title_source': titleSource.name,
    'pinned': pinned,
    'kind': kind.name,
    'created': created.millisecondsSinceEpoch,
    'updated': updated.millisecondsSinceEpoch,
    'preview': preview,
    'message_count': messageCount,
  };

  Conversation copyWith({
    String? title,
    TitleSource? titleSource,
    bool? pinned,
    ConversationKind? kind,
    DateTime? updated,
    String? preview,
    int? messageCount,
  }) => Conversation(
    id: id,
    title: title ?? this.title,
    titleSource: titleSource ?? this.titleSource,
    pinned: pinned ?? this.pinned,
    kind: kind ?? this.kind,
    created: created,
    updated: updated ?? this.updated,
    preview: preview ?? this.preview,
    messageCount: messageCount ?? this.messageCount,
  );
}

enum MessageRole { user, assistant }

/// Where a message came from: typed, a live-call voice turn, or a Hermes task
/// result from a live call.
enum MessageSource { text, voice, task }

/// Client view of a message's state. Server statuses map as `complete` →
/// [done], `cancelled` → [stopped], `error` → [failed], `interrupted` →
/// [interrupted]; [sending] is client-only (optimistic user message).
enum MessageStatus {
  /// A user message on its way to the server.
  sending,

  /// The assistant reply is being written.
  streaming,
  done,

  /// The reply (or the send) failed. Any text is what had arrived.
  failed,

  /// Stopped by the user; the text is the partial reply.
  stopped,

  /// The bridge restarted mid-reply; the text is partial.
  interrupted;

  static MessageStatus fromWire(Object? v) => switch (v) {
    'streaming' => streaming,
    'cancelled' => stopped,
    'error' => failed,
    'interrupted' => interrupted,
    _ => done,
  };

  String get wire => switch (this) {
    sending || streaming => 'streaming',
    done => 'complete',
    failed => 'error',
    stopped => 'cancelled',
    interrupted => 'interrupted',
  };
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.text,
    this.source = MessageSource.text,
    this.status = MessageStatus.done,
    required this.created,
    this.clientId,
    this.meta = const {},
    this.progress,
    this.error,
    this.attachments = const [],
  });

  factory ChatMessage.fromJson(Map<String, dynamic> j) {
    final meta = _m(j['meta']);
    final status = MessageStatus.fromWire(j['status']);
    final code = _sn(meta['error_code']);
    return ChatMessage(
      id: _s(j['id']),
      conversationId: _s(j['conversation_id']),
      role: j['role'] == 'user' ? MessageRole.user : MessageRole.assistant,
      text: _s(j['text']),
      source: switch (j['source']) {
        'voice' => MessageSource.voice,
        'task' => MessageSource.task,
        _ => MessageSource.text,
      },
      status: status,
      created: _time(j['created']),
      clientId: _sn(j['client_id']),
      meta: meta,
      error: status == MessageStatus.failed && code != null
          ? ChatException.fromStream(code, null)
          : null,
      attachments: [
        for (final a
            in (j['attachments'] is List ? j['attachments'] as List : const []))
          ?MessageAttachment.fromJson(a),
      ],
    );
  }

  /// Server id, or a `local-…` id until the server has assigned one.
  final String id;

  /// Empty while a message for a new chat has not been acknowledged.
  final String conversationId;
  final MessageRole role;
  final String text;
  final MessageSource source;
  final MessageStatus status;
  final DateTime created;

  /// `client_msg_id`, `turn:<id>` or `job:<session>:<job>`.
  final String? clientId;

  /// `effort`, `finish_reason`, `usage`, `error_code`; for tasks `task`,
  /// `job`, `session`, `seconds`.
  final Map<String, dynamic> meta;

  /// The latest Hermes progress (`event: status`) while streaming.
  final ChatProgress? progress;

  /// Why it failed, for [MessageStatus.failed].
  final ChatException? error;

  /// Files and images sent with a user message (bridge-requests.md §4.4).
  final List<MessageAttachment> attachments;

  bool get isUser => role == MessageRole.user;
  bool get isAssistant => role == MessageRole.assistant;
  bool get isTask => source == MessageSource.task;
  bool get isVoice => source == MessageSource.voice;

  /// Posted by the assistant itself (bridge `POST /api/notify`: alerts,
  /// briefings), not an answer to a user message, so it cannot be retried.
  bool get isNotify => meta['notify'] is String;
  bool get isStreaming => status == MessageStatus.streaming;
  bool get isLocal => id.startsWith('local-');

  /// Ended early (stopped, failed or interrupted) with some text kept.
  bool get isPartial =>
      role == MessageRole.assistant &&
      (status == MessageStatus.stopped ||
          status == MessageStatus.failed ||
          status == MessageStatus.interrupted);

  /// The error kind, if the message failed.
  ChatErrorKind? get errorKind => error?.kind;

  /// The text of [progress], for the "Thinking…" slot.
  String? get statusLabel => progress?.label;

  /// For task results: the request Hermes was given.
  String? get taskRequest => _sn(meta['task']);

  int? get taskSeconds =>
      meta['seconds'] is num ? (meta['seconds'] as num).round() : null;

  ChatMessage copyWith({
    String? id,
    String? conversationId,
    String? text,
    MessageStatus? status,
    Map<String, dynamic>? meta,
    ChatProgress? progress,
    bool clearProgress = false,
    ChatException? error,
    bool clearError = false,
  }) => ChatMessage(
    id: id ?? this.id,
    conversationId: conversationId ?? this.conversationId,
    role: role,
    text: text ?? this.text,
    source: source,
    status: status ?? this.status,
    created: created,
    clientId: clientId,
    meta: meta ?? this.meta,
    progress: clearProgress ? null : (progress ?? this.progress),
    error: clearError ? null : (error ?? this.error),
    attachments: attachments,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'conversation_id': conversationId,
    'role': role.name,
    'text': text,
    'source': source.name,
    'status': status.wire,
    'created': created.millisecondsSinceEpoch,
    'client_id': clientId,
    'meta': meta,
  };
}

/// A file or image sent with a user message: the bridge's stored copy
/// (`{id, name, mime, size, kind, width?, height?, preview_url?}`).
class MessageAttachment {
  const MessageAttachment({
    required this.id,
    required this.name,
    required this.mime,
    this.size = 0,
    this.width,
    this.height,
    this.previewUrl,
  });

  static MessageAttachment? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'] ?? j['upload_id'];
    if (id is! String || id.isEmpty) return null;
    return MessageAttachment(
      id: id,
      name: j['name'] is String ? j['name'] as String : id,
      mime: j['mime'] is String ? j['mime'] as String : '',
      size: j['size'] is num ? (j['size'] as num).toInt() : 0,
      width: j['width'] is num ? (j['width'] as num).toInt() : null,
      height: j['height'] is num ? (j['height'] as num).toInt() : null,
      previewUrl: j['preview_url'] is String
          ? j['preview_url'] as String
          : null,
    );
  }

  final String id;
  final String name;
  final String mime;
  final int size;
  final int? width;
  final int? height;

  /// Relative to the bridge (`/api/uploads/{id}/preview`), images only.
  final String? previewUrl;

  bool get isImage => mime.startsWith('image/');

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mime': mime,
    'size': size,
    'width': ?width,
    'height': ?height,
    'preview_url': ?previewUrl,
  };
}

class ConversationPage {
  const ConversationPage(this.conversations, this.nextCursor);
  final List<Conversation> conversations;
  final String? nextCursor;
}

class ConversationDetail {
  const ConversationDetail(this.conversation, this.messages, this.hasMore);
  final Conversation conversation;

  /// Oldest first.
  final List<ChatMessage> messages;

  /// Older messages exist (load them with `before:`).
  final bool hasMore;
}

class MessagePage {
  const MessagePage(this.messages, this.hasMore);
  final List<ChatMessage> messages;
  final bool hasMore;
}

class SearchResult {
  const SearchResult({
    required this.conversation,
    this.messageId,
    required this.snippet,
  });

  factory SearchResult.fromJson(Map<String, dynamic> j) => SearchResult(
    conversation: Conversation.fromJson(_m(j['conversation'])),
    messageId: _sn(j['message_id']),
    snippet: _s(j['snippet']),
  );

  final Conversation conversation;

  /// Null for a title match.
  final String? messageId;

  /// Plain text, no highlight markers: highlight the query on the client.
  final String snippet;

  bool get titleMatch => messageId == null;
}

/// A reply's usage (API.md "Usage"). The three basic counts are typed; [raw]
/// keeps every field the bridge sent (`model`, `cached_tokens`, `ttft_ms`,
/// `tool_count`, …) so a just-finished reply's `meta.usage` matches the saved
/// copy that the Details sheet reads after a reload.
class ChatUsage {
  const ChatUsage({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    this.raw = const {},
  });

  static ChatUsage? fromJson(Object? v) {
    if (v is! Map<String, dynamic>) return null;
    return ChatUsage(
      promptTokens: _i(v['prompt_tokens'] ?? v['input_tokens']),
      completionTokens: _i(v['completion_tokens'] ?? v['output_tokens']),
      totalTokens: _i(v['total_tokens']),
      raw: Map<String, dynamic>.unmodifiable(v),
    );
  }

  final int promptTokens;
  final int completionTokens;
  final int totalTokens;

  /// The whole `usage` object as received.
  final Map<String, dynamic> raw;

  /// `meta.usage` for the message: every received field, with the basic
  /// counts filled in for older bridges that send only some of them.
  Map<String, dynamic> toMeta() => {
    ...raw,
    'prompt_tokens': raw['prompt_tokens'] ?? promptTokens,
    'completion_tokens': raw['completion_tokens'] ?? completionTokens,
    'total_tokens': raw['total_tokens'] ?? totalTokens,
  };
}

enum ProgressState { running, completed, failed, info, approval, unknown }

/// `event: status`: Hermes tool and lifecycle progress.
class ChatProgress {
  const ChatProgress({
    required this.label,
    this.state = ProgressState.unknown,
    this.tool,
    this.id,
    this.emoji,
    this.kind,
  });

  factory ChatProgress.fromJson(Map<String, dynamic> j) => ChatProgress(
    label: _s(j['label']),
    state: switch (j['state']) {
      'running' => ProgressState.running,
      'completed' => ProgressState.completed,
      'failed' || 'error' => ProgressState.failed,
      'info' => ProgressState.info,
      'approval' => ProgressState.approval,
      _ => ProgressState.unknown,
    },
    tool: _sn(j['tool']),
    id: _sn(j['id']),
    emoji: _sn(j['emoji']),
    kind: _sn(j['kind']),
  );

  final String label;
  final ProgressState state;
  final String? tool;
  final String? id;
  final String? emoji;
  final String? kind;
}

/// One parsed event of the `/api/chat` stream.
sealed class ChatEvent {
  const ChatEvent();
}

class ChatMetaEvent extends ChatEvent {
  const ChatMetaEvent({
    required this.conversationId,
    required this.messageId,
    this.userMessageId,
    this.clientMsgId,
    this.createdConversation = false,
    this.title,
  });

  factory ChatMetaEvent.fromJson(Map<String, dynamic> j) => ChatMetaEvent(
    conversationId: _s(j['conversation_id']),
    messageId: _s(j['message_id']),
    userMessageId: _sn(j['user_message_id']),
    clientMsgId: _sn(j['client_msg_id']),
    createdConversation: _b(j['created_conversation']),
    title: _sn(j['title']),
  );

  final String conversationId;

  /// The assistant message being written.
  final String messageId;
  final String? userMessageId;
  final String? clientMsgId;
  final bool createdConversation;
  final String? title;
}

class ChatDeltaEvent extends ChatEvent {
  const ChatDeltaEvent(this.text);
  final String text;
}

class ChatProgressEvent extends ChatEvent {
  const ChatProgressEvent(this.progress);
  final ChatProgress progress;
}

/// `event: step.start` / `step.end` (API.md "Steps"): a step begins, or its
/// final form replaces the running copy ([end]).
class ChatStepEvent extends ChatEvent {
  const ChatStepEvent(this.step, {required this.end});
  final ReplyStep step;
  final bool end;
}

/// `event: step.delta`: thinking text to append to step [id].
class ChatStepDeltaEvent extends ChatEvent {
  const ChatStepDeltaEvent(this.id, this.text);
  final String id;
  final String text;
}

class ChatDoneEvent extends ChatEvent {
  const ChatDoneEvent({
    required this.conversationId,
    required this.messageId,
    this.finishReason,
    this.usage,
    this.title,
    this.titlePending = false,
  });

  factory ChatDoneEvent.fromJson(Map<String, dynamic> j) => ChatDoneEvent(
    conversationId: _s(j['conversation_id']),
    messageId: _s(j['message_id']),
    finishReason: _sn(j['finish_reason']),
    usage: ChatUsage.fromJson(j['usage']),
    title: _sn(j['title']),
    titlePending: _b(j['title_pending']),
  );

  final String conversationId;
  final String messageId;
  final String? finishReason;
  final ChatUsage? usage;
  final String? title;

  /// A Hermes title is still coming: re-read the conversation in a few seconds.
  final bool titlePending;
}

/// `event: error`: the reply failed; the text so far is saved as `error`.
class ChatFailedEvent extends ChatEvent {
  const ChatFailedEvent({
    this.conversationId,
    this.messageId,
    required this.error,
  });

  factory ChatFailedEvent.fromJson(Map<String, dynamic> j) => ChatFailedEvent(
    conversationId: _sn(j['conversation_id']),
    messageId: _sn(j['message_id']),
    error: ChatException.fromStream(_sn(j['code']), _sn(j['message'])),
  );

  final String? conversationId;
  final String? messageId;
  final ChatException error;
}

/// `event: stopped`: the reply was stopped (the stop route, a retry, a
/// delete, or a disconnect with `disconnect_cancels`). Not an error.
class ChatStoppedEvent extends ChatEvent {
  const ChatStoppedEvent({this.conversationId, this.messageId, this.reason});

  factory ChatStoppedEvent.fromJson(Map<String, dynamic> j) => ChatStoppedEvent(
    conversationId: _sn(j['conversation_id']),
    messageId: _sn(j['message_id']),
    reason: _sn(j['reason']),
  );

  final String? conversationId;
  final String? messageId;

  /// `user`, `retry`, `deleted` or `disconnect`.
  final String? reason;
}

/// `event: snapshot` (resume only): replace the reply text with [text].
class ChatSnapshotEvent extends ChatEvent {
  const ChatSnapshotEvent({
    this.conversationId,
    this.messageId,
    required this.text,
    this.status,
    this.lastStatus,
    this.steps,
  });

  factory ChatSnapshotEvent.fromJson(Map<String, dynamic> j) =>
      ChatSnapshotEvent(
        conversationId: _sn(j['conversation_id']),
        messageId: _sn(j['message_id']),
        text: _s(j['text']),
        status: _sn(j['status']),
        lastStatus: j['last_status'] is Map<String, dynamic>
            ? ChatProgress.fromJson(j['last_status'] as Map<String, dynamic>)
            : null,
        steps: j['steps'] is List ? stepsFromJson(j['steps']) : null,
      );

  final String? conversationId;
  final String? messageId;
  final String text;

  /// The saved message status (`streaming`, `complete`, …).
  final String? status;

  /// The newest `status` event, if any.
  final ChatProgress? lastStatus;

  /// The reply's steps so far (bridges with `steps`), else null.
  final List<ReplyStep>? steps;
}

/// A finished voice turn for `POST /api/conversations/{id}/live-transcript`.
class LiveTurn {
  const LiveTurn({
    this.id,
    required this.role,
    required this.text,
    this.created,
  });

  /// Makes re-posting idempotent. 1–64 chars of `A-Za-z0-9_-`.
  final String? id;
  final MessageRole role;
  final String text;
  final DateTime? created;

  Map<String, dynamic> toJson() => {
    'id': ?id,
    'role': role.name,
    'text': text,
    if (created != null) 'created': created!.millisecondsSinceEpoch,
  };
}

/// A delegated task result, sent only for calls not linked to the chat.
class LiveTask {
  const LiveTask({
    required this.id,
    required this.request,
    required this.answer,
    required this.done,
    this.seconds = 0,
    this.created,
  });

  final String id;
  final String request;

  /// Hermes' markdown.
  final String answer;
  final bool done;
  final int seconds;
  final DateTime? created;

  Map<String, dynamic> toJson() => {
    'id': id,
    'request': request,
    'answer': answer,
    'status': done ? 'done' : 'failed',
    'seconds': seconds,
    if (created != null) 'created': created!.millisecondsSinceEpoch,
  };
}

class TranscriptImportResult {
  const TranscriptImportResult(this.added, this.skipped, this.conversation);
  final int added;
  final int skipped;
  final Conversation? conversation;
}
