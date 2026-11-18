/// Entity cards, news lists and the entity details sheet (round 3).
///
/// Pictures load through the bridge like markdown images
/// ([MarkdownImageScope]); without a loader, cards show the name's letter
/// and news rows show no thumbnail. Nothing here fetches a remote URL
/// itself.
library;

import 'package:material_ui/material_ui.dart';

import '../common/floating_sheet.dart';
import '../markdown/favicons.dart';
import '../markdown/footnotes.dart';
import '../markdown/hermes_markdown.dart';
import '../markdown/entity_info.dart';
import '../markdown/md_images.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'scope.dart';
import 'ui_model.dart';
import 'ui_widgets.dart' show UiPill;

// ------------------------------------------------------------ pictures

/// A remote picture in a fixed [width] × [height] frame, filled edge to
/// edge. Loading and failed states keep the frame, so nothing jumps.
class UiRemoteImage extends StatefulWidget {
  const UiRemoteImage({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    required this.style,
    this.radius = 14,
    this.letter,
    this.entityName,
    this.entityHint,
    this.pageUrl,
    this.collapseWhenEmpty = false,
    this.gap = 0,
  });

  final String? url;

  /// No [url]: the picture of this entity from the bridge's entity info
  /// (round 8; Hermes rarely has image URLs for entities).
  final String? entityName, entityHint;

  /// No [url]: this page's preview picture (a news article's og:image).
  final String? pageUrl;

  /// Takes no space (and no [gap]) once it is known there is no picture.
  final bool collapseWhenEmpty;

  /// Space after the picture, on its right, only while it shows.
  final double gap;
  final double width, height, radius;
  final MarkdownStyle style;

  /// Shown when there is no picture (an entity's initial).
  final String? letter;

  @override
  State<UiRemoteImage> createState() => _UiRemoteImageState();
}

class _UiRemoteImageState extends State<UiRemoteImage> {
  LinkImageResult? _result;
  MarkdownImageLoader? _loader;
  String? _url;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(UiRemoteImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _resolve();
  }

  void _resolve() {
    final loader = MarkdownImageScope.of(context);
    final url = widget.url;
    final page = widget.pageUrl, name = widget.entityName;
    final key =
        url ??
        (page != null
            ? 'page:$page'
            : name != null
            ? 'entity:$name'
            : null);
    if (key == _url && identical(loader, _loader)) return;
    _url = key;
    _loader = loader;
    _result = null;
    if (loader == null || key == null) return;
    void done(LinkImageResult r) {
      if (mounted && _url == key) setState(() => _result = r);
    }

    if (url != null) {
      final hit = loader.peek(url);
      if (hit != null) {
        _result = hit;
        return;
      }
      loader.load(url).then(done);
    } else if (page != null && loader is PageImageSource) {
      final pages = loader as PageImageSource;
      final hit = pages.peekPageImage(page);
      if (hit != null) {
        _result = hit;
        return;
      }
      pages.loadPageImage(page).then(done);
    } else if (name != null && loader is EntityInfoSource) {
      final infos = loader as EntityInfoSource;
      Future<void> picture(EntityInfo? info) async {
        final src = info?.image ?? info?.originalImage;
        if (src == null) return done(const LinkImageResult(null));
        final hit = loader.peek(src);
        if (hit != null) return done(hit);
        done(await loader.load(src));
      }

      final known = infos.peekEntityInfo(name, hint: widget.entityHint);
      final src = known?.image ?? known?.originalImage;
      final hit = src == null ? null : loader.peek(src);
      if (hit != null) {
        _result = hit;
        return;
      }
      infos.entityInfo(name, hint: widget.entityHint).then(picture);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    final image = _result?.image;
    final reduced = Motion.reduced(context);
    Widget content;
    if (image != null) {
      final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2;
      final aspect = image.aspect;
      // Decode only what the frame shows (cover: the longer side fills).
      final need = aspect == null
          ? widget.width * 1.5
          : (widget.height * aspect > widget.width
                ? widget.height * aspect
                : widget.width);
      content = Image(
        image: ResizeImage.resizeIfNeeded(
          (need * dpr).ceil().clamp(1, 2048),
          null,
          MemoryImage(image.bytes),
        ),
        fit: BoxFit.cover,
        width: widget.width,
        height: widget.height,
        gaplessPlayback: true,
        excludeFromSemantics: true,
        filterQuality: FilterQuality.medium,
        frameBuilder: (context, child, frame, sync) {
          if (sync || reduced) return child;
          return AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: const Duration(milliseconds: 180),
            child: child,
          );
        },
        errorBuilder: (context, error, stack) => _empty(s),
      );
    } else {
      if (widget.collapseWhenEmpty && _result != null) {
        return const SizedBox.shrink();
      }
      content = _empty(s);
    }
    if (widget.collapseWhenEmpty && _result == null) {
      // Unknown yet: no frame, so a row without a picture never jumps.
      return const SizedBox.shrink();
    }
    final frame = Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: s.surfaceHigh,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
    return widget.gap > 0
        ? Padding(
            padding: EdgeInsets.only(right: widget.gap),
            child: frame,
          )
        : frame;
  }

  Widget _empty(MarkdownStyle s) {
    final letter = widget.letter;
    if (letter == null || letter.isEmpty) return const SizedBox.expand();
    return Center(
      child: Text(
        letter.characters.first.toUpperCase(),
        textScaler: TextScaler.noScaling,
        style: s.h2.copyWith(
          color: s.textMuted,
          fontSize: (widget.height * 0.32).clamp(14.0, 48.0),
          height: 1,
        ),
      ),
    );
  }
}

/// A tappable, focusable region with button semantics.
class _Tap extends StatelessWidget {
  const _Tap({
    required this.label,
    required this.onTap,
    required this.child,
    this.hint,
    this.link = false,
  });

  final String label;
  final String? hint;
  final bool link;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: !link,
    link: link,
    label: label,
    hint: hint,
    onTap: onTap,
    excludeSemantics: true,
    child: FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: child,
      ),
    ),
  );
}

// ------------------------------------------------------------ entities

/// A row of entity cards (reference: two portraits side by side, the name
/// underlined in bold and a muted sub-line). One or two cards share the row
/// in halves; three or more scroll sideways with the next card peeking.
/// Tapping a card opens [showEntitySheet].
class UiEntitiesView extends StatelessWidget {
  const UiEntitiesView({super.key, required this.element, required this.style});

  final UiEntities element;
  final MarkdownStyle style;

  static const gap = 12.0;

  /// The square picture's side for a card in a row [width] wide.
  static double tileWidth(double width, int count) => count <= 2
      ? ((width - gap) / 2).clamp(120.0, 320.0)
      : (width * 0.42).clamp(132.0, 240.0);

  @override
  Widget build(BuildContext context) {
    final items = element.items;
    return Semantics(
      container: true,
      label: items.length > 1 ? '${items.length} cards' : null,
      child: LayoutBuilder(
        builder: (context, box) {
          final tw = tileWidth(box.maxWidth, items.length);
          Widget card(UiEntity e) => SizedBox(
            width: tw,
            child: UiEntityCard(entity: e, width: tw, style: style),
          );
          final row = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(width: gap),
                card(items[i]),
              ],
            ],
          );
          if (items.length <= 2) return row;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: row,
          );
        },
      ),
    );
  }
}

/// One entity card: square picture, bold underlined name, sub-line.
class UiEntityCard extends StatelessWidget {
  const UiEntityCard({
    super.key,
    required this.entity,
    required this.width,
    required this.style,
  });

  final UiEntity entity;
  final double width;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final e = entity;
    final nameStyle = s.bodyStrong.copyWith(
      decoration: TextDecoration.underline,
      decorationColor: s.text.withValues(alpha: 0.55),
      decorationThickness: 1,
    );
    return _Tap(
      label: [e.name, ?e.sub].join(', '),
      hint: 'Opens details',
      onTap: () => showEntitySheet(context, e, style: s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          UiRemoteImage(
            url: e.image,
            entityName: e.image == null ? e.name : null,
            entityHint: e.sub,
            width: width,
            height: width,
            style: s,
            letter: e.name,
          ),
          const SizedBox(height: 10),
          Text(
            e.name,
            style: nameStyle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (e.sub != null) ...[
            const SizedBox(height: 2),
            Text(
              e.sub!,
              style: s.caption.copyWith(color: s.textMuted),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ news

/// A news list (reference "Latest news"): per article a rounded square
/// thumbnail, the headline as a dotted-underlined link with ↗, and
/// "Publisher · date" in muted caption text; hairlines between articles.
/// The headline opens the link confirm; the thumbnail opens the viewer.
class UiNewsView extends StatelessWidget {
  const UiNewsView({super.key, required this.element, required this.style});

  final UiNews element;
  final MarkdownStyle style;

  /// Thumbnail side for a list [width] wide (107 dp on the reference phone,
  /// 100 on its desktop).
  static double thumb(double width) => (width * 0.26).clamp(72.0, 104.0);

  @override
  Widget build(BuildContext context) {
    final s = style;
    final items = element.items;
    return LayoutBuilder(
      builder: (context, box) {
        final side = thumb(box.maxWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Divider(height: 1, thickness: 1, color: s.hairline),
                ),
              _NewsRow(item: items[i], side: side, style: s),
            ],
          ],
        );
      },
    );
  }
}

class _NewsRow extends StatelessWidget {
  const _NewsRow({required this.item, required this.side, required this.style});

  final UiNewsItem item;
  final double side;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final handler = UiActionHandler.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final title = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: item.title),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(
                Icons.north_east_rounded,
                size: scaler.scale(14),
                color: s.textMuted,
              ),
            ),
          ),
        ],
      ),
      textScaler: scaler,
      style: s.body.copyWith(
        decoration: TextDecoration.underline,
        decorationStyle: TextDecorationStyle.dotted,
        decorationColor: s.textMuted,
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
    final text = _Tap(
      link: true,
      label: [item.title, if (item.byline.isNotEmpty) item.byline].join(', '),
      onTap: () => handler.openLink(item.url),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          title,
          if (item.byline.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              item.byline,
              style: s.caption.copyWith(color: s.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
    final loader = MarkdownImageScope.of(context);
    if (loader == null) return text;
    if (item.image == null) {
      // Round 8: the article's own preview picture, shown once found.
      if (loader is! PageImageSource) return text;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: UiRemoteImage(
              url: null,
              pageUrl: item.url,
              width: side,
              height: side,
              style: s,
              radius: 12,
              collapseWhenEmpty: true,
              gap: 12,
            ),
          ),
          Expanded(child: text),
        ],
      );
    }
    final picture = _Tap(
      label: 'Picture for ${item.title}',
      hint: 'Opens the image',
      onTap: () => showMdImageViewer(
        context,
        images: [MdImage(src: item.image!, alt: item.title, source: item.url)],
        initial: 0,
        loader: loader,
        style: s,
        onLinkTap: handler.openLink,
      ),
      child: UiRemoteImage(
        url: item.image,
        width: side,
        height: side,
        style: s,
        radius: 12,
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        picture,
        const SizedBox(width: 12),
        Expanded(child: text),
      ],
    );
  }
}

// ------------------------------------------------------------ details sheet

/// Opens the details sheet for [entity] (reference: tapping a person in a
/// reply). It shows what the reply embedded at once (picture, sub-line,
/// summary with its source chips, facts, highlights, links, sources) and,
/// when the app can fetch more ([HermesUiScope.onEntityDetails]), fills in
/// the rest as it arrives. "Follow up" sends the entity's question as a
/// visible message.
Future<void> showEntitySheet(
  BuildContext context,
  UiEntity entity, {
  MarkdownStyle? style,
}) {
  final s = style ?? MarkdownStyle.of(context);
  final handler = UiActionHandler.of(context);
  final loader = MarkdownImageScope.of(context);
  final footnotes = UiCitations.of(context);
  final infos = loader is EntityInfoSource ? loader as EntityInfoSource : null;
  final more = handler.canFetchEntityDetails
      ? handler.entityDetails(entity)
      : infos
            ?.entityInfo(entity.name, hint: entity.sub)
            .then((i) => i == null ? null : entityFromInfo(entity, i));
  return showFloatingSheet<void>(
    context,
    page: SheetPage(
      title: entity.name,
      heightFraction: 0.9,
      builder: (sheet) => MarkdownImageScope(
        loader: loader,
        child: EntityDetailsView(
          entity: entity,
          more: more,
          style: s,
          footnotes: footnotes,
          onOpenLink: handler.openLink,
          onFollowUp: handler.canSend
              ? () {
                  Navigator.of(sheet).pop();
                  handler.send(entity.followUp);
                }
              : null,
          onOpenImage: loader == null
              ? null
              : (images, i) => showMdImageViewer(
                  sheet,
                  images: images,
                  initial: i,
                  loader: loader,
                  style: s,
                  onLinkTap: handler.openLink,
                ),
        ),
      ),
    ),
  );
}

/// What the bridge's entity info adds to [e] (round 8), shaped for
/// [UiEntity.merge]: the reply's own sub-line, picture, summary and links
/// come first; Wikipedia fills the gaps and adds "Read on Wikipedia".
UiEntity entityFromInfo(UiEntity e, EntityInfo i) {
  final desc = i.description;
  final extract = i.extract;
  String? about = e.about;
  if (about == null && (extract != null || desc != null)) {
    about = [
      if (desc != null && e.sub != null) '_${desc.replaceAll('_', ' ')}_',
      ?extract,
    ].join('\n\n');
  }
  final page = i.page;
  return UiEntity(
    name: e.name,
    sub: desc,
    image: i.originalImage ?? i.image,
    page: page,
    about: about,
    facts: e.facts,
    highlights: e.highlights,
    links: [
      ...e.links,
      if (page != null && !e.links.any((l) => l.url == page))
        UiLink('Read on Wikipedia', page),
    ],
    ask: e.ask,
  );
}

/// The scrolling body of the entity sheet.
class EntityDetailsView extends StatelessWidget {
  const EntityDetailsView({
    super.key,
    required this.entity,
    required this.style,
    required this.onOpenLink,
    this.more,
    this.footnotes = const {},
    this.onFollowUp,
    this.onOpenImage,
  });

  final UiEntity entity;
  final MarkdownStyle style;
  final Future<UiEntity?>? more;
  final Map<String, Footnote> footnotes;
  final void Function(String url) onOpenLink;
  final VoidCallback? onFollowUp;
  final void Function(List<MdImage> images, int index)? onOpenImage;

  @override
  Widget build(BuildContext context) {
    final f = more;
    if (f == null) return _body(context, entity, loading: false);
    return FutureBuilder<UiEntity?>(
      future: f,
      builder: (context, snap) {
        final done = snap.connectionState == ConnectionState.done;
        final e = snap.data == null ? entity : entity.merge(snap.data!);
        return _body(context, e, loading: !done);
      },
    );
  }

  Widget _body(BuildContext context, UiEntity e, {required bool loading}) {
    final s = style;
    final images = <MdImage>[
      if (e.image != null) MdImage(src: e.image!, alt: e.name, source: e.page),
      for (final h in e.highlights)
        if (h.image != null) MdImage(src: h.image!, alt: h.name),
    ];
    // The summary's citations: footnote definitions it references are
    // appended so its source chips resolve; the renderer hides them.
    final about = e.about;
    final cited = about == null ? <String>{} : footnoteRefsIn(about);
    final citedNotes = [
      for (final l in cited)
        if (footnotes[l] != null) footnotes[l]!,
    ];
    String? aboutMd;
    if (about != null) {
      final defs = [
        for (final n in citedNotes)
          '[^${n.label}]: '
              '${n.url == null ? n.title : '[${n.title.replaceAll(']', '')}](${n.url})'}'
              '${n.note.isEmpty ? '' : ' — ${n.note}'}',
      ];
      aboutMd = defs.isEmpty ? about : '$about\n\n${defs.join('\n')}';
    }
    final links = [
      if (e.page != null && !e.links.any((l) => l.url == e.page))
        UiLink(e.name, e.page!),
      ...e.links,
    ];
    Widget section(String title) => Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Semantics(
        header: true,
        child: Text(title, style: s.h3.hermesSize(18, line: 24)),
      ),
    );
    final children = <Widget>[
      if (e.image != null)
        LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            final h = (w * 0.8).clamp(160.0, 340.0);
            final hero = UiRemoteImage(
              url: e.image,
              width: w,
              height: h,
              style: s,
              radius: 16,
              letter: e.name,
            );
            final open = onOpenImage;
            if (open == null) return hero;
            return _Tap(
              label: 'Picture of ${e.name}',
              hint: 'Opens the image',
              onTap: () => open(images, 0),
              child: hero,
            );
          },
        ),
      if (e.sub != null)
        Padding(
          padding: EdgeInsets.only(top: e.image == null ? 0 : 12),
          child: Text(e.sub!, style: s.body.copyWith(color: s.textMuted)),
        ),
      if (aboutMd != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: NoNestedUiBlocks(
            child: HermesMarkdown(
              text: aboutMd,
              style: s,
              onLinkTap: onOpenLink,
            ),
          ),
        )
      else if (loading)
        const Padding(
          padding: EdgeInsets.only(top: 16),
          child: _LoadingLines(),
        ),
      if (e.facts.isNotEmpty) ...[
        section('Key facts'),
        for (var i = 0; i < e.facts.length; i++) ...[
          if (i > 0) Divider(height: 1, thickness: 1, color: s.hairline),
          _FactRow(fact: e.facts[i], style: s),
        ],
      ],
      if (e.highlights.isNotEmpty) ...[
        section('Highlights'),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < e.highlights.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                _HighlightCard(
                  media: e.highlights[i],
                  style: s,
                  onTap: e.highlights[i].image == null || onOpenImage == null
                      ? null
                      : () => onOpenImage!(
                          images,
                          images.indexWhere(
                            (m) => m.src == e.highlights[i].image,
                          ),
                        ),
                ),
              ],
            ],
          ),
        ),
      ],
      if (links.isNotEmpty) ...[
        section('Links'),
        for (final l in links)
          _LinkRow(
            title: l.label,
            url: l.url,
            style: s,
            onTap: () => onOpenLink(l.url),
          ),
      ],
      if (citedNotes.isNotEmpty) ...[
        section('Sources'),
        for (final n in citedNotes)
          if (n.url != null)
            _LinkRow(
              title: n.title,
              url: n.url!,
              note: n.note,
              style: s,
              onTap: () => onOpenLink(n.url!),
            ),
      ],
    ];
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
        if (onFollowUp != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Align(
              alignment: Alignment.centerRight,
              child: UiPill(
                label: 'Follow up',
                style: s,
                primary: true,
                leading: Icons.chat_bubble_outline_rounded,
                semanticsHint: 'Asks: ${e.followUp}',
                onTap: onFollowUp,
              ),
            ),
          ),
      ],
    );
  }
}

String? _hostOf(String url) {
  final u = safeLink(url);
  return u == null ? null : linkHost(u);
}

/// Static placeholder lines while the details load (no shimmer).
class _LoadingLines extends StatelessWidget {
  const _LoadingLines();

  @override
  Widget build(BuildContext context) {
    final s = MarkdownStyle.of(context);
    Widget line(double f) => FractionallySizedBox(
      widthFactor: f,
      alignment: Alignment.centerLeft,
      child: Container(
        height: 12,
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: s.surfaceHigh,
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
    return Semantics(
      label: 'Loading details',
      liveRegion: true,
      child: Column(children: [line(1), line(0.92), line(0.6)]),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.fact, required this.style});
  final UiFact fact;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    return Semantics(
      container: true,
      label: '${fact.label}: ${fact.value}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: Text(
                fact.label,
                style: s.body.copyWith(color: s.textMuted),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(flex: 3, child: Text(fact.value, style: s.body)),
          ],
        ),
      ),
    );
  }
}

class _HighlightCard extends StatelessWidget {
  const _HighlightCard({required this.media, required this.style, this.onTap});
  final UiMedia media;
  final MarkdownStyle style;
  final VoidCallback? onTap;

  static const side = 140.0;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final card = SizedBox(
      width: side,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          UiRemoteImage(
            url: media.image,
            width: side,
            height: side,
            style: s,
            radius: 12,
            letter: media.name,
          ),
          const SizedBox(height: 8),
          Text(
            media.name,
            style: s.bodyStrong.hermesSize(15, line: 20),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (media.sub != null)
            Text(
              media.sub!,
              style: s.caption.copyWith(color: s.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
    final label = [media.name, ?media.sub].join(', ');
    final tap = onTap;
    if (tap == null) {
      return Semantics(label: label, excludeSemantics: true, child: card);
    }
    return _Tap(label: label, hint: 'Opens the image', onTap: tap, child: card);
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.title,
    required this.url,
    required this.style,
    required this.onTap,
    this.note = '',
  });

  final String title, url, note;
  final MarkdownStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final host = _hostOf(url) ?? url;
    final sub = [host, if (note.isNotEmpty) note].join(' · ');
    return _Tap(
      link: true,
      label: '$title, $host',
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              SiteFavicon(host: host, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: s.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      sub,
                      style: s.caption.copyWith(color: s.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.north_east_rounded, size: 16, color: s.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
