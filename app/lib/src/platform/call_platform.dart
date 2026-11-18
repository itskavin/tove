import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native call integration contract (implemented in android/ and ios/).
///
/// Channel `io.github.tovechat.tove/call`.
///
/// Flutter -> native:
///  * `startCall {muted: bool}`: called once per call, AFTER the microphone
///    permission was granted and the microphone opened, and BEFORE the peer
///    connection is created. Android starts its microphone foreground service
///    (the app is visible at this point, which Android 14+ requires); iOS
///    reports an outgoing call to CallKit. Complete the result when the call
///    is set up, or with a PlatformException when it cannot be. The result
///    map may carry `notificationsVisible: bool` and `warning: String?`
///    (Android when notifications are off).
///  * `updateCall {muted: bool}`: the mute state changed in the app.
///  * `endCall {}`: the call ended for any reason. Can arrive while
///    `startCall` is still pending (the user hung up during setup); method
///    calls are delivered in order, so it always follows `startCall`.
///
/// Native -> Flutter (each answered at once; native waits a few seconds):
///  * `onMute {muted: bool}`: mute pressed in the notification or CallKit UI.
///    Answers `true` once the track is muted, `false` when there is no call
///    to mute (Android then ends its stale service, since it cannot mute the
///    microphone itself).
///  * `onEnd {}`: end pressed in the notification or CallKit UI, or the
///    system ended the call. Flutter then tears the call down and still calls
///    `endCall`, which must be idempotent, even when it has no call.
abstract interface class CallPlatform {
  /// Whether this platform has native call integration at all.
  bool get supported;

  /// Explains what happens in the background when [supported] is false.
  String? get backgroundNote;

  /// Returns a warning to show when the call runs but its system controls
  /// are not visible (for example, notifications are off), else null.
  Future<String?> startCall({required bool muted});
  Future<void> updateCall({required bool muted});
  Future<void> endCall();

  /// [onMute] returns whether the change was applied.
  void setHandlers({
    required bool Function(bool muted) onMute,
    required void Function() onEnd,
  });
}

class CallPlatformException implements Exception {
  const CallPlatformException(this.message);
  final String message;
  @override
  String toString() => message;
}

class MethodChannelCallPlatform implements CallPlatform {
  MethodChannelCallPlatform({MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel(channelName),
      supported =
          supported ??
          (!kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.android ||
                  defaultTargetPlatform == TargetPlatform.iOS));

  static const channelName = 'io.github.tovechat.tove/call';
  final MethodChannel _channel;

  @override
  final bool supported;

  bool Function(bool muted)? _onMute;
  void Function()? _onEnd;

  @override
  String? get backgroundNote => kIsWeb
      ? 'Keep this tab open. Browsers may pause the microphone when the tab '
            'is in the background or the screen locks.'
      : null;

  @override
  void setHandlers({
    required bool Function(bool muted) onMute,
    required void Function() onEnd,
  }) {
    _onMute = onMute;
    _onEnd = onEnd;
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onMute':
          final args = call.arguments;
          final muted = args is Map ? args['muted'] : null;
          if (muted is! bool) return false;
          return _onMute?.call(muted) ?? false;
        case 'onEnd':
          _onEnd?.call();
          return null;
        default:
          throw MissingPluginException('Unknown method ${call.method}');
      }
    });
  }

  Future<Object?> _invoke(String method, Map<String, Object?> args) async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } on MissingPluginException {
      throw const CallPlatformException(
        'This build has no native call support, so the call stops when the '
        'app leaves the screen.',
      );
    } on PlatformException catch (e) {
      throw CallPlatformException(
        e.message?.isNotEmpty == true ? e.message! : 'Native call error',
      );
    }
  }

  @override
  Future<String?> startCall({required bool muted}) async {
    final r = await _invoke('startCall', {'muted': muted});
    if (r is! Map || r['notificationsVisible'] != false) return null;
    final warning = r['warning'];
    return warning is String && warning.isNotEmpty
        ? warning
        : 'Notifications are off, so the call has no controls in the '
              'notification shade or on the lock screen.';
  }

  @override
  Future<void> updateCall({required bool muted}) =>
      _invoke('updateCall', {'muted': muted});

  @override
  Future<void> endCall() => _invoke('endCall', const {});
}
