import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/ui/common/brand_mark.dart';
import 'package:tove_chat/src/ui/common/tove_mark_path.dart';

import 'test_harness.dart';

void main() {
  test('the traced mark fills its box and is centred', () {
    final b = toveMarkPath.getBounds();
    expect(b.left, closeTo(0, 2));
    expect(b.right, closeTo(toveMarkBox, 2));
    expect(b.height, inInclusiveRange(850, 950));
    expect(toveMarkCentreY, inInclusiveRange(480, 600));
  });

  for (final b in Brightness.values) {
    testWidgets('golden: brand mark at 24, 48 and 96 dp (${b.name})', (
      tester,
    ) async {
      phoneSize(tester, size: const Size(220, 120));
      await tester.pumpWidget(
        themed(
          brightness: b,
          const Material(
            key: ValueKey('marks'),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  BrandMark(size: 24),
                  SizedBox(width: 16),
                  BrandMark(size: 48),
                  SizedBox(width: 16),
                  BrandMark(size: 96),
                ],
              ),
            ),
          ),
        ),
      );
      await expectLater(
        find.byKey(const ValueKey('marks')),
        matchesGoldenFile('goldens/brand_mark_${b.name}.png'),
      );
    });
  }
}
