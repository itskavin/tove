import '../background/reply_task.dart';
import '../brand.dart';

/// What a notice is about.
enum ReplyNoticeKind {
  /// A chat reply is complete.
  reply,

  /// A chat reply failed or was cut off.
  failed,

  /// A delegated live-call task finished (push `live.task`, event
  /// `task.done`).
  task,

  /// A live-call task failed, timed out or was cut off.
  taskFailed,

  /// `POST /api/push/test`.
  test,
}

/// Where a finished reply is announced.
enum NoticeTarget {
  /// Nowhere: the chat is on screen, it was stopped, or notifications are off.
  none,

  /// The in-app banner (the app is visible, another chat is open).
  banner,

  /// A system notification (the app is in the background or closed).
  system,
}

/// One announcement: a reply or task ended somewhere the user is not looking.
class ReplyNotice {
  const ReplyNotice({
    required this.kind,
    this.conversationId,
    this.messageId,
    this.title,
    this.preview,
  });

  /// From a finished task; null when it needs no notice (stopped, still
  /// running).
  static ReplyNotice? fromTask(ReplyTask t) {
    final kind = switch (t.phase) {
      ReplyPhase.done => ReplyNoticeKind.reply,
      ReplyPhase.failed || ReplyPhase.interrupted => ReplyNoticeKind.failed,
      _ => null,
    };
    if (kind == null) return null;
    final p = t.preview();
    return ReplyNotice(
      kind: kind,
      conversationId: t.conversationId,
      messageId: t.messageId,
      title: t.title,
      preview: p.isEmpty ? null : p,
    );
  }

  final ReplyNoticeKind kind;

  /// The chat to open on "View" or a tap; null for unlinked tasks and tests.
  final String? conversationId;
  final String? messageId;

  /// The chat title, if known (null with `push_previews: false`).
  final String? title;

  /// Plain-text start of the reply (null with `push_previews: false`).
  final String? preview;

  /// The headline: the chat title, or a generic line.
  String get heading {
    final t = title?.trim();
    if (t != null && t.isNotEmpty) return t;
    return switch (kind) {
      ReplyNoticeKind.task ||
      ReplyNoticeKind.taskFailed => '${Brand.assistantName} finished a task',
      ReplyNoticeKind.test => '${Brand.appName} notifications work',
      _ => Brand.assistantName,
    };
  }

  /// The second line: the preview, or a generic status.
  String get body {
    final p = preview?.trim();
    if (kind == ReplyNoticeKind.failed) {
      return p == null || p.isEmpty
          ? 'Couldn’t finish the reply'
          : 'Couldn’t finish the reply: $p';
    }
    if (kind == ReplyNoticeKind.taskFailed) {
      return 'The task didn’t finish. Open the chat for details.';
    }
    if (p != null && p.isNotEmpty) return p;
    return switch (kind) {
      ReplyNoticeKind.task => 'The result is in the chat',
      ReplyNoticeKind.test => 'This is a test notification',
      _ => 'Reply ready',
    };
  }

  /// Stable per chat, so a newer notice replaces an older one.
  int get notificationId {
    final key = conversationId ?? messageId ?? kind.name;
    var h = 0;
    for (final c in key.codeUnits) {
      h = (h * 31 + c) & 0x3fffffff;
    }
    return h;
  }

  @override
  String toString() => 'ReplyNotice(${kind.name}, $conversationId, $heading)';
}

/// The rule for announcing a finished reply.
///
/// - Stopped replies (and anything without a notice) are never announced.
/// - App visible: nothing for the chat on screen, the in-app banner for any
///   other chat. The banner does not depend on [systemEnabled].
/// - App in the background: a system notification when [systemEnabled] and
///   nothing announced it yet ([alreadyNotified]: a push got there first).
NoticeTarget decideReplyNotice({
  required ReplyNotice? notice,
  required bool appVisible,
  required String? onScreenConversation,
  required bool systemEnabled,
  bool alreadyNotified = false,
}) {
  if (notice == null) return NoticeTarget.none;
  if (appVisible) {
    final here =
        notice.conversationId != null &&
        notice.conversationId == onScreenConversation;
    return here ? NoticeTarget.none : NoticeTarget.banner;
  }
  if (!systemEnabled || alreadyNotified) return NoticeTarget.none;
  return NoticeTarget.system;
}
