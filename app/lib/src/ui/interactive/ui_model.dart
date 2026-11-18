/// The hermes-ui block schema, version 1 (chat-rendering-v2 §3.3–§3.5), and
/// its validating parser. Pure Dart; the widgets live in `ui_widgets.dart`.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'expr.dart';

/// Limits (§3.2). Anything over a limit renders the fallback.
abstract final class UiLimits {
  static const int maxBytes = 16 * 1024;
  static const int maxBlocksPerMessage = 6;
  static const int maxElements = 24;
  static const int maxDepth = 2;
  static const int maxString = 300;
  static const int maxLabel = 60;
}

/// The info string that marks a fenced block as hermes-ui.
const String hermesUiInfo = 'hermes-ui';

/// The info string of a safe-HTML fence (`html_view.dart`). A plain
/// `html` fence stays a code block: replies also show HTML source.
const String hermesHtmlInfo = 'hermes-html';

final _idRe = RegExp(r'^[a-z0-9-]{1,32}$');

class UiSchemaError implements Exception {
  UiSchemaError(this.message);
  final String message;
  @override
  String toString() => 'UiSchemaError: $message';
}

/// What a control does when used (§3.2). Exactly one of the fields is set.
class UiAction {
  const UiAction.send(String this.send) : link = null, copy = null;
  const UiAction.link(String this.link) : send = null, copy = null;
  const UiAction.copy(String this.copy) : send = null, link = null;

  /// Posts this text as a visible user message.
  final String? send;

  /// Opens this http(s) or mailto URL after the host confirm sheet.
  final String? link;

  /// Copies this text.
  final String? copy;
}

enum UiTone { neutral, info, tip, good, warn, bad }

sealed class UiElement {
  const UiElement({this.id});
  final String? id;

  /// The element's text in reading order, for Read aloud and Share (§3.7).
  String get plainText;
}

class UiOption {
  const UiOption(this.label, this.send);
  final String label;
  final String send;
}

class UiOptions extends UiElement {
  const UiOptions({
    super.id,
    this.prompt,
    required this.many,
    required this.options,
    this.other = false,
  });
  final String? prompt;

  /// `select: "many"`: chips toggle, then Send.
  final bool many;
  final List<UiOption> options;

  /// Adds an "Other…" chip that focuses the composer.
  final bool other;

  @override
  String get plainText =>
      [?prompt, options.map((o) => o.label).join(', ')].join('\n');
}

class UiButton {
  const UiButton(this.label, this.action, {this.primary = false});
  final String label;
  final UiAction action;
  final bool primary;
}

class UiActions extends UiElement {
  const UiActions({super.id, required this.items});
  final List<UiButton> items;
  @override
  String get plainText => items.map((b) => b.label).join(', ');
}

class UiCard {
  const UiCard({
    required this.label,
    required this.value,
    this.sub,
    this.tone = UiTone.neutral,
  });
  final String label;
  final String value;
  final String? sub;
  final UiTone tone;
}

class UiCards extends UiElement {
  const UiCards({super.id, required this.items});
  final List<UiCard> items;
  @override
  String get plainText => [
    for (final c in items)
      [c.label, c.value, if (c.sub != null) c.sub!].join(': '),
  ].join('\n');
}

enum UiInputKind { slider, stepper, toggle, segmented }

class UiSegment {
  const UiSegment(this.label, this.value);
  final String label;
  final double value;
}

class UiInput {
  const UiInput({
    required this.id,
    required this.kind,
    required this.label,
    this.min = 0,
    this.max = 1,
    this.step = 1,
    required this.value,
    this.format,
    this.segments = const [],
  });
  final String id;
  final UiInputKind kind;
  final String label;
  final double min, max, step, value;
  final String? format;
  final List<UiSegment> segments;
}

class UiOutput {
  const UiOutput({
    required this.label,
    required this.expr,
    required this.source,
    this.format,
    this.sub,
    this.tone = UiTone.neutral,
  });
  final String label;
  final Expr expr;
  final String source;
  final String? format;
  final String? sub;
  final UiTone tone;
}

class UiCalc extends UiElement {
  const UiCalc({super.id, required this.inputs, required this.outputs});
  final List<UiInput> inputs;
  final List<UiOutput> outputs;
  @override
  String get plainText => [
    for (final i in inputs) i.label,
    for (final o in outputs) o.label,
  ].join('\n');
}

class UiDetails extends UiElement {
  const UiDetails({
    super.id,
    required this.title,
    required this.body,
    this.open = false,
  });
  final String title;

  /// Markdown (no nested hermes-ui).
  final String body;
  final bool open;
  @override
  String get plainText => '$title\n$body';
}

class UiCallout extends UiElement {
  const UiCallout({
    super.id,
    required this.tone,
    this.title,
    required this.body,
  });
  final UiTone tone;
  final String? title;

  /// Markdown.
  final String body;
  @override
  String get plainText => [?title, body].join('\n');
}

class UiSuggestions extends UiElement {
  const UiSuggestions({super.id, required this.items});
  final List<String> items;
  @override
  String get plainText => '';
}

class UiGroup extends UiElement {
  const UiGroup({super.id, this.title, required this.children});
  final String? title;
  final List<UiElement> children;
  @override
  String get plainText => [
    ?title,
    for (final c in children) c.plainText,
  ].where((s) => s.isNotEmpty).join('\n');
}

/// A labelled fact in an entity's details ("Born": "1963").
class UiFact {
  const UiFact(this.label, this.value);
  final String label;
  final String value;
}

/// A link in an entity's details.
class UiLink {
  const UiLink(this.label, this.url);
  final String label;
  final String url;
}

/// A small picture card in an entity's details ("Career highlights").
class UiMedia {
  const UiMedia({required this.name, this.sub, this.image});
  final String name;
  final String? sub;
  final String? image;
}

/// A person, place, organisation, product or work: a card in a row, and a
/// details sheet when tapped (round 3). Everything but [name] is optional;
/// the sheet shows what the reply embedded and, when the app can ask for
/// more ([HermesUiScope.onEntityDetails]), what that returns.
class UiEntity {
  const UiEntity({
    required this.name,
    this.sub,
    this.image,
    this.page,
    this.about,
    this.facts = const [],
    this.links = const [],
    this.highlights = const [],
    this.ask,
  });

  final String name;

  /// The one-line role or description under the card ("Interim CEO").
  final String? sub;

  /// A picture URL a tool returned (loaded through the bridge).
  final String? image;

  /// The page the entity is best described on.
  final String? page;

  /// A short markdown summary; may cite the reply's footnotes (`[^1]`).
  final String? about;
  final List<UiFact> facts;
  final List<UiLink> links;
  final List<UiMedia> highlights;

  /// The follow-up the sheet's "Follow up" button sends. Defaults to
  /// "Tell me more about `name`".
  final String? ask;

  String get followUp => ask ?? 'Tell me more about $name';

  /// True when the sheet has more to show than the card.
  bool get hasDetails =>
      about != null ||
      facts.isNotEmpty ||
      links.isNotEmpty ||
      highlights.isNotEmpty;

  /// [more] filled in with this entity's own fields where [more] has none.
  UiEntity merge(UiEntity more) => UiEntity(
    name: name,
    sub: sub ?? more.sub,
    image: image ?? more.image,
    page: page ?? more.page,
    about: more.about ?? about,
    facts: more.facts.isNotEmpty ? more.facts : facts,
    links: more.links.isNotEmpty ? more.links : links,
    highlights: more.highlights.isNotEmpty ? more.highlights : highlights,
    ask: ask ?? more.ask,
  );

  String get plainText => [name, ?sub].join(', ');
}

/// A row of entity cards (round 3): pictures with a name and a sub-line.
class UiEntities extends UiElement {
  const UiEntities({super.id, required this.items});
  final List<UiEntity> items;
  @override
  String get plainText => items.map((e) => e.plainText).join('\n');
}

/// One article in a news list.
class UiNewsItem {
  const UiNewsItem({
    required this.title,
    required this.url,
    this.source,
    this.date,
    this.image,
  });
  final String title;
  final String url;

  /// The publisher ("Reuters").
  final String? source;

  /// As written ("November 12").
  final String? date;
  final String? image;

  String get byline => [?source, ?date].join(' · ');
}

/// A list of articles (round 3): thumbnail, linked headline, publisher and
/// date.
class UiNews extends UiElement {
  const UiNews({super.id, required this.items});
  final List<UiNewsItem> items;
  @override
  String get plainText => [
    for (final n in items)
      [n.title, if (n.byline.isNotEmpty) n.byline].join(', '),
  ].join('\n');
}

/// One checkbox row of a checklist.
class UiCheckItem {
  const UiCheckItem(this.label, {this.done = false});
  final String label;

  /// Ticked when the reply arrived; the user's taps win over it.
  final bool done;
}

/// A titled part of a plan: "1. Deep work", "11:30 AM – 2:30 PM".
class UiCheckSection {
  const UiCheckSection({this.title, this.time, this.icon, required this.items});
  final String? title;
  final String? time;

  /// A name from [UiChecklist.icons]; unknown names get the default.
  final String? icon;
  final List<UiCheckItem> items;
}

/// A plan or checklist (round 4): a progress header ("3/9 Tasks
/// completed"), then numbered sections with an icon, a time range and
/// checkbox items the user ticks off. Ticks persist per message.
class UiChecklist extends UiElement {
  const UiChecklist({
    super.id,
    this.title,
    this.numbered = true,
    required this.sections,
  });

  /// The header's caption; "Tasks completed" when absent.
  final String? title;

  /// Section titles get "1.", "2." in front.
  final bool numbered;
  final List<UiCheckSection> sections;

  int get total => sections.fold(0, (n, s) => n + s.items.length);

  /// Stable item keys: `section.item`.
  static String itemKey(int section, int item) => '$section.$item';

  /// The icons a section may name.
  static const icons = {
    'focus',
    'work',
    'rest',
    'morning',
    'evening',
    'home',
    'health',
    'food',
    'learn',
    'code',
    'travel',
    'money',
    'social',
    'errands',
    'homelab',
    'calendar',
    'call',
    'mail',
    'idea',
    'star',
    'list',
  };

  @override
  String get plainText {
    final out = <String>[?title];
    for (final (i, s) in sections.indexed) {
      final head = [
        if (s.title != null) numbered ? '${i + 1}. ${s.title}' : s.title!,
        ?s.time,
      ].join(', ');
      if (head.isNotEmpty) out.add(head);
      for (final it in s.items) {
        out.add('${it.done ? 'Done' : 'To do'}: ${it.label}');
      }
    }
    return out.join('\n');
  }
}

// ------------------------------------------------- dashboard (round 4)

/// A health headline: a state dot, a title, a summary and when it was
/// checked.
class UiStatus extends UiElement {
  const UiStatus({
    super.id,
    required this.title,
    required this.state,
    this.summary,
    this.updated,
  });
  final String title;

  /// [UiTone.good] healthy, [UiTone.warn] degraded, [UiTone.bad] down,
  /// [UiTone.neutral] unknown.
  final UiTone state;
  final String? summary;

  /// As written ("2 min ago", "10:42").
  final String? updated;

  @override
  String get plainText => [
    title,
    stateWord(state),
    ?summary,
    if (updated != null) 'updated $updated',
  ].join(', ');
}

/// The word a screen reader says for a state dot.
String stateWord(UiTone t) => switch (t) {
  UiTone.good => 'healthy',
  UiTone.warn || UiTone.tip => 'degraded',
  UiTone.bad => 'down',
  UiTone.info => 'info',
  UiTone.neutral => 'unknown',
};

/// One number tile: label, value and unit, a change, a small trend line.
class UiMetric {
  const UiMetric({
    required this.label,
    required this.value,
    this.unit,
    this.delta,
    this.tone = UiTone.neutral,
    this.trend = const [],
  });
  final String label;
  final String value;
  final String? unit;

  /// As written ("+4%", "−12 ms").
  final String? delta;

  /// Colours the delta and the trend line.
  final UiTone tone;
  final List<double> trend;
}

class UiMetrics extends UiElement {
  const UiMetrics({super.id, required this.items});
  final List<UiMetric> items;
  @override
  String get plainText => [
    for (final m in items)
      [
        '${m.label}: ${m.value}${m.unit == null ? '' : ' ${m.unit}'}',
        ?m.delta,
      ].join(', '),
  ].join('\n');
}

/// A ring: [value] of [max] (CPU, RAM, disk, battery).
class UiGauge {
  const UiGauge({
    required this.label,
    required this.value,
    this.max = 100,
    this.unit = '%',
    this.sub,
    this.tone = UiTone.neutral,
  });
  final String label;
  final double value;
  final double max;
  final String unit;
  final String? sub;
  final UiTone tone;

  double get fraction => max <= 0 ? 0 : (value / max).clamp(0.0, 1.0);
}

class UiGauges extends UiElement {
  const UiGauges({super.id, required this.items});
  final List<UiGauge> items;
  @override
  String get plainText => [
    for (final g in items)
      '${g.label}: ${uiNumber(g.value)}${g.unit}${g.max != 100 || g.unit != '%' ? ' of ${uiNumber(g.max)}' : ''}',
  ].join('\n');
}

/// One service row: a state dot, name, latency. Tapping sends [ask].
class UiService {
  const UiService({
    required this.name,
    required this.state,
    this.latency,
    this.sub,
    this.ask,
  });
  final String name;
  final UiTone state;
  final String? latency;
  final String? sub;
  final String? ask;

  /// What a tap sends: [ask], or a question that fits the state.
  String get followUp =>
      ask ??
      switch (state) {
        UiTone.bad => 'Why is $name down?',
        UiTone.warn || UiTone.tip => 'What is wrong with $name?',
        _ => 'How is $name doing?',
      };
}

class UiServices extends UiElement {
  const UiServices({super.id, this.title, required this.items});
  final String? title;
  final List<UiService> items;
  @override
  String get plainText => [
    ?title,
    for (final x in items)
      [x.name, stateWord(x.state), ?x.latency, ?x.sub].join(', '),
  ].join('\n');
}

/// One alert: tone, title, optional body and time, and up to two
/// follow-up buttons.
class UiAlert {
  const UiAlert({
    required this.tone,
    required this.title,
    this.body,
    this.time,
    this.actions = const [],
  });
  final UiTone tone;
  final String title;
  final String? body;
  final String? time;
  final List<UiButton> actions;
}

class UiAlerts extends UiElement {
  const UiAlerts({super.id, required this.items});
  final List<UiAlert> items;
  @override
  String get plainText => [
    for (final a in items) [a.title, ?a.body, ?a.time].join('. '),
  ].join('\n');
}

enum UiChartKind { line, bar }

class UiSeries {
  const UiSeries({required this.name, required this.values, this.tone});
  final String name;
  final List<double> values;
  final UiTone? tone;
}

/// A small line or bar chart: 1–3 series of up to 60 points.
class UiChart extends UiElement {
  const UiChart({
    super.id,
    required this.kind,
    this.title,
    this.unit,
    this.labels = const [],
    required this.series,
  });
  final UiChartKind kind;
  final String? title;
  final String? unit;
  final List<String> labels;
  final List<UiSeries> series;

  @override
  String get plainText {
    final u = unit == null ? '' : ' $unit';
    return [
      ?title,
      for (final x in series)
        if (x.values.isNotEmpty)
          '${x.name}: from ${uiNumber(x.values.first)}$u to '
              '${uiNumber(x.values.last)}$u, low ${uiNumber(x.values.reduce(math.min))}$u, '
              'high ${uiNumber(x.values.reduce(math.max))}$u',
    ].join('\n');
  }
}

/// A short number: no trailing ".0", at most one decimal over 10.
String uiNumber(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.abs() >= 10
      ? v.toStringAsFixed(1)
      : v
            .toStringAsFixed(2)
            .replaceFirst(RegExp(r'0+$'), '')
            .replaceFirst(RegExp(r'\.$'), '');
}

/// A `type: "html"` block: a fragment drawn natively from an allowlist
/// (`html_view.dart`).
class UiHtml extends UiElement {
  const UiHtml({super.id, required this.html});
  final String html;
  @override
  String get plainText => html
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// The result of [parseHermesUi]: an [element], or an [error] explaining why
/// the fallback renders.
class UiParseResult {
  const UiParseResult.ok(UiElement this.element) : error = null;
  const UiParseResult.failed(String this.error) : element = null;
  final UiElement? element;
  final String? error;
  bool get ok => element != null;
}

final Map<String, UiParseResult> _memo = {};

/// Parses and validates one hermes-ui block body. Never throws. Results are
/// memoised per source, so rebuilding a block costs nothing.
UiParseResult parseHermesUi(String source) {
  final hit = _memo[source];
  if (hit != null) return hit;
  final r = _parse(source);
  if (_memo.length > 64) _memo.remove(_memo.keys.first);
  _memo[source] = r;
  return r;
}

/// True if [source] could still become a valid block (unbalanced braces or
/// an open string), used to tell a block that is still streaming from one
/// that is broken.
bool looksIncompleteJson(String source) {
  var depth = 0;
  var inString = false;
  var escape = false;
  var sawOpen = false;
  for (final c in source.codeUnits) {
    if (inString) {
      if (escape) {
        escape = false;
      } else if (c == 0x5C) {
        escape = true;
      } else if (c == 0x22) {
        inString = false;
      }
      continue;
    }
    if (c == 0x22) {
      inString = true;
    } else if (c == 0x7B || c == 0x5B) {
      depth++;
      sawOpen = true;
    } else if (c == 0x7D || c == 0x5D) {
      depth--;
    }
  }
  return !sawOpen || inString || depth > 0;
}

/// The element type named in a (possibly partial) block, for the placeholder
/// label.
String? peekUiType(String source) =>
    RegExp(r'"type"\s*:\s*"([a-z]+)"').firstMatch(source)?[1];

UiParseResult _parse(String source) {
  if (utf8.encode(source).length > UiLimits.maxBytes) {
    return const UiParseResult.failed('larger than 16 KB');
  }
  Object? json;
  try {
    json = jsonDecode(source);
  } on FormatException catch (e) {
    return UiParseResult.failed('invalid JSON: ${e.message}');
  }
  try {
    final m = _obj(json, 'block');
    final v = m['v'];
    if (v is! num || v != v.truncate()) {
      throw UiSchemaError('"v" must be a whole number');
    }
    if (v != 1) throw UiSchemaError('unsupported version $v');
    final counter = _Counter();
    final e = _element(m, counter, 1);
    return UiParseResult.ok(e);
  } on UiSchemaError catch (e) {
    return UiParseResult.failed(e.message);
  }
}

class _Counter {
  int n = 0;
  void add() {
    if (++n > UiLimits.maxElements) {
      throw UiSchemaError('more than ${UiLimits.maxElements} elements');
    }
  }
}

Map<String, Object?> _obj(Object? j, String what) {
  if (j is Map<String, Object?>) return j;
  throw UiSchemaError('$what must be an object');
}

List<Object?> _list(Map<String, Object?> m, String key, int min, int max) {
  final l = m[key];
  if (l is! List) throw UiSchemaError('"$key" must be a list');
  if (l.length < min || l.length > max) {
    throw UiSchemaError('"$key" must have $min–$max items');
  }
  return l;
}

String _str(
  Object? v,
  String key, {
  int max = UiLimits.maxString,
  bool required = true,
}) {
  if (v == null && !required) return '';
  if (v is! String) throw UiSchemaError('"$key" must be a string');
  final t = v.trim();
  if (t.isEmpty && required) throw UiSchemaError('"$key" is empty');
  if (t.length > max) throw UiSchemaError('"$key" is longer than $max');
  return t;
}

String? _optStr(
  Map<String, Object?> m,
  String key, {
  int max = UiLimits.maxString,
}) {
  final v = m[key];
  if (v == null) return null;
  final s = _str(v, key, max: max);
  return s.isEmpty ? null : s;
}

/// A numbered checklist adds its own "1.", so a model's own leading number
/// ("1. Deep work", "2) Gym", "Step 3: Lunch") is dropped from the title.
String? _unnumbered(String? title) {
  if (title == null) return null;
  final t = title
      .replaceFirst(
        RegExp(r'^(?:step\s+)?\d{1,2}\s*[.):]\s*', caseSensitive: false),
        '',
      )
      .trim();
  return t.isEmpty ? title : t;
}

String _label(Map<String, Object?> m, String key) =>
    _str(m[key], key, max: UiLimits.maxLabel);

double _num(Map<String, Object?> m, String key, {double? fallback}) {
  final v = m[key];
  if (v == null && fallback != null) return fallback;
  if (v is! num || !v.isFinite) throw UiSchemaError('"$key" must be a number');
  return v.toDouble();
}

bool _bool(Map<String, Object?> m, String key) {
  final v = m[key];
  if (v == null) return false;
  if (v is! bool) throw UiSchemaError('"$key" must be true or false');
  return v;
}

String? _id(Map<String, Object?> m) {
  final v = m['id'];
  if (v == null) return null;
  if (v is! String || !_idRe.hasMatch(v)) {
    throw UiSchemaError('"id" must match [a-z0-9-]{1,32}');
  }
  return v;
}

UiTone _tone(Map<String, Object?> m, {UiTone fallback = UiTone.neutral}) {
  final v = m['tone'];
  if (v == null) return fallback;
  return switch (v) {
    'neutral' => UiTone.neutral,
    'info' => UiTone.info,
    'tip' => UiTone.tip,
    'good' || 'success' => UiTone.good,
    'warn' || 'warning' => UiTone.warn,
    'bad' || 'danger' => UiTone.bad,
    _ => throw UiSchemaError('unknown tone "$v"'),
  };
}

final _formatRe = RegExp(
  r'^(number:[0-6]|percent:[0-6]|currency:[A-Z]{3}|duration:min|[^{}]{0,24}\{\}[^{}]{0,24})$',
);

String? _format(Map<String, Object?> m) {
  final f = _optStr(m, 'format', max: 60);
  if (f == null) return null;
  if (!_formatRe.hasMatch(f)) throw UiSchemaError('unknown format "$f"');
  return f;
}

String? _url(Map<String, Object?> m, String key, {bool required = false}) {
  final v = m[key];
  if (v == null && !required) return null;
  final l = _str(v, key, max: 2000);
  final u = Uri.tryParse(l);
  if (u == null ||
      !(u.scheme == 'https' || u.scheme == 'http') ||
      u.host.isEmpty) {
    throw UiSchemaError('"$key" must be an http or https URL');
  }
  return l;
}

/// Parses one entity object (a block item, or the bridge's details answer).
UiEntity parseUiEntity(Object? j) {
  final m = _obj(j, 'entity');
  final facts = m['facts'] == null
      ? const <Object?>[]
      : _list(m, 'facts', 0, 8);
  final links = m['links'] == null
      ? const <Object?>[]
      : _list(m, 'links', 0, 4);
  final media = m['highlights'] == null
      ? const <Object?>[]
      : _list(m, 'highlights', 0, 8);
  return UiEntity(
    name: _label(m, 'name'),
    sub: _optStr(m, 'sub', max: 120),
    image: _url(m, 'image'),
    page: _url(m, 'page'),
    about: _optStr(m, 'about', max: 1200),
    facts: [
      for (final f in facts)
        () {
          final fm = _obj(f, 'fact');
          return UiFact(
            _label(fm, 'label'),
            _str(fm['value'], 'value', max: 120),
          );
        }(),
    ],
    links: [
      for (final l in links)
        () {
          final lm = _obj(l, 'link');
          return UiLink(_label(lm, 'label'), _url(lm, 'url', required: true)!);
        }(),
    ],
    highlights: [
      for (final h in media)
        () {
          final hm = _obj(h, 'highlight');
          return UiMedia(
            name: _label(hm, 'name'),
            sub: _optStr(hm, 'sub', max: UiLimits.maxLabel),
            image: _url(hm, 'image'),
          );
        }(),
    ],
    ask: _optStr(m, 'ask'),
  );
}

/// A state for dots and alerts: ok/up/healthy, warn/degraded, bad/down,
/// info, unknown.
UiTone _state(Map<String, Object?> m, String key) {
  final v = m[key];
  if (v == null) return UiTone.neutral;
  return switch (v) {
    'ok' || 'up' || 'healthy' || 'good' || 'success' || 'online' => UiTone.good,
    'warn' || 'warning' || 'degraded' || 'slow' => UiTone.warn,
    'bad' ||
    'down' ||
    'error' ||
    'critical' ||
    'danger' ||
    'offline' => UiTone.bad,
    'info' => UiTone.info,
    'unknown' || 'neutral' => UiTone.neutral,
    _ => throw UiSchemaError('unknown $key "$v"'),
  };
}

List<double> _numbers(Map<String, Object?> m, String key, int min, int max) {
  if (m[key] == null && min == 0) return const [];
  return [
    for (final v in _list(m, key, min, max))
      if (v is num && v.isFinite)
        v.toDouble()
      else
        throw UiSchemaError('"$key" must hold numbers'),
  ];
}

UiAction _action(Object? j) {
  final m = _obj(j, 'action');
  if (m.length != 1) throw UiSchemaError('an action has exactly one kind');
  if (m.containsKey('send')) return UiAction.send(_str(m['send'], 'send'));
  if (m.containsKey('copy')) return UiAction.copy(_str(m['copy'], 'copy'));
  if (m.containsKey('link')) {
    final l = _str(m['link'], 'link');
    final u = Uri.tryParse(l);
    final ok =
        u != null &&
        (((u.scheme == 'https' || u.scheme == 'http') && u.host.isNotEmpty) ||
            u.scheme == 'mailto');
    if (!ok) throw UiSchemaError('links must be http, https or mailto');
    return UiAction.link(l);
  }
  throw UiSchemaError('unknown action');
}

UiElement _element(Map<String, Object?> m, _Counter counter, int depth) {
  counter.add();
  final type = m['type'];
  if (type is! String) throw UiSchemaError('"type" is missing');
  final id = _id(m);
  switch (type) {
    case 'options':
      final many = switch (m['select']) {
        null || 'one' => false,
        'many' => true,
        _ => throw UiSchemaError('"select" must be "one" or "many"'),
      };
      return UiOptions(
        id: id,
        prompt: _optStr(m, 'prompt'),
        many: many,
        other: _bool(m, 'other'),
        options: [
          for (final o in _list(m, 'options', 2, 8))
            () {
              final om = _obj(o, 'option');
              final label = _label(om, 'label');
              final send = om['send'] == null
                  ? label
                  : _str(om['send'], 'send');
              return UiOption(label, send);
            }(),
        ],
      );
    case 'actions':
      final items = [
        for (final o in _list(m, 'items', 1, 3))
          () {
            final om = _obj(o, 'item');
            final style = om['style'];
            if (style != null && style != 'primary' && style != 'default') {
              throw UiSchemaError('unknown button style "$style"');
            }
            return UiButton(
              _label(om, 'label'),
              _action(om['action']),
              primary: style == 'primary',
            );
          }(),
      ];
      if (items.where((b) => b.primary).length > 1) {
        throw UiSchemaError('at most one primary button');
      }
      return UiActions(id: id, items: items);
    case 'cards':
      return UiCards(
        id: id,
        items: [
          for (final o in _list(m, 'items', 1, 4))
            () {
              final om = _obj(o, 'card');
              return UiCard(
                label: _label(om, 'label'),
                value: _str(om['value'], 'value', max: UiLimits.maxLabel),
                sub: _optStr(om, 'sub'),
                tone: _tone(om),
              );
            }(),
        ],
      );
    case 'calc':
      final inputs = [
        for (final o in _list(m, 'inputs', 1, 6)) _input(_obj(o, 'input')),
      ];
      final ids = inputs.map((i) => i.id).toSet();
      if (ids.length != inputs.length) {
        throw UiSchemaError('duplicate input id');
      }
      return UiCalc(
        id: id,
        inputs: inputs,
        outputs: [
          for (final o in _list(m, 'outputs', 1, 4))
            () {
              final om = _obj(o, 'output');
              final src = _str(om['expr'], 'expr', max: maxExprLength);
              final Expr e;
              try {
                e = Expr.parse(src, known: ids);
              } on ExprError catch (err) {
                throw UiSchemaError('expr "$src": ${err.message}');
              }
              return UiOutput(
                label: _label(om, 'label'),
                expr: e,
                source: src,
                format: _format(om),
                sub: _optStr(om, 'sub'),
                tone: _tone(om),
              );
            }(),
        ],
      );
    case 'details':
      return UiDetails(
        id: id,
        title: _label(m, 'title'),
        body: _str(m['body'], 'body', max: 2000),
        open: _bool(m, 'open'),
      );
    case 'callout':
      return UiCallout(
        id: id,
        tone: _tone(m, fallback: UiTone.info),
        title: _optStr(m, 'title', max: UiLimits.maxLabel),
        body: _str(m['body'], 'body', max: 1000),
      );
    case 'suggestions':
      return UiSuggestions(
        id: id,
        items: [
          for (final s in _list(m, 'items', 1, 3))
            _str(s, 'item', max: UiLimits.maxLabel),
        ],
      );
    case 'entities':
      return UiEntities(
        id: id,
        items: [for (final o in _list(m, 'items', 1, 6)) parseUiEntity(o)],
      );
    case 'news':
      return UiNews(
        id: id,
        items: [
          for (final o in _list(m, 'items', 1, 8))
            () {
              final om = _obj(o, 'item');
              return UiNewsItem(
                title: _str(om['title'], 'title', max: 200),
                url: _url(om, 'url', required: true)!,
                source: _optStr(om, 'source', max: UiLimits.maxLabel),
                date: _optStr(om, 'date', max: 40),
                image: _url(om, 'image'),
              );
            }(),
        ],
      );
    case 'checklist' || 'plan':
      UiCheckItem item(Object? o) {
        if (o is String) return UiCheckItem(_str(o, 'item', max: 120));
        final om = _obj(o, 'item');
        return UiCheckItem(
          _str(om['label'], 'label', max: 120),
          done: _bool(om, 'done'),
        );
      }
      final numbered = m['numbered'];
      if (numbered != null && numbered is! bool) {
        throw UiSchemaError('"numbered" must be true or false');
      }
      final List<UiCheckSection> sections;
      if (m['sections'] != null) {
        sections = [
          for (final o in _list(m, 'sections', 1, 8))
            () {
              final sm = _obj(o, 'section');
              final icon = _optStr(sm, 'icon', max: 20)?.toLowerCase();
              return UiCheckSection(
                title: numbered == false
                    ? _optStr(sm, 'title', max: UiLimits.maxLabel)
                    : _unnumbered(_optStr(sm, 'title', max: UiLimits.maxLabel)),
                time: _optStr(sm, 'time', max: 40),
                icon: icon,
                items: [for (final i in _list(sm, 'items', 1, 12)) item(i)],
              );
            }(),
        ];
      } else {
        sections = [
          UiCheckSection(
            items: [for (final i in _list(m, 'items', 1, 20)) item(i)],
          ),
        ];
      }
      final total = sections.fold(0, (n, s) => n + s.items.length);
      if (total > 40) throw UiSchemaError('more than 40 checklist items');
      return UiChecklist(
        id: id,
        title: _optStr(m, 'title', max: UiLimits.maxLabel),
        numbered: numbered != false,
        sections: sections,
      );
    case 'status':
      return UiStatus(
        id: id,
        title: _label(m, 'title'),
        state: _state(m, 'state'),
        summary: _optStr(m, 'summary', max: 200),
        updated: _optStr(m, 'updated', max: 40),
      );
    case 'metrics':
      return UiMetrics(
        id: id,
        items: [
          for (final o in _list(m, 'items', 1, 6))
            () {
              final om = _obj(o, 'metric');
              final v = om['value'];
              return UiMetric(
                label: _label(om, 'label'),
                value: v is num && v.isFinite
                    ? uiNumber(v.toDouble())
                    : _str(v, 'value', max: 24),
                unit: _optStr(om, 'unit', max: 16),
                delta: _optStr(om, 'delta', max: 24),
                tone: _tone(om),
                trend: _numbers(om, 'trend', 0, 48),
              );
            }(),
        ],
      );
    case 'gauges':
      return UiGauges(
        id: id,
        items: [
          for (final o in _list(m, 'items', 1, 6))
            () {
              final om = _obj(o, 'gauge');
              final max = _num(om, 'max', fallback: 100);
              if (!(max > 0)) throw UiSchemaError('"max" must be positive');
              return UiGauge(
                label: _label(om, 'label'),
                value: _num(om, 'value'),
                max: max,
                unit: om['unit'] == ''
                    ? ''
                    : _optStr(om, 'unit', max: 8) ?? (max == 100 ? '%' : ''),
                sub: _optStr(om, 'sub', max: UiLimits.maxLabel),
                tone: _tone(om),
              );
            }(),
        ],
      );
    case 'services':
      return UiServices(
        id: id,
        title: _optStr(m, 'title', max: UiLimits.maxLabel),
        items: [
          for (final o in _list(m, 'items', 1, 20))
            () {
              final om = _obj(o, 'service');
              final lat = om['latency'];
              return UiService(
                name: _label(om, 'name'),
                state: _state(om, 'state'),
                latency: lat is num && lat.isFinite
                    ? '${uiNumber(lat.toDouble())} ms'
                    : _optStr(om, 'latency', max: 16),
                sub: _optStr(om, 'sub', max: 120),
                ask: _optStr(om, 'ask'),
              );
            }(),
        ],
      );
    case 'alerts':
      return UiAlerts(
        id: id,
        items: [
          for (final o in _list(m, 'items', 1, 8))
            () {
              final om = _obj(o, 'alert');
              final actions = om['actions'] == null
                  ? const <Object?>[]
                  : _list(om, 'actions', 0, 2);
              return UiAlert(
                tone: _state(om, 'tone'),
                title: _str(om['title'], 'title', max: 120),
                body: _optStr(om, 'body'),
                time: _optStr(om, 'time', max: 40),
                actions: [
                  for (final a in actions)
                    () {
                      final am = _obj(a, 'action');
                      return UiButton(
                        _label(am, 'label'),
                        UiAction.send(_str(am['send'], 'send')),
                      );
                    }(),
                ],
              );
            }(),
        ],
      );
    case 'chart':
      final kind = switch (m['kind']) {
        null || 'line' => UiChartKind.line,
        'bar' => UiChartKind.bar,
        final k => throw UiSchemaError('unknown chart kind "$k"'),
      };
      final series = [
        for (final o in _list(m, 'series', 1, 3))
          () {
            final om = _obj(o, 'series');
            return UiSeries(
              name: _optStr(om, 'name', max: UiLimits.maxLabel) ?? '',
              values: _numbers(om, 'values', 1, 60),
              tone: om['tone'] == null ? null : _tone(om),
            );
          }(),
      ];
      return UiChart(
        id: id,
        kind: kind,
        title: _optStr(m, 'title', max: UiLimits.maxLabel),
        unit: _optStr(m, 'unit', max: 16),
        labels: m['labels'] == null
            ? const []
            : [
                for (final l in _list(m, 'labels', 0, 60))
                  _str(l, 'label', max: 24),
              ],
        series: series,
      );
    case 'html':
      return UiHtml(id: id, html: _str(m['html'], 'html', max: 12000));
    case 'group':
      if (depth >= UiLimits.maxDepth) {
        throw UiSchemaError('groups cannot be nested');
      }
      return UiGroup(
        id: id,
        title: _optStr(m, 'title', max: UiLimits.maxLabel),
        children: [
          for (final c in _list(m, 'children', 1, UiLimits.maxElements))
            () {
              final cm = _obj(c, 'child');
              if (cm['type'] == 'suggestions') {
                throw UiSchemaError('suggestions cannot be in a group');
              }
              return _element(cm, counter, depth + 1);
            }(),
        ],
      );
  }
  throw UiSchemaError('unknown type "$type"');
}

UiInput _input(Map<String, Object?> m) {
  final id = m['id'];
  if (id is! String || !_idRe.hasMatch(id)) {
    throw UiSchemaError('an input needs an "id" matching [a-z0-9-]{1,32}');
  }
  final kind = switch (m['kind']) {
    null || 'slider' => UiInputKind.slider,
    'stepper' => UiInputKind.stepper,
    'toggle' => UiInputKind.toggle,
    'segmented' => UiInputKind.segmented,
    final k => throw UiSchemaError('unknown input kind "$k"'),
  };
  final label = _label(m, 'label');
  final format = _format(m);
  switch (kind) {
    case UiInputKind.toggle:
      final v = m['value'];
      final on = v == true || v == 1;
      return UiInput(
        id: id,
        kind: kind,
        label: label,
        min: 0,
        max: 1,
        step: 1,
        value: on ? 1 : 0,
        format: format,
      );
    case UiInputKind.segmented:
      final segs = [
        for (final o in _list(m, 'options', 2, 4))
          () {
            final om = _obj(o, 'option');
            return UiSegment(_label(om, 'label'), _num(om, 'value'));
          }(),
      ];
      final value = _num(m, 'value', fallback: segs.first.value);
      if (!segs.any((s) => s.value == value)) {
        throw UiSchemaError('"value" must be one of the options');
      }
      return UiInput(
        id: id,
        kind: kind,
        label: label,
        value: value,
        format: format,
        segments: segs,
      );
    case UiInputKind.slider || UiInputKind.stepper:
      final min = _num(m, 'min');
      final max = _num(m, 'max');
      final step = _num(m, 'step', fallback: 1);
      if (!(max > min)) throw UiSchemaError('"max" must be above "min"');
      if (!(step > 0)) throw UiSchemaError('"step" must be positive');
      if ((max - min) / step > 10000) throw UiSchemaError('too many steps');
      final value = _num(m, 'value', fallback: min).clamp(min, max).toDouble();
      return UiInput(
        id: id,
        kind: kind,
        label: label,
        min: min,
        max: max,
        step: step,
        value: value,
        format: format,
      );
  }
}
