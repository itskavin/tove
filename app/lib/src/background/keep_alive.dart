import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'background_replies.dart';
import 'periodic_check.dart';

/// Covers replies left in flight when the app leaves the screen.
///
/// There is no foreground service for chat replies (none is
/// needed): on a bridge with `resumable_stream` a dropped connection does
/// not stop the reply, the bridge finishes it and announces it on its
/// events stream (instant notifications) or to UnifiedPush, and the app
/// resumes the stream when it returns. When push is not active and the app
/// leaves the screen with replies in flight, Android schedules the
/// 15-minute WorkManager check for the case the process is killed.
/// iOS, the web and desktop need nothing here.
class ReplyKeepAlive {
  ReplyKeepAlive({
    required this.replies,
    ReplyCheckScheduler? checks,
    bool? android,
  }) : _checks = checks ?? ReplyCheckScheduler(),
       _android =
           android ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final BackgroundReplies replies;
  final ReplyCheckScheduler _checks;
  final bool _android;
  AppLifecycleListener? _lifecycle;
  bool _started = false;

  /// Starts following the app's lifecycle. Call once (after the binding
  /// exists).
  void start() {
    if (_started || !_android) return;
    _started = true;
    _lifecycle = AppLifecycleListener(onHide: _onHidden, onShow: _onShown);
  }

  void _onHidden() {
    if (replies.busy && !replies.pushActive) unawaited(_checks.schedule());
  }

  void _onShown() {
    if (!replies.busy) unawaited(_checks.cancel());
  }

  void dispose() {
    _lifecycle?.dispose();
    _lifecycle = null;
    _started = false;
  }
}
