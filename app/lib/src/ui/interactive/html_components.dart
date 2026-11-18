// Round 7 components for hermes-html, chosen by class (see html_view.dart).
// Everything is drawn natively with the reply's own type and colours (the
// blend rule: no fills; 1 px outlines group, colour only shows state).
// Nothing here runs code: buttons only send their `data-send` text as the
// user's message, links go through the confirm sheet, and pictures load
// through the bridge.
part of 'html_view.dart';

/// True for an element drawn by a component rather than as plain layout.
bool isHtmlComponent(HElement e) {
  if (const {'details', 'dl', 'progress', 'button'}.contains(e.tag)) {
    return true;
  }
  if (e.tag == 'a') return _isButton(e);
  if (e.has('bar')) return _barValue(e) != null;
  return const [
    'tabs', 'stats', 'timeline', 'pros', 'cons', 'callout', 'gallery', //
    'card', 'cards', 'hero',
  ].any(e.has);
}

/// The widget for a layout element or component.
Widget htmlElement(HElement e, MarkdownStyle s) {
  if (_isButton(e)) return HtmlButtons(buttons: [e], style: s);
  if (e.tag == 'progress' || e.has('bar') && _barValue(e) != null) {
    return HtmlBar(element: e, style: s);
  }
  if (e.tag == 'dl') return _HtmlSpecs(element: e, style: s);
  if (e.tag == 'details') return _details(e, s);
  if (e.has('tabs')) {
    final panes = HtmlTabs.panesOf(e);
    if (panes.length >= 2) return HtmlTabs(panes: panes, style: s);
  }
  if (e.has('stats')) {
    final cards = htmlStats(e);
    if (cards.isNotEmpty) return UiCardsView(cards: cards, style: s);
  }
  if (e.has('timeline')) return HtmlTimeline(element: e, style: s);
  if (e.has('pros') || e.has('cons')) {
    return _HtmlProsCons(element: e, style: s);
  }
  if (e.has('callout')) return _callout(e, s);
  if (e.has('gallery')) {
    final imgs = _descendants(e).where((x) => x.tag == 'img').toList();
    if (imgs.isNotEmpty) {
      // A paragraph of images: side by side or a strip; tap opens the
      // full-screen viewer (pinch to zoom).
      return HermesMarkdown(
        text: imgs.map((i) => _image(i.attrs)).join('\n'),
        style: s,
      );
    }
  }
  if (e.has('hero')) return _HtmlHero(element: e, style: s);
  if (e.has('card') && !e.has('cards')) return HtmlCard(element: e, style: s);
  if (_layoutTags.contains(e.tag) || e.has('cards')) {
    return _HtmlBox(element: e, style: s);
  }
  final md = flowMarkdown([e]).trim();
  return md.isEmpty
      ? const SizedBox.shrink()
      : HermesMarkdown(text: md, style: s);
}

Iterable<HElement> _descendants(HElement e) sync* {
  for (final c in e.children.whereType<HElement>()) {
    yield c;
    yield* _descendants(c);
  }
}

String? _textOf(HNode? n) {
  if (n == null) return null;
  final t = (n is HText ? n.text : (n as HElement).text)
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return t.isEmpty ? null : t;
}

bool _isHeading(HNode n) =>
    n is HElement && const {'h1', 'h2', 'h3', 'h4'}.contains(n.tag);

bool _hasContent(List<HNode> nodes) =>
    nodes.any((n) => n is HElement || (n as HText).text.trim().isNotEmpty);

double _lineHeight(BuildContext context, TextStyle t) =>
    MediaQuery.textScalerOf(context).scale(t.fontSize ?? 17) *
    (t.height ?? 1.5);

// ---------------------------------------------------------------- cards

/// A card: an optional cover picture edge to edge on top (tap to zoom), then
/// its title, meta line and text inside a light 1 px outline.
class HtmlCard extends StatelessWidget {
  const HtmlCard({super.key, required this.element, required this.style});
  final HElement element;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final kids = element.children;
    final cover = kids
        .whereType<HElement>()
        .where((c) => c.tag == 'img')
        .firstOrNull;
    final rest = [
      for (final c in kids)
        if (!identical(c, cover))
          // A card's title is bold body text, not a reply heading.
          _isHeading(c)
              ? HElement(
                  'p',
                  style: (c as HElement).style,
                  children: [HElement('strong', children: c.children)],
                )
              : c,
    ];
    final radius = BorderRadius.circular(s.frameRadius + 4);
    return Semantics(
      container: true,
      child: Container(
        foregroundDecoration: BoxDecoration(
          border: Border.all(color: s.outline),
          borderRadius: radius,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (cover != null)
                LayoutBuilder(
                  builder: (context, c) {
                    final w = c.maxWidth;
                    return HtmlCover(
                      image: cover,
                      width: w,
                      height: (w * 0.62).clamp(110.0, 220.0),
                      radius: 0,
                      style: s,
                    );
                  },
                ),
              if (_hasContent(rest))
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                  child: _HtmlBlocks(nodes: rest, style: s),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A picture in a fixed frame, loaded through the bridge; tapping it opens
/// the full-screen viewer.
class HtmlCover extends StatelessWidget {
  const HtmlCover({
    super.key,
    required this.image,
    required this.width,
    required this.height,
    required this.style,
    this.radius = 12,
  });

  final HElement image;
  final double width, height, radius;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final src = image.attrs['src']!;
    final alt = image.attrs['alt'] ?? '';
    final loader = MarkdownImageScope.of(context);
    final pic = UiRemoteImage(
      url: src,
      width: width,
      height: height,
      radius: radius,
      style: style,
    );
    if (loader == null) {
      return Semantics(image: true, label: alt, child: pic);
    }
    final actions = UiActionHandler.of(context);
    return Semantics(
      image: true,
      button: true,
      label: alt.isEmpty ? 'Image' : alt,
      hint: 'Opens the image',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => showMdImageViewer(
            context,
            images: [MdImage(src: src, alt: alt)],
            initial: 0,
            loader: loader,
            style: style,
            onLinkTap: actions.openLink,
          ),
          child: pic,
        ),
      ),
    );
  }
}

/// A hero: a wide cover picture, then the title, lead and key stats.
class _HtmlHero extends StatelessWidget {
  const _HtmlHero({required this.element, required this.style});
  final HElement element;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final cover = element.children
        .whereType<HElement>()
        .where((c) => c.tag == 'img')
        .firstOrNull;
    final rest = [
      for (final c in element.children)
        if (!identical(c, cover)) c,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (cover != null) ...[
          LayoutBuilder(
            builder: (context, c) => HtmlCover(
              image: cover,
              width: c.maxWidth,
              height: (c.maxWidth * 0.5).clamp(140.0, 240.0),
              radius: style.frameRadius + 4,
              style: style,
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (_hasContent(rest)) _HtmlBlocks(nodes: rest, style: style),
      ],
    );
  }
}

// ---------------------------------------------------------------- stats

/// Stat tiles from `.stats` children: a `.value` (or the first bold text or
/// heading), a `.label` (or `<small>`) and an optional `.sub`; a tone class
/// colours the value.
List<UiCard> htmlStats(HElement e) {
  final out = <UiCard>[];
  for (final c in e.children.whereType<HElement>().take(8)) {
    final all = [c, ..._descendants(c)];
    HElement? find(bool Function(HElement) f) => all.where(f).firstOrNull;
    final labelEl =
        find((x) => x.has('label')) ??
        find((x) => x.tag == 'small' || x.tag == 'figcaption');
    final valueEl =
        find((x) => x.has('value')) ??
        find((x) => x.tag == 'strong' || _isHeading(x));
    final subEl = find((x) => (x.has('sub') || x.has('meta')) && x != labelEl);
    final label = _textOf(labelEl);
    var value = _textOf(valueEl);
    if (value == null) {
      final whole = _textOf(c) ?? '';
      value = label == null ? whole : whole.replaceFirst(label, '').trim();
    }
    if (value.isEmpty) continue;
    final tone =
        htmlTone(c.classes) ??
        (valueEl == null ? null : htmlTone(valueEl.classes)) ??
        valueEl?.children.whereType<HText>().firstOrNull?.tone;
    out.add(
      UiCard(
        label: label ?? '',
        value: value,
        sub: _textOf(subEl),
        tone: tone ?? UiTone.neutral,
      ),
    );
  }
  return out;
}

// ----------------------------------------------------------------- bars

double? _barValue(HElement e) =>
    double.tryParse(e.attrs['data-value'] ?? e.attrs['value'] ?? '');

String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// A progress bar: label and value on one line, then a slim track whose
/// fill grows in once (tone classes colour it).
class HtmlBar extends StatelessWidget {
  const HtmlBar({super.key, required this.element, required this.style});
  final HElement element;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final e = element;
    final value = _barValue(e) ?? 0;
    var max = double.tryParse(e.attrs['data-max'] ?? e.attrs['max'] ?? '');
    if (max == null || max <= 0) max = 100;
    final frac = (value / max).clamp(0.0, 1.0);
    final shown = max == 100
        ? '${_num(value)}%'
        : '${_num(value)} / ${_num(max)}';
    final label = e.tag == 'progress' ? '' : _inline(e.children).trim();
    final plain = _textOf(e) ?? '';
    final color = dashTone(
      htmlTone(e.classes) ?? UiTone.neutral,
      s,
      neutral: s.text,
    );
    return Semantics(
      container: true,
      label: plain.isEmpty ? shown : '$plain: $shown',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: label.isEmpty
                      ? const SizedBox.shrink()
                      : HermesMarkdown(text: label, style: s),
                ),
                const SizedBox(width: 12),
                Text(
                  shown,
                  style: s.caption.copyWith(
                    color: s.textMuted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 6,
                child: ColoredBox(
                  color: s.hairline,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: frac),
                    duration: Motion.of(
                      context,
                      const Duration(milliseconds: 600),
                    ),
                    curve: Curves.easeOutCubic,
                    builder: (context, v, _) => FractionallySizedBox(
                      alignment: AlignmentDirectional.centerStart,
                      widthFactor: v,
                      heightFactor: 1,
                      child: ColoredBox(color: color),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- timeline

/// A vertical timeline: a ring per item on a hairline rail, an optional
/// `.time` caption, then the item's content.
class HtmlTimeline extends StatelessWidget {
  const HtmlTimeline({super.key, required this.element, required this.style});
  final HElement element;
  final MarkdownStyle style;

  List<HElement> get items {
    final e = element;
    // `<div class="timeline"><ol>…</ol></div>` too.
    final list = e.tag == 'ul' || e.tag == 'ol'
        ? e
        : e.children
                  .whereType<HElement>()
                  .where((c) => c.tag == 'ul' || c.tag == 'ol')
                  .length ==
              1
        ? e.children.whereType<HElement>().firstWhere(
            (c) => c.tag == 'ul' || c.tag == 'ol',
          )
        : e;
    return list.children.whereType<HElement>().toList();
  }

  @override
  Widget build(BuildContext context) {
    final s = style;
    final its = items;
    final bodyLine = _lineHeight(context, s.body);
    final capLine = _lineHeight(context, s.caption);
    const dot = 10.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, item) in its.indexed)
          () {
            final time = item.children
                .whereType<HElement>()
                .where((c) => c.has('time'))
                .firstOrNull;
            final rest = [
              for (final c in item.children)
                if (!identical(c, time)) c,
            ];
            final tone = htmlTone(item.classes);
            final ring = tone == null
                ? s.text
                : dashTone(tone, s, neutral: s.text);
            final top = ((time != null ? capLine : bodyLine) - dot) / 2;
            final last = i == its.length - 1;
            return Semantics(
              container: true,
              child: Stack(
                children: [
                  if (i > 0 && top > 2)
                    Positioned(
                      left: dot / 2 - 0.5,
                      top: 0,
                      height: top - 2,
                      width: 1,
                      child: ColoredBox(color: s.outline),
                    ),
                  if (!last)
                    Positioned(
                      left: dot / 2 - 0.5,
                      top: top + dot + 2,
                      bottom: 0,
                      width: 1,
                      child: ColoredBox(color: s.outline),
                    ),
                  Positioned(
                    left: 0,
                    top: top,
                    child: Container(
                      width: dot,
                      height: dot,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: tone == null ? s.background : ring,
                        border: Border.all(color: ring, width: 2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(left: 26, bottom: last ? 0 : 18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_textOf(time) case final t?)
                          Text(
                            t,
                            style: s.caption.copyWith(color: s.textMuted),
                          ),
                        if (_hasContent(rest))
                          _HtmlBlocks(nodes: rest, style: s),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }(),
      ],
    );
  }
}

// ------------------------------------------------------------ pros/cons

/// A pros or cons list: a title with a thumb, and a check or a cross before
/// each item in the success or danger colour.
class _HtmlProsCons extends StatelessWidget {
  const _HtmlProsCons({required this.element, required this.style});
  final HElement element;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final e = element;
    final pros = e.has('pros');
    final color = pros ? s.success : s.danger;
    final items = <List<HNode>>[];
    final other = <HNode>[];
    String? title;
    void walk(HElement list) {
      for (final li in list.children.whereType<HElement>()) {
        if (li.tag == 'li') items.add(li.children);
      }
    }

    if (e.tag == 'ul' || e.tag == 'ol') {
      walk(e);
    } else {
      for (final c in e.children) {
        if (title == null && _isHeading(c)) {
          title = _textOf(c);
        } else if (c is HElement && (c.tag == 'ul' || c.tag == 'ol')) {
          walk(c);
        } else if (_hasContent([c])) {
          other.add(c);
        }
      }
    }
    final scaler = MediaQuery.textScalerOf(context);
    final icon = scaler.scale(18);
    final line = _lineHeight(context, s.body);
    final dy = ((line - icon) / 2).clamp(0.0, 20.0);
    return Semantics(
      container: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                pros
                    ? Icons.thumb_up_alt_outlined
                    : Icons.thumb_down_alt_outlined,
                size: icon,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title ?? (pros ? 'Pros' : 'Cons'),
                    style: s.bodyStrong,
                  ),
                ),
              ),
            ],
          ),
          if (other.isNotEmpty) ...[
            const SizedBox(height: 6),
            _HtmlBlocks(nodes: other, style: s),
          ],
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(top: dy),
                    child: Semantics(
                      label: pros ? 'Pro' : 'Con',
                      child: Icon(
                        pros ? Icons.check_rounded : Icons.close_rounded,
                        size: icon,
                        color: color,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: HermesMarkdown(
                      text: flowMarkdown(item).replaceAll('\n\n', ' ').trim(),
                      style: s,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------- callout

Widget _callout(HElement e, MarkdownStyle s) {
  final heading = e.children.where(_isHeading).firstOrNull;
  return UiCalloutView(
    element: UiCallout(
      tone: htmlTone(e.classes) ?? UiTone.info,
      title: _textOf(heading),
      body: flowMarkdown([
        for (final c in e.children)
          if (!identical(c, heading)) c,
      ]),
    ),
    style: s,
  );
}

// -------------------------------------------------------------- details

/// An accordion; its body may hold any component.
Widget _details(HElement e, MarkdownStyle s) {
  final summary = e.children
      .whereType<HElement>()
      .where((c) => c.tag == 'summary')
      .firstOrNull;
  final rest = [
    for (final c in e.children)
      if (!identical(c, summary)) c,
  ];
  return UiDetailsView(
    title: _textOf(summary) ?? 'Details',
    initiallyOpen: e.attrs.containsKey('open'),
    style: s,
    body: _HtmlBlocks(nodes: rest, style: s),
  );
}

// ---------------------------------------------------------------- specs

/// A spec sheet (`dl`): the term muted on the left, the value on the right,
/// hairlines between rows.
class _HtmlSpecs extends StatelessWidget {
  const _HtmlSpecs({required this.element, required this.style});
  final HElement element;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final rows = <(String, List<String>)>[];
    for (final c in element.children.whereType<HElement>()) {
      if (c.tag == 'dt') {
        rows.add((_textOf(c) ?? '', []));
      } else if (c.tag == 'dd') {
        final v = _inline(c.children).trim();
        if (v.isEmpty) continue;
        if (rows.isEmpty) rows.add(('', []));
        rows.last.$2.add(v);
      }
    }
    final shown = rows.where((r) => r.$2.isNotEmpty || r.$1.isNotEmpty);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, (term, values)) in shown.indexed) ...[
          if (i > 0) Divider(height: 1, thickness: 1, color: s.hairline),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Semantics(
              container: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: Text(
                      term,
                      style: s.body.copyWith(color: s.textMuted),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: HermesMarkdown(text: values.join('\n\n'), style: s),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ----------------------------------------------------------------- tabs

/// Tabs: a row of pills (wrapping when narrow or at large text) above the
/// selected pane, which fades in while the height eases to fit.
class HtmlTabs extends StatefulWidget {
  const HtmlTabs({super.key, required this.panes, required this.style});

  final List<(String, List<HNode>)> panes;
  final MarkdownStyle style;

  /// The panes of a `.tabs` element: each child element, labelled by its
  /// `data-tab`, else its first heading (then not repeated in the pane).
  static List<(String, List<HNode>)> panesOf(HElement e) {
    final out = <(String, List<HNode>)>[];
    for (final c in e.children.whereType<HElement>()) {
      if (out.length >= HtmlLimits.maxTabs) break;
      var label = c.attrs['data-tab'];
      var body = c.children;
      if (label == null) {
        final h = c.children.where(_isHeading).firstOrNull;
        if (h != null) {
          label = cleanText(_textOf(h) ?? '', HtmlLimits.maxTabLabel);
          body = [
            for (final x in c.children)
              if (!identical(x, h)) x,
          ];
        }
      }
      if (label == null || label.isEmpty) label = 'Part ${out.length + 1}';
      out.add((label, body));
    }
    return out;
  }

  @override
  State<HtmlTabs> createState() => _HtmlTabsState();
}

class _HtmlTabsState extends State<HtmlTabs> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    final panes = widget.panes;
    final i = _i.clamp(0, panes.length - 1);
    final actions = UiActionHandler.of(context);
    var size = Motion.spatial(context, const Duration(milliseconds: 220));
    // A zero-duration AnimatedSize asserts when the size changes.
    if (size == Duration.zero) size = const Duration(microseconds: 1);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          container: true,
          explicitChildNodes: true,
          child: Wrap(
            spacing: 8,
            children: [
              for (final (j, (label, _)) in panes.indexed)
                UiPill(
                  label: label,
                  style: s,
                  quiet: true,
                  selected: j == i,
                  height: 36,
                  horizontalPadding: 14,
                  semanticsSelected: j == i,
                  semanticsHint: 'Shows this tab',
                  onTap: () {
                    if (j == _i) return;
                    actions.selectionHaptic();
                    setState(() => _i = j);
                  },
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        AnimatedSize(
          duration: size,
          curve: Motion.spatialCurve(context, Motion.emphasizedDecel),
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: Motion.of(context, const Duration(milliseconds: 180)),
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              fit: StackFit.passthrough,
              children: [...previous, ?current],
            ),
            child: KeyedSubtree(
              key: ValueKey<int>(i),
              child: _HtmlBlocks(nodes: panes[i].$2, style: s),
            ),
          ),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------- buttons

/// Buttons in one wrap. `<button data-send>` posts its text as the user's
/// message (once; locked after the user replies), `<a class="button">`
/// opens its link through the confirm sheet. Nothing else can happen.
class HtmlButtons extends StatefulWidget {
  const HtmlButtons({super.key, required this.buttons, required this.style});
  final List<HElement> buttons;
  final MarkdownStyle style;

  @override
  State<HtmlButtons> createState() => _HtmlButtonsState();
}

class _HtmlButtonsState extends State<HtmlButtons> {
  final _sent = <int>{};

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    final actions = UiActionHandler.of(context);
    final next = actions.nextUserMessage?.trim();
    return Wrap(
      spacing: 8,
      children: [
        for (final (i, b) in widget.buttons.indexed)
          if (b.tag == 'button')
            () {
              final send = b.attrs['data-send']!;
              final label = cleanText(_textOf(b) ?? send, 60);
              final chosen = _sent.contains(i) || next == send;
              // One follow-up per reply: after a tap the group locks.
              final locked = _sent.isNotEmpty || next != null;
              return UiPill(
                label: label,
                style: s,
                quiet: true,
                selected: locked && chosen,
                dimmed: locked && !chosen,
                height: 44,
                horizontalPadding: 18,
                semanticsHint: 'Sends "$send"',
                onTap: locked || !actions.canSend
                    ? null
                    : () {
                        // Two taps inside one frame must not send twice.
                        if (_sent.contains(i)) return;
                        setState(() => _sent.add(i));
                        actions.send(send);
                      },
              );
            }()
          else
            UiPill(
              label: cleanText(_textOf(b) ?? 'Open', 60),
              style: s,
              quiet: true,
              height: 44,
              horizontalPadding: 18,
              trailing: Icons.north_east_rounded,
              semanticsHint: 'Opens a link',
              onTap: () => actions.openLink(b.attrs['href']!),
            ),
      ],
    );
  }
}
