import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../common/shimmer.dart';
import '../markdown/hermes_markdown.dart';
import '../theme/render_policy.dart';
import '../theme/tokens.dart';
import '../thread/follow_scroll.dart';
import 'live_content.dart';
import 'live_link_cards.dart';

/// Builds extra blocks under a live answer (for example the hermes-ui
/// interactive blocks, once `lib/src/ui/interactive/` exists and the
/// markdown renderer does not already draw them). Return null for none.
typedef LiveBlockBuilder = Widget? Function(
  BuildContext context,
  LiveContent content,
);

/// The live panel (spec §2.3, §4.2): a long answer or task result, rendered
/// with the app's markdown module, scrolling under the app bar and fading
/// out above the composer, with the docked orb drawn over it.
///
/// It follows the stream while the reader is within 160 dp of the end
/// ([FollowScrollController]); dragging up stops following. Links become
/// [LiveSiteCards] under the text.
class LivePanel extends StatefulWidget {
  const LivePanel({
    super.key,
    required this.content,
    required this.scroll,
    required this.topInset,
    required this.fadeStart,
    required this.fadeEnd,
    required this.bottomPadding,
    this.onCollapse,
    this.onOpenSite,
    this.blockBuilder,
  });

  final LiveContent content;
  final FollowScrollController scroll;

  /// The app bar's bottom: the text starts 8 dp under it.
  final double topInset;

  /// The fade runs from opaque at [fadeStart] to clear at [fadeEnd] (the
  /// composer top), in this widget's coordinates.
  final double fadeStart, fadeEnd;

  /// Room under the last line, so it can scroll above the orb and cards.
  final double bottomPadding;

  /// Hides the panel (the orb returns to the centre).
  final VoidCallback? onCollapse;
  final ValueChanged<LiveSite>? onOpenSite;
  final LiveBlockBuilder? blockBuilder;

  @override
  State<LivePanel> createState() => _LivePanelState();
}

class _LivePanelState extends State<LivePanel> {
  /// Content once seen streaming keeps the streaming renderer, so the rate
  /// smoothing can flush and the trailing fade finish.
  final Set<String> _streamed = {};

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final c = widget.content;
    if (c.streaming) _streamed.add(c.id);
    final sites = c.failed || c.continuesInChat ? const <LiveSite>[] : c.sites;
    final extra = widget.blockBuilder?.call(context, c);

    Widget body;
    if (c.text.trim().isEmpty && c.streaming) {
      body = Align(
        alignment: Alignment.centerLeft,
        child: ShimmerText('Working on it…', style: t.body),
      );
    } else if (c.failed || c.continuesInChat) {
      body = Text(c.text, style: t.body.copyWith(color: t.textMuted));
    } else if (_streamed.contains(c.id)) {
      body = StreamingMarkdown(
        key: ValueKey('md-${c.id}'),
        text: c.text,
        isStreaming: c.streaming,
      );
    } else {
      body = HermesMarkdown(key: ValueKey('md-${c.id}'), text: c.text);
    }

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(content: c, onCollapse: widget.onCollapse),
        if (c.title != null) ...[
          const SizedBox(height: Sp.xs),
          Text(
            c.title!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: t.row.copyWith(color: t.textMuted),
          ),
        ],
        const SizedBox(height: Sp.m),
        SelectionArea(child: body),
        if (sites.isNotEmpty) ...[
          const SizedBox(height: Sp.xl),
          LiveSiteCards(sites: sites, onOpen: widget.onOpenSite),
        ],
        if (extra != null) ...[const SizedBox(height: Sp.l), extra],
      ],
    );

    final scroll = SingleChildScrollView(
      key: const ValueKey('live-panel-scroll'),
      controller: widget.scroll,
      padding: EdgeInsets.fromLTRB(
        Sp.content,
        widget.topInset + 8,
        Sp.content,
        widget.bottomPadding,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Sz.contentMaxWidth),
          child: column,
        ),
      ),
    );
    return RepaintBoundary(
      child: LivePanelFade(
        fadeStart: widget.fadeStart,
        fadeEnd: widget.fadeEnd,
        child: scroll,
      ),
    );
  }
}

/// Shared fade for rich answers and the live conversation.
class LivePanelFade extends StatelessWidget {
  const LivePanelFade({
    super.key,
    required this.fadeStart,
    required this.fadeEnd,
    required this.child,
  });
  final double fadeStart, fadeEnd;
  final Widget child;

  /// The bottom fade (§4.2): a `dstIn` mask, or a `bg` gradient over the
  /// text when the render policy says masks are too costly (§7.3).
  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    if (RenderPolicyScope.of(context).liveMask) {
      return ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (r) {
          final a = (fadeStart / r.height).clamp(0.0, 1.0);
          final b = (fadeEnd / r.height).clamp(a, 1.0);
          return LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: const [Colors.white, Colors.white, Color(0x00FFFFFF)],
            stops: [0, a, b],
          ).createShader(r);
        },
        child: child,
      );
    }
    return Stack(
      children: [
        child,
        Positioned(
          left: 0,
          right: 0,
          top: fadeStart,
          height: math.max(1, fadeEnd - fadeStart),
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [t.bg.withValues(alpha: 0), t.bg],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: fadeEnd,
          bottom: 0,
          child: IgnorePointer(child: ColoredBox(color: t.bg)),
        ),
      ],
    );
  }
}

/// "Task result · 12 s" / "Answer", and the hide button.
class _Header extends StatelessWidget {
  const _Header({required this.content, this.onCollapse});

  final LiveContent content;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final c = content;
    final String what;
    if (c.kind == LiveContentKind.answer) {
      what = c.streaming ? 'Answering' : 'Answer';
    } else if (c.failed) {
      what = 'Task failed';
    } else if (c.continuesInChat) {
      what = 'Task continues in the chat';
    } else if (c.streaming) {
      what = 'Task running';
    } else {
      what = c.seconds != null ? 'Task result · ${c.seconds} s' : 'Task result';
    }
    return Row(
      children: [
        Expanded(
          child: Semantics(header: true, child: Text(what, style: t.section)),
        ),
        if (onCollapse != null)
          IconButton(
            onPressed: onCollapse,
            tooltip: 'Hide',
            visualDensity: VisualDensity.compact,
            color: t.textMuted,
            icon: const Icon(Icons.expand_more_rounded),
          ),
      ],
    );
  }
}
