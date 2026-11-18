import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/chat/chat_errors.dart';
import 'package:tove_chat/src/chat/usage_limits.dart';
import 'package:tove_chat/src/ui/settings/usage_limits_page.dart';

import 'test_harness.dart';

final _now = DateTime(2026, 11, 16, 10);
int _ms(Duration d) => _now.add(d).millisecondsSinceEpoch;

Map<String, dynamic> _account(
  String id,
  String label, {
  String status = 'ok',
  String? plan,
  String? note,
  double weeklyLeft = 61,
  Map<String, dynamic>? credits,
}) => {
  'id': id,
  'label': label,
  'plan': plan,
  'status': status,
  'note': note,
  'windows': [
    {
      'id': '5h',
      'label': '5-hour',
      'used_percent': 3.0,
      'remaining_percent': 97.0,
      'resets_at': _ms(const Duration(hours: 3, minutes: 12)),
    },
    {
      'id': 'weekly',
      'label': 'Weekly',
      'remaining_percent': weeklyLeft,
      'resets_at': _ms(const Duration(days: 5, hours: 4)),
    },
  ],
  'credits': credits,
};

Map<String, dynamic> _limits(List<Map<String, dynamic>> providers) => {
  'observed_at': _now
      .subtract(const Duration(minutes: 4))
      .millisecondsSinceEpoch,
  'cached': false,
  'notes': [],
  'providers': providers,
};

Map<String, dynamic> _sample({bool withSecondClaude = true}) => _limits([
  {
    'id': 'codex',
    'name': 'ChatGPT · Codex',
    'accounts': [
      _account(
        'a1',
        't•••@g•••.com',
        plan: 'plus',
        credits: {'balance': 0.0, 'unlimited': false, 'has_credits': false},
      ),
    ],
  },
  {
    'id': 'claude',
    'name': 'Claude',
    'accounts': [
      _account('c1', 'k•••@p•••.dev', status: 'warning', weeklyLeft: 12),
      if (withSecondClaude) _account('c2', 'm•••@p•••.dev', status: 'disabled'),
      _account(
        'c3',
        'r•••@p•••.dev',
        status: 'error',
        note: 'Login expired: sign in again in the proxy',
      ),
    ],
  },
  {
    'id': 'zeta',
    'name': 'Some New Provider',
    'accounts': [
      _account('z1', 'z•••@z•••.io'),
      _account('z2', 'q•••@z•••.io', status: 'expired'),
    ],
  },
]);

class _FakeLoader {
  _FakeLoader(this.answer);
  Map<String, dynamic> answer;
  Object? error;
  final calls = <bool>[];

  Future<UsageLimits> call({bool refresh = false}) async {
    calls.add(refresh);
    if (error != null) throw error!;
    return UsageLimits.fromJson(answer);
  }
}

Future<void> _pump(
  WidgetTester tester,
  LoadUsageLimits? load, {
  Brightness brightness = Brightness.dark,
}) async {
  phoneSize(tester, size: const Size(412, 1400));
  await tester.pumpWidget(
    themed(
      UsageLimitsPage(load: load, clock: () => _now),
      brightness: brightness,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  test('parses and words the windows', () {
    final l = UsageLimits.fromJson(_sample());
    expect(l.providers.map((p) => p.id), ['codex', 'claude', 'zeta']);
    final w = l.providers.first.accounts.single.windows;
    expect(w.first.title, '5-hour limit');
    expect(w.first.remainingPercent, 97);
    expect(resetsIn(w.first.resetsAt!, _now), 'Resets in 3 h 12 min');
    expect(resetsIn(w.last.resetsAt!, _now), 'Resets in 5 days 4 h');
    expect(updatedAgo(l.observedAt!, _now), 'Updated 4 min ago');
    // Missing remaining_percent falls back to 100 - used.
    final only = UsageWindow.fromJson({'id': 'x', 'used_percent': 30});
    expect(only.remainingPercent, 70);
  });

  testWidgets('every account, grouped by provider, with clear states', (
    tester,
  ) async {
    final load = _FakeLoader(_sample());
    await _pump(tester, load.call);
    // Opening asks the providers again.
    expect(load.calls, [true]);
    for (final name in ['ChatGPT · Codex', 'Claude', 'Some New Provider']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    expect(find.text('t•••@g•••.com · Plus'), findsOneWidget);
    expect(find.text('Updated 4 min ago'), findsOneWidget);
    expect(find.text('97% remaining'), findsNWidgets(6));
    expect(find.text('Resets in 3 h 12 min'), findsNWidgets(6));
    expect(find.text('Running low'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);
    expect(find.text('Expired'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('usage-credits')), findsOneWidget);
  });

  testWidgets('accounts removed or added animate out and in by id', (
    tester,
  ) async {
    final load = _FakeLoader(_sample());
    await _pump(tester, load.call);
    expect(find.text('m•••@p•••.dev'), findsOneWidget);

    load.answer = _sample(withSecondClaude: false);
    await tester.drag(
      find.byKey(const ValueKey('usage-list')),
      const Offset(0, 400),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 100));
    // Halfway through its exit it is still there, then it is gone.
    expect(find.text('m•••@p•••.dev'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('m•••@p•••.dev'), findsNothing);
    expect(load.calls.last, isTrue, reason: 'pull asks with ?refresh=1');

    load.answer = _sample();
    await tester.drag(
      find.byKey(const ValueKey('usage-list')),
      const Offset(0, 400),
    );
    await tester.pumpAndSettle();
    expect(find.text('m•••@p•••.dev'), findsOneWidget);
  });

  testWidgets('re-reads quietly every minute while visible', (tester) async {
    final load = _FakeLoader(_sample());
    await _pump(tester, load.call);
    expect(load.calls, [true]);
    // A failing quiet read keeps the last answer on screen.
    load.error = ChatException.network;
    await tester.pump(usageLimitsPollEvery);
    await tester.pump();
    expect(load.calls, [true, false]);
    expect(find.text('Claude'), findsOneWidget);
    expect(find.byKey(const ValueKey('usage-error')), findsNothing);
    // Hidden behind another page: no reads.
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(MaterialPageRoute<void>(builder: (_) => const SizedBox()));
    await tester.pumpAndSettle();
    await tester.pump(usageLimitsPollEvery);
    expect(load.calls, hasLength(2));
  });

  testWidgets('an old bridge and a failure explain themselves', (tester) async {
    await _pump(tester, null);
    expect(find.byKey(const ValueKey('usage-unsupported')), findsOneWidget);

    final load = _FakeLoader(_sample())
      ..error = const ChatException(
        ChatErrorKind.server,
        'x',
        status: 503,
        code: 'usage_limits_unavailable',
      );
    await _pump(tester, load.call);
    expect(find.textContaining('can’t read any account'), findsOneWidget);
  });

  for (final b in Brightness.values) {
    testWidgets('golden ${b.name}', (tester) async {
      final load = _FakeLoader(_sample());
      await _pump(tester, load.call, brightness: b);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/usage_limits_${b.name}.png'),
      );
    });
  }
}
