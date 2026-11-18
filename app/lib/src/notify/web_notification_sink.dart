import 'dart:async';

import 'notification_sink.dart';
import 'reply_notice.dart';
import 'web_notifications_stub.dart'
    if (dart.library.js_interop) 'web_notifications_web.dart'
    as browser;

/// The web app's sink: a browser notification while the tab is open but in
/// the background. There is no service worker, so a closed tab gets nothing;
/// the next visit shows the result in the chat (documented in the settings).
class WebNotificationSink implements NotificationSink {
  final _taps = StreamController<String>.broadcast();

  static bool get available => browser.available;

  @override
  Future<void> init() async {}

  @override
  Future<void> show(ReplyNotice notice) async {
    final id = notice.conversationId;
    browser.show(
      notice.heading,
      notice.body,
      'tove-${id ?? notice.kind.name}',
      () {
        if (id != null) _taps.add(id);
      },
    );
  }

  @override
  Future<void> clear(String conversationId) async =>
      browser.close('tove-$conversationId');

  @override
  Stream<String> get taps => _taps.stream;

  @override
  Future<String?> launchConversation() async => null;

  @override
  Future<bool> requestPermission() => browser.requestPermission();
}
