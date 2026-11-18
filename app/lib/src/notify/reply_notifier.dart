import 'dart:async';

import 'package:flutter/foundation.dart';

import '../background/background_replies.dart';
import 'notification_sink.dart';
import 'reply_notice.dart';

/// Announces finished replies: an in-app banner for a chat that is not on
/// screen, a system notification when the app is in the background.
///
/// The shell renders [current] (or uses `ReplyNoticeBanner`, which does)
/// and wires [opens] to `chat.load(id)`.
class ReplyNotifier {
  ReplyNotifier({
    required this.replies,
    required this.sink,
    required this.onScreenConversation,
    required this.systemEnabled,
    this.appVisible,
    this.bannerDuration = const Duration(seconds: 6),
  }) {
    _sub = replies.finished.listen(_onFinished);
    _tapSub = sink.taps.listen(_opens.add);
  }

  final BackgroundReplies replies;
  final NotificationSink sink;

  /// The chat on screen (`chat.currentConversationId`).
  final String? Function() onScreenConversation;

  /// The "Reply notifications" switch (`ReplyNotificationPrefs.enabled`).
  final bool Function() systemEnabled;

  /// Whether the app is on screen; defaults to the manager's lifecycle view.
  final bool Function()? appVisible;
  final Duration bannerDuration;

  late final StreamSubscription<ReplyTask> _sub;
  late final StreamSubscription<String> _tapSub;
  final _banners = StreamController<ReplyNotice>.broadcast();
  final _opens = StreamController<String>.broadcast();
  final ValueNotifier<ReplyNotice?> current = ValueNotifier(null);
  Timer? _hide;
  bool _disposed = false;

  /// Replies already shown as a system notification (a push while the app
  /// was in the background): their later resume-and-finish stays quiet.
  final Set<String> _announced = {};

  /// Messages that already raised a banner: the same end can arrive from the
  /// reply's own stream, the events stream and a push; it shows once.
  final List<String> _bannered = [];
  final List<StreamSubscription<String>> _extraTaps = [];

  /// Every in-app banner, as it is raised.
  Stream<ReplyNotice> get banners => _banners.stream;

  /// Chats to open: notification taps and banner "View".
  Stream<String> get opens => _opens.stream;

  bool get _visible => appVisible?.call() ?? replies.foreground;

  void _onFinished(ReplyTask t) =>
      announce(ReplyNotice.fromTask(t), alreadyNotified: t.alreadyNotified);

  /// Applies [decideReplyNotice] to [notice] and shows it where it belongs.
  NoticeTarget announce(ReplyNotice? notice, {bool alreadyNotified = false}) {
    if (_disposed) return NoticeTarget.none;
    final id = notice?.messageId;
    final target =
        id != null && (_announced.contains(id) || _bannered.contains(id))
        ? NoticeTarget.none
        : decideReplyNotice(
            notice: notice,
            appVisible: _visible,
            onScreenConversation: onScreenConversation(),
            systemEnabled: systemEnabled(),
            alreadyNotified: alreadyNotified,
          );
    switch (target) {
      case NoticeTarget.banner:
        if (id != null) {
          _bannered.add(id);
          if (_bannered.length > 100) _bannered.removeAt(0);
        }
        _banners.add(notice!);
        current.value = notice;
        _hide?.cancel();
        _hide = Timer(bannerDuration, dismiss);
      case NoticeTarget.system:
        if (id != null) _announced.add(id);
        unawaited(sink.show(notice!));
      case NoticeTarget.none:
        break;
    }
    return target;
  }

  /// More chats to open (taps on notifications another part of the app
  /// posted, such as the Android instant-notification service).
  void addOpens(Stream<String> opens) {
    if (_disposed) return;
    _extraTaps.add(opens.listen(_opens.add));
  }

  /// Hides the banner.
  void dismiss() {
    _hide?.cancel();
    _hide = null;
    if (!_disposed) current.value = null;
  }

  /// The banner's "View": opens the chat and hides the banner.
  void view(ReplyNotice notice) {
    dismiss();
    final id = notice.conversationId;
    if (id != null) _opens.add(id);
  }

  /// Call when a chat opens: drops its banner and system notification.
  void chatOpened(String conversationId) {
    if (current.value?.conversationId == conversationId) dismiss();
    unawaited(sink.clear(conversationId));
  }

  void dispose() {
    _disposed = true;
    _hide?.cancel();
    _sub.cancel();
    _tapSub.cancel();
    for (final s in _extraTaps) {
      s.cancel();
    }
    _banners.close();
    _opens.close();
    current.dispose();
  }
}
