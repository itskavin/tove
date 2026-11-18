import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/platform/call_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(MethodChannelCallPlatform.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> sent;
  Object? Function(MethodCall)? reply;

  setUp(() {
    sent = [];
    reply = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      sent.add(call);
      return reply?.call(call);
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// Sends a native -> Flutter call and decodes Dart's answer.
  Future<Object?> fromNative(String method, Object? args) async {
    const codec = StandardMethodCodec();
    ByteData? answer;
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, args)),
      (data) => answer = data,
    );
    return codec.decodeEnvelope(answer!);
  }

  test('startCall: Android result with notifications off -> warning', () async {
    final p = MethodChannelCallPlatform(supported: true);
    reply = (_) => {'notificationsVisible': false, 'warning': 'No controls.'};
    expect(await p.startCall(muted: true), 'No controls.');
    expect(sent.single.method, 'startCall');
    expect(sent.single.arguments, {'muted': true});

    reply = (_) => {'notificationsVisible': false};
    expect(await p.startCall(muted: false), contains('Notifications are off'));

    reply = (_) => {'notificationsVisible': true, 'warning': null};
    expect(await p.startCall(muted: false), isNull);
    reply = (_) => {'callKit': true, 'notificationsVisible': true};
    expect(await p.startCall(muted: false), isNull);
    reply = (_) => null;
    expect(await p.startCall(muted: false), isNull);
  });

  test('startCall: notifications off with no native text -> default', () async {
    // CallBridge.startedPayload sends `warning: null` when it has no context.
    final p = MethodChannelCallPlatform(supported: true);
    for (final warning in [null, '', 42]) {
      reply = (_) => {'notificationsVisible': false, 'warning': warning};
      expect(
        await p.startCall(muted: false),
        contains('no controls in the notification shade'),
      );
    }
  });

  test('startCall: success path sends muted once and returns null', () async {
    final p = MethodChannelCallPlatform(supported: true);
    reply = (_) => {'notificationsVisible': true, 'warning': null};
    expect(await p.startCall(muted: false), isNull);
    expect(sent, hasLength(1));
    expect(sent.single.method, 'startCall');
    expect(sent.single.arguments, {'muted': false});
  });

  test('native errors become CallPlatformException messages', () async {
    final p = MethodChannelCallPlatform(supported: true);
    reply = (_) => throw PlatformException(
      code: 'not_visible',
      message: 'Start a call only while Tove is open on screen.',
    );
    await expectLater(
      p.startCall(muted: false),
      throwsA(
        isA<CallPlatformException>().having(
          (e) => e.message,
          'message',
          contains('open on screen'),
        ),
      ),
    );
  });

  test('onMute answers true only when applied; onEnd answers null', () async {
    final p = MethodChannelCallPlatform(supported: true);
    final mutes = <bool>[];
    var applied = true;
    var ends = 0;
    p.setHandlers(
      onMute: (m) {
        mutes.add(m);
        return applied;
      },
      onEnd: () => ends++,
    );
    expect(await fromNative('onMute', {'muted': true}), isTrue);
    applied = false;
    expect(await fromNative('onMute', {'muted': false}), isFalse);
    expect(await fromNative('onMute', {'muted': 'yes'}), isFalse);
    expect(mutes, [true, false]);
    expect(await fromNative('onEnd', const {}), isNull);
    expect(ends, 1);
  });

  test('unsupported platforms never touch the channel', () async {
    final p = MethodChannelCallPlatform(supported: false);
    expect(await p.startCall(muted: false), isNull);
    await p.updateCall(muted: true);
    await p.endCall();
    expect(sent, isEmpty);
  });
}
