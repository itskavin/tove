import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/ui/interactive/interactive.dart';
import 'package:tove_chat/src/ui/markdown/footnotes.dart' show scanFootnotes;
import 'package:tove_chat/src/ui/markdown/hermes_markdown.dart';
import 'package:tove_chat/src/ui/thread/messages.dart';
import 'package:tove_chat/src/ui/thread/reply_details.dart';

import '../markdown/golden_harness.dart' show loadReplyFonts;
import 'round3_fixtures.dart';

/// Round 3 goldens: the sources cluster, the Details sheet, a news-style
/// reply (entity cards, inline citations, news list), entity cards alone
/// and the entity details sheet; dark and light, phone (412 dp, 17/26) and
/// desktop (760 dp, 16/26). Regenerate with
/// `flutter test --update-goldens test/interactive/round3_golden_test.dart`.
void main() {
  final entities =
      parseHermesUi(
            RegExp(r'```hermes-ui\n(\{"v":1,"type":"entities"[\s\S]*?)\n```')
                .firstMatch(newsReply)![1]!,
          ).element!
          as UiEntities;

  void matrix(
    String name,
    Widget Function() build, {
    double phoneHeight = 1400,
    double desktopHeight = 1200,
    bool sheet = false,
  }) {
    for (final b in Brightness.values) {
      for (final desktop in [false, true]) {
        final tag = '${name}_${b.name}_${desktop ? 'desktop' : 'phone'}';
        testWidgets('golden $tag', (tester) async {
          await loadReplyFonts();
          tester.view.physicalSize = Size(
            desktop ? 800 : 412,
            desktop ? desktopHeight : phoneHeight,
          );
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            r3Frame(build(), brightness: b, desktop: desktop, sheet: sheet),
          );
          await tester.pump(const Duration(milliseconds: 600));
          await settleImages(tester);
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byKey(goldenKey),
            matchesGoldenFile('goldens/r3_$tag.png'),
          );
        });
      }
    }
  }

  matrix(
    'sources_cluster',
    () => AssistantMessage(
      message: reply(sourcedReply),
      onRetry: () {},
      onDelete: () {},
    ),
    phoneHeight: 700,
    desktopHeight: 500,
  );

  matrix(
    'details_sheet',
    () => ReplyDetailsView(
      details: ReplyDetails.of(
        reply(
          'x',
          meta: {
            'finish_reason': 'stop',
            'usage': {
              'model': 'gpt-5.5',
              'input_tokens': 28160,
              'output_tokens': 412,
              'total_tokens': 28572,
              'cached_tokens': 27904,
              'reasoning_tokens': 96,
              'model_calls': 2,
              'duration_ms': 9120,
              'ttft_ms': 7310,
              'tool_count': 3,
              'effort': 'medium',
            },
            'tools': [
              {'tool': 'web_search'},
              {'tool': 'web_search'},
              {'tool': 'terminal'},
            ],
          },
        ),
      ),
    ),
    phoneHeight: 1100,
    desktopHeight: 1100,
    sheet: true,
  );

  matrix(
    'details_sheet_partial',
    () => ReplyDetailsView(
      details: ReplyDetails.of(
        reply(
          'x',
          meta: {
            'usage': {
              'prompt_tokens': 912,
              'completion_tokens': 88,
              'total_tokens': 1000,
            },
          },
        ),
      ),
    ),
    phoneHeight: 1100,
    desktopHeight: 1100,
    sheet: true,
  );

  matrix(
    'news_reply',
    () => AssistantMessage(
      message: reply(newsReply),
      onRetry: () {},
      onDelete: () {},
    ),
    phoneHeight: 2600,
    desktopHeight: 2000,
  );

  matrix(
    'entity_cards',
    () => Builder(
      builder: (context) =>
          UiEntitiesView(element: entities, style: MarkdownStyle.of(context)),
    ),
    phoneHeight: 500,
    desktopHeight: 600,
  );

  matrix(
    'entity_sheet',
    () => SizedBox(
      height: 1180,
      child: Builder(
        builder: (context) => UiCitations(
          footnotes: scanFootnotes(newsReply),
          child: EntityDetailsView(
            entity: entities.items.first,
            style: MarkdownStyle.of(context),
            footnotes: scanFootnotes(newsReply),
            onOpenLink: (_) {},
            onFollowUp: () {},
            onOpenImage: (_, _) {},
          ),
        ),
      ),
    ),
    phoneHeight: 1250,
    desktopHeight: 1250,
    sheet: true,
  );
}
