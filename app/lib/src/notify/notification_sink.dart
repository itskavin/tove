import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'reply_notice.dart';
import 'web_notification_sink.dart';

/// Posts system notifications for finished replies and reports taps.
abstract class NotificationSink {
  /// Sets up channels and the tap callback. Safe to call more than once.
  Future<void> init();

  Future<void> show(ReplyNotice notice);

  /// Removes the notice of [conversationId] (the user opened that chat).
  Future<void> clear(String conversationId);

  /// Chat ids from notification taps while the app runs.
  Stream<String> get taps;

  /// The chat a notification tap launched the app with, once.
  Future<String?> launchConversation();

  /// Asks for notification permission (Android 13+, iOS). True if granted.
  Future<bool> requestPermission();
}

/// Web, Windows and tests: nothing is posted.
class NoopNotificationSink implements NotificationSink {
  final shown = <ReplyNotice>[];
  final _taps = StreamController<String>.broadcast();

  @override
  Future<void> init() async {}
  @override
  Future<void> show(ReplyNotice notice) async => shown.add(notice);
  @override
  Future<void> clear(String conversationId) async {}
  @override
  Stream<String> get taps => _taps.stream;

  /// Simulates a tap (tests).
  void tap(String conversationId) => _taps.add(conversationId);
  @override
  Future<String?> launchConversation() async => null;
  @override
  Future<bool> requestPermission() async => false;
}

/// The notification payload: `{"conversation_id", "message_id"}`.
String? conversationFromPayload(String? payload) {
  if (payload == null || payload.isEmpty) return null;
  try {
    final j = jsonDecode(payload);
    if (j is Map && j['conversation_id'] is String) {
      final id = j['conversation_id'] as String;
      return id.isEmpty ? null : id;
    }
  } catch (_) {}
  return null;
}

/// flutter_local_notifications. Android channel "Replies"
/// (`hermes_replies`, default importance), separate from the call channel
/// and from the reply service's quiet ongoing channel. Lock screen: private
/// (the system hides the text until unlocked).
class LocalNotificationSink implements NotificationSink {
  LocalNotificationSink({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const channelId = 'hermes_replies';
  static const channelName = 'Replies';
  static const channelDescription =
      'A reply or task finished while you were away';

  /// The best sink for this platform.
  static NotificationSink platformDefault() {
    // Web: browser notifications while the tab is open (no service worker,
    // so nothing once it is closed).
    if (kIsWeb) {
      return WebNotificationSink.available
          ? WebNotificationSink()
          : NoopNotificationSink();
    }
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return NoopNotificationSink();
    }
    return LocalNotificationSink();
  }

  final FlutterLocalNotificationsPlugin _plugin;
  final _taps = StreamController<String>.broadcast();
  Future<void>? _init;
  String? _launch;
  bool _launchRead = false;

  @override
  Future<void> init() => _init ??= _doInit();

  Future<void> _doInit() async {
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_stat_hermes'),
          iOS: darwin,
          macOS: darwin,
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        ),
        onDidReceiveNotificationResponse: (r) {
          final id = conversationFromPayload(r.payload);
          if (id != null) _taps.add(id);
        },
      );
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp ?? false) {
        _launch = conversationFromPayload(
          details!.notificationResponse?.payload,
        );
      }
    } catch (e) {
      debugPrint('Notifications unavailable: $e');
    }
  }

  @override
  Future<void> show(ReplyNotice notice) async {
    await init();
    try {
      await _plugin.show(
        id: notice.notificationId,
        title: notice.heading,
        body: notice.body,
        payload: jsonEncode({
          'conversation_id': notice.conversationId,
          'message_id': notice.messageId,
        }),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            channelDescription: channelDescription,
            icon: '@drawable/ic_stat_hermes',
            category: AndroidNotificationCategory.message,
            visibility: NotificationVisibility.private,
            styleInformation: BigTextStyleInformation(notice.body),
          ),
          iOS: const DarwinNotificationDetails(threadIdentifier: 'replies'),
          macOS: const DarwinNotificationDetails(threadIdentifier: 'replies'),
        ),
      );
    } catch (e) {
      debugPrint('Could not post a reply notification: $e');
    }
  }

  @override
  Future<void> clear(String conversationId) async {
    await init();
    try {
      await _plugin.cancel(
        id: ReplyNotice(
          kind: ReplyNoticeKind.reply,
          conversationId: conversationId,
        ).notificationId,
      );
    } catch (_) {}
  }

  @override
  Stream<String> get taps => _taps.stream;

  @override
  Future<String?> launchConversation() async {
    await init();
    if (_launchRead) return null;
    _launchRead = true;
    return _launch;
  }

  @override
  Future<bool> requestPermission() async {
    await init();
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android != null) {
        return await android.requestNotificationsPermission() ?? false;
      }
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (ios != null) {
        return await ios.requestPermissions(alert: true, sound: true) ?? false;
      }
      final mac = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      if (mac != null) {
        return await mac.requestPermissions(alert: true, sound: true) ?? false;
      }
    } catch (_) {}
    return defaultTargetPlatform == TargetPlatform.linux;
  }
}
