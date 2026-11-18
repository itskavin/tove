import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/ui/markdown/artifact.dart';
import 'package:tove_chat/src/ui/markdown/hermes_markdown.dart';

import 'golden_harness.dart';

const script = '''Here is the script.

```hermes-artifact
{"title":"Nightly photo backup","kind":"script","lang":"bash","file":"../backup-photos.sh"}
#!/usr/bin/env bash
# Copy new photos to the NAS every night.
set -euo pipefail
SRC="\$HOME/Pictures/"
DEST="nas:/backups/photos/"
for i in 1 2 3; do
  rsync -a "\$SRC" "\$DEST" && break
  sleep 30
done
echo "done"
```
''';

const email = '''```hermes-artifact
{"title":"Reply to the landlord","kind":"email","lang":"text"}
Subject: Boiler repair on Friday

Hi Sam,

Friday at 10 works for me. I will leave the side gate open.

Thanks,
Alex
```
''';

void main() {
  group('Artifact.parse', () {
    test('reads the header and keeps the content verbatim', () {
      final a = Artifact.parse(
        '{"title":"T","kind":"config","lang":"YAML","file":"a/b.yml"}\nx: 1\n',
      )!;
      expect(a.title, 'T');
      expect(a.kind, ArtifactKind.config);
      expect(a.lang, 'yaml');
      expect(a.file, 'b.yml', reason: 'no path');
      expect(a.content, 'x: 1\n');
      expect(a.speakable, 'T (config)');
    });

    test('unknown kind is a document; empty lang is text', () {
      final a = Artifact.parse('{"title":"T","kind":"poem"}\nhi')!;
      expect(a.kind, ArtifactKind.document);
      expect(a.lang, 'text');
      expect(a.prose, isTrue);
    });

    test('an email shows its subject in the header', () {
      final a = Artifact.parse(
        '{"title":"T","kind":"email"}\nSubject: Hello\n\nBody',
      )!;
      expect(a.subject, 'Hello');
      expect(a.content, 'Body');
    });

    test('a bad header is not an artifact', () {
      expect(Artifact.parse('not json\ncode'), isNull);
      expect(Artifact.parse('{"kind":"code"}\ncode'), isNull);
    });

    test('file names are sanitised', () {
      expect(sanitiseFileName('..\\..\\evil<>.sh'), 'evil.sh');
      expect(sanitiseFileName('...'), isNull);
      expect(sanitiseFileName(3), isNull);
    });
  });

  testWidgets('a bad header falls back to a code block', (tester) async {
    await tester.pumpWidget(
      replyFrame(
        const HermesMarkdown(text: '```hermes-artifact\nnope\nx\n```'),
      ),
    );
    expect(find.byType(ArtifactCard), findsNothing);
    expect(find.byType(CodeBlock), findsOneWidget);
  });

  testWidgets('the card expands to a full-screen page with wrap', (
    tester,
  ) async {
    await tester.pumpWidget(replyFrame(const HermesMarkdown(text: script)));
    expect(find.byType(ArtifactCard), findsOneWidget);
    expect(find.text('Nightly photo backup'), findsOneWidget);
    expect(find.text('backup-photos.sh'), findsOneWidget);
    expect(find.text('bash'), findsOneWidget);
    await tester.tap(find.text('Expand'));
    await tester.pumpAndSettle();
    expect(find.byType(ArtifactPage), findsOneWidget);
    await tester.tap(find.byTooltip('Wrap lines'));
    await tester.pump();
    expect(find.byTooltip('Don’t wrap lines'), findsOneWidget);
  });

  testWidgets('a streaming artifact shows a skeleton under its title', (
    tester,
  ) async {
    final a = '{"title":"Draft","kind":"draft"}\nDear';
    await tester.pumpWidget(
      replyFrame(
        Builder(
          builder: (context) => ArtifactCard(
            body: a,
            complete: false,
            style: MarkdownStyle.of(context),
          ),
        ),
      ),
    );
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(find.text('Draft'), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('^Writing Draft')), findsOneWidget);
    expect(find.text('Copy'), findsNothing);
    semantics.dispose();
  });

  goldenMatrix('artifact_script', () => const HermesMarkdown(text: script));
  goldenMatrix('artifact_email', () => const HermesMarkdown(text: email));
}
