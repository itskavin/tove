import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/ui/markdown/artifact.dart';
import 'package:tove_chat/src/ui/markdown/email_card.dart';
import 'package:tove_chat/src/ui/markdown/hermes_markdown.dart';
import 'package:tove_chat/src/ui/thread/message_actions.dart';

import 'golden_harness.dart';

const landlord = '''```hermes-artifact
{"title":"Leaking tap","kind":"email","lang":"text","to":["Sam (landlord) <sam@example.org>"],"subject":"Leaking tap – repair request"}
Hi Sam,

The kitchen tap has been leaking since Monday. Could you arrange for someone to fix it this week?

Thanks,
Alex
```
''';

class _Composer implements EmailComposer {
  _Composer({this.gmail = true});
  final bool gmail;
  final sent = <Map<String, Object>>[];

  @override
  Future<bool> gmailAvailable() async => gmail;

  @override
  Future<bool> compose({
    required bool gmail,
    required List<String> to,
    required String subject,
    required String body,
  }) async {
    sent.add({'gmail': gmail, 'to': to, 'subject': subject, 'body': body});
    return true;
  }
}

void main() {
  setUpAll(loadReplyFonts);

  group('email artifacts', () {
    test('header to (list or string) and subject; Subject: line fallback', () {
      final a = Artifact.parse(
        '{"title":"T","kind":"email","to":["Ana","b@x.org"],"subject":"Hi"}\nBody',
      )!;
      expect(a.to, ['Ana', 'b@x.org']);
      expect(a.subject, 'Hi');
      expect(a.content, 'Body');
      final b = Artifact.parse(
        '{"title":"T","kind":"email","recipients":"c@y.org"}\nSubject: Old\n\nBody',
      )!;
      expect(b.to, ['c@y.org']);
      expect(b.subject, 'Old');
      expect(b.content, 'Body');
      expect(Artifact.parse('{"title":"T","kind":"email"}\nX')!.to, isEmpty);
    });

    test('mailto: addresses only, percent-encoded, no plus signs', () {
      expect(emailAddresses(['Sam <sam@example.org>', 'Landlord', 'a@b.co']), [
        'sam@example.org',
        'a@b.co',
      ]);
      final u = mailtoUri(
        to: ['Sam <sam@example.org>', 'Landlord'],
        subject: 'Leaking tap & sink',
        body: 'Hi Sam,\n\nIt leaks.',
      ).toString();
      expect(u, startsWith('mailto:sam%40example.org?subject=Leaking%20tap'));
      expect(u, contains('%26%20sink'));
      expect(u, contains('body=Hi%20Sam%2C%0A%0AIt%20leaks.'));
      expect(u, isNot(contains('+')));
      expect(mailtoUri(to: [], subject: '', body: '').toString(), 'mailto:');
    });

    Future<_Composer> pump(
      WidgetTester tester, {
      bool gmail = true,
      Brightness b = Brightness.dark,
      List<String>? notes,
    }) async {
      tester.view.physicalSize = const Size(412, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = _Composer(gmail: gmail);
      await tester.pumpWidget(
        replyFrame(
          MessageActions(
            share: (_) async {},
            notify: (t) => notes?.add(t),
            email: c,
            child: const HermesMarkdown(text: landlord),
          ),
          brightness: b,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      return c;
    }

    testWidgets('the card: Email header, recipients, subject, whole body', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byType(EmailCard), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Sam (landlord) <sam@example.org>'), findsOneWidget);
      expect(find.text('Leaking tap – repair request'), findsOneWidget);
      expect(find.textContaining('fix it this week'), findsOneWidget);
      expect(find.textContaining('Alex'), findsOneWidget);
    });

    testWidgets('Copy copies the body', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      final notes = <String>[];
      await pump(tester, notes: notes);
      await tester.tap(find.byKey(const ValueKey('email-copy')));
      await tester.pump();
      expect(copied, startsWith('Hi Sam,'));
      expect(notes, ['Copied']);
    });

    testWidgets('Send: Gmail and the email app; each composes the draft', (
      tester,
    ) async {
      final c = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('email-send')));
      await tester.pumpAndSettle();
      expect(find.text('Send with Gmail'), findsOneWidget);
      expect(find.text('Open in email app'), findsOneWidget);
      await tester.tap(find.text('Send with Gmail'));
      await tester.pumpAndSettle();
      expect(c.sent.single['gmail'], isTrue);
      expect(c.sent.single['to'], ['Sam (landlord) <sam@example.org>']);
      expect(c.sent.single['subject'], 'Leaking tap – repair request');
      expect(c.sent.single['body'] as String, endsWith('Alex'));

      await tester.tap(find.byKey(const ValueKey('email-send')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open in email app'));
      await tester.pumpAndSettle();
      expect(c.sent.last['gmail'], isFalse);
    });

    testWidgets('no Gmail: only the email app is offered', (tester) async {
      await pump(tester, gmail: false);
      await tester.tap(find.byKey(const ValueKey('email-send')));
      await tester.pumpAndSettle();
      expect(find.text('Send with Gmail'), findsNothing);
      expect(find.text('Open in email app'), findsOneWidget);
    });
  });

  goldenMatrix('email_card', () => const HermesMarkdown(text: landlord));
}
