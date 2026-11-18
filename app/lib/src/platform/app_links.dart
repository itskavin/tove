import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../pairing/pair_link.dart';

/// What a `tove://` link asks the app to do.
sealed class LaunchAction {
  const LaunchAction();

  /// Parses `tove://chat/new[?keyboard=1]`, `tove://live` and
  /// `tove://chat/<id>`; null for anything else.
  static LaunchAction? parse(String? link) {
    if (link == null) return null;
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme != 'tove') return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    switch (uri.host) {
      case 'live' when segments.isEmpty:
        return const OpenLive();
      case 'chat' when segments.length == 1:
        final id = segments.single;
        if (id == 'new') {
          return NewChatAction(
            keyboard: uri.queryParameters['keyboard'] == '1',
          );
        }
        return OpenChatAction(id);
    }
    return null;
  }
}

/// A new chat; [keyboard] focuses the composer.
final class NewChatAction extends LaunchAction {
  const NewChatAction({this.keyboard = false});
  final bool keyboard;

  @override
  bool operator ==(Object other) =>
      other is NewChatAction && other.keyboard == keyboard;
  @override
  int get hashCode => Object.hash(NewChatAction, keyboard);
}

/// Live voice (the widget's mic, Live, or the assistant gesture).
final class OpenLive extends LaunchAction {
  const OpenLive();

  @override
  bool operator ==(Object other) => other is OpenLive;
  @override
  int get hashCode => (OpenLive).hashCode;
}

/// An existing chat by id (the quick widget's last chat).
final class OpenChatAction extends LaunchAction {
  const OpenChatAction(this.id);
  final String id;

  @override
  bool operator ==(Object other) => other is OpenChatAction && other.id == id;
  @override
  int get hashCode => Object.hash(OpenChatAction, id);
}

/// Whether Tove is the device's digital assistant app.
class AssistantStatus {
  const AssistantStatus({required this.supported, this.held});

  /// The device has the assistant role (or the older assist setting).
  final bool supported;

  /// Tove holds it; null when the platform does not say.
  final bool? held;
}

/// Ways into the app from outside it (Android), channel `tove/launch`:
/// home-screen widgets and the assistant gesture open it with a `tove://`
/// link (see `LaunchPlugin.kt`), and a scanned or tapped pairing link
/// (`tove://pair?…`) arrives the same way. Pairing links go to [pairs] and
/// [initialPair], everything else to [actions] and [initial]. Also feeds
/// the quick widget's last chat and reads the assistant role. Every call is
/// a no-op elsewhere.
class AppLinks {
  AppLinks({MethodChannel? channel, bool? android})
    : _channel = channel ?? const MethodChannel(channelName),
      _android =
          android ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    if (_android) _channel.setMethodCallHandler(_onCall);
  }

  static const channelName = 'tove/launch';
  final MethodChannel _channel;
  final bool _android;
  final _actions = StreamController<LaunchAction>.broadcast();
  final _pairs = StreamController<PairLink>.broadcast();

  bool get android => _android;

  /// Links that reach the app while it runs.
  Stream<LaunchAction> get actions => _actions.stream;

  /// Pairing links that reach the app while it runs.
  Stream<PairLink> get pairs => _pairs.stream;

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'link') {
      final link = call.arguments as String?;
      final pair = PairLink.parse(link);
      if (pair != null) {
        _pairs.add(pair);
      } else {
        final a = LaunchAction.parse(link);
        if (a != null) _actions.add(a);
      }
    }
    return null;
  }

  Future<String?>? _initialLink;

  /// The native side hands the starting link out once; both readers share it.
  Future<String?> _startLink() => _initialLink ??= () async {
    if (!_android) return null;
    try {
      return await _channel.invokeMethod<String>('initialLink');
    } catch (_) {
      return null;
    }
  }();

  /// The link that started the app, once (pairing links excluded).
  Future<LaunchAction?> initial() async =>
      LaunchAction.parse(await _startLink());

  /// The pairing link that started the app, if it was one.
  Future<PairLink?> initialPair() async => PairLink.parse(await _startLink());

  String? _recentId;
  String? _recentTitle;

  /// The quick widget's last chat; null clears it (sign-out, deleted).
  Future<void> setRecentChat(String? id, String? title) async {
    if (!_android) return;
    if (id == _recentId && title == _recentTitle) return;
    _recentId = id;
    _recentTitle = title;
    try {
      await _channel.invokeMethod<void>('setRecentChat', {
        'id': id,
        'title': title,
      });
    } catch (_) {}
  }

  /// The id last given to [setRecentChat].
  String? get recentChatId => _recentId;

  /// Null where there is no assistant setting (other platforms, old builds).
  Future<AssistantStatus?> assistantStatus() async {
    if (!_android) return null;
    try {
      final r = await _channel.invokeMethod<Map<Object?, Object?>>(
        'assistantStatus',
      );
      if (r == null) return null;
      final held = r['held'];
      return AssistantStatus(
        supported: r['supported'] == true,
        held: held is bool ? held : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// Opens the system's digital-assistant settings (apps cannot request the
  /// role themselves); false when nothing opened.
  Future<bool> openAssistantSettings() async {
    if (!_android) return false;
    try {
      return await _channel.invokeMethod<bool>('openAssistantSettings') == true;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    if (_android) _channel.setMethodCallHandler(null);
    unawaited(_actions.close());
    unawaited(_pairs.close());
  }
}
