import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../common/floating_sheet.dart';
import '../markdown/favicons.dart';
import '../theme/tokens.dart';
import 'live_content.dart';

/// Opens a site from live mode. Returns false when nothing could open it.
typedef LiveSiteOpener = Future<bool> Function(Uri uri);

/// Opens [uri] in the in-app browser view (Custom Tabs on Android,
/// SFSafariViewController on iOS): a separate, sandboxed browser surface
/// above the app, never a web view inside our UI. Falls back to the
/// external browser where there is no in-app view (desktop, web).
Future<bool> openSiteInApp(Uri uri) async {
  try {
    if (await supportsLaunchMode(LaunchMode.inAppBrowserView) &&
        await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) {
      return true;
    }
  } catch (_) {
    // Fall through to the external browser.
  }
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// The opener live mode uses by default. Replaced in tests.
LiveSiteOpener liveSiteOpener = openSiteInApp;

/// A chat reply's sources as the reference's compact cluster at the end of
/// the action row: up to three round favicons (loaded through the bridge,
/// else letter tiles) overlapping by 2 dp with a canvas-coloured ring, then
/// "Sources" in 14/20 muted text. No fill; a 48 dp tall target. Tapping
/// opens [showLiveSourcesSheet] with each page's full title and address.
class LiveSourcesPill extends StatelessWidget {
  const LiveSourcesPill({super.key, required this.sites, this.onOpen});
  final List<LiveSite> sites;
  final ValueChanged<LiveSite>? onOpen;

  /// Favicon diameter at 1× text, and the step between favicons.
  static const iconSize = 20.0, step = 18.0, ring = 1.5;

  @override
  Widget build(BuildContext context) {
    if (sites.isEmpty) return const SizedBox.shrink();
    final t = HermesTokens.of(context);
    final hosts = sites.map((s) => s.host).toSet().toList();
    final k =
        MediaQuery.textScalerOf(context).scale(iconSize).clamp(iconSize, 28.0) /
        iconSize;
    final icon = iconSize * k;
    final dx = step * k;
    final shown = hosts.take(3).toList();
    final outer = icon + 2 * ring;
    final glyphs = SizedBox(
      width: outer + dx * (shown.length - 1),
      height: outer,
      child: Stack(
        children: [
          // The first site is drawn last, on top (as in the reference).
          for (var i = shown.length - 1; i >= 0; i--)
            Positioned(
              left: dx * i,
              child: SiteFavicon(
                host: shown[i],
                size: icon,
                ring: t.bg,
                ringWidth: ring,
              ),
            ),
        ],
      ),
    );
    final n = sites.length;
    void open() => showLiveSourcesSheet(context, sites, onOpen: onOpen);
    return Semantics(
      button: true,
      label: 'Sources, $n ${n == 1 ? 'page' : 'pages'}: ${hosts.join(', ')}',
      onTap: open,
      excludeSemantics: true,
      child: Align(
        alignment: Alignment.centerLeft,
        widthFactor: 1,
        child: Material(
          color: Colors.transparent,
          shape: const StadiumBorder(),
          child: InkWell(
            key: const ValueKey('sources-cluster'),
            customBorder: const StadiumBorder(),
            onTap: open,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    glyphs,
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Sources',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.caption,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Sources sheet: one row per page with its full title and address.
/// Tapping a row closes the sheet and opens the page.
Future<void> showLiveSourcesSheet(
  BuildContext context,
  List<LiveSite> sites, {
  ValueChanged<LiveSite>? onOpen,
}) {
  return showFloatingSheet<void>(
    context,
    page: SheetPage(
      title: 'Sources',
      builder: (sheet) {
        final t = HermesTokens.of(sheet);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < sites.length; i++) ...[
                if (i > 0) Divider(height: 1, color: t.hairline),
                LiveSiteCard(
                  site: sites[i],
                  showAddress: true,
                  onOpen: (site) {
                    Navigator.of(sheet).pop();
                    final cb = onOpen;
                    cb != null ? cb(site) : liveSiteOpener(site.uri);
                  },
                ),
              ],
            ],
          ),
        );
      },
    ),
  );
}

/// The address shown under a source's title: the page without its scheme.
String siteAddress(Uri uri) {
  final s = uri.toString().replaceFirst(RegExp(r'^https?://(www\.)?'), '');
  return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
}

/// Readable source rows shared by chat answers and the live facts view.
/// Titles and hosts come from returned links; no invented preview metadata.
class LiveSiteCards extends StatefulWidget {
  const LiveSiteCards({super.key, required this.sites, this.onOpen});
  final List<LiveSite> sites;
  final ValueChanged<LiveSite>? onOpen;

  @override
  State<LiveSiteCards> createState() => _LiveSiteCardsState();
}

class _LiveSiteCardsState extends State<LiveSiteCards> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    if (widget.sites.isEmpty) return const SizedBox.shrink();
    final t = HermesTokens.of(context);
    final sites = _all ? widget.sites : widget.sites.take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Its own node, so the heading never merges into a parent container
        // such as the reply's long-press node.
        Semantics(
          header: true,
          container: true,
          child: Text('Sources', style: t.label),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < sites.length; i++) ...[
          if (i > 0) Divider(height: 1, color: t.hairline),
          LiveSiteCard(site: sites[i], onOpen: widget.onOpen),
        ],
        if (widget.sites.length > 3)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              // The accent is 4.3:1 on black; the orb's lower sky keeps the
              // blue and reads 8:1 there (5.5:1 on raised surfaces). Light
              // keeps the accent (5.75:1 on white).
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).brightness == Brightness.dark
                    ? OrbPalette.skyLow
                    : t.accent,
              ),
              onPressed: () => setState(() => _all = !_all),
              child: Text(
                _all
                    ? 'Show fewer sources'
                    : 'Show all ${widget.sites.length} sources',
              ),
            ),
          ),
      ],
    );
  }
}

/// One resource with its title, host and favicon (or letter tile).
class LiveSiteCard extends StatelessWidget {
  const LiveSiteCard({
    super.key,
    required this.site,
    this.onOpen,
    this.showAddress = false,
  });
  final LiveSite site;
  final ValueChanged<LiveSite>? onOpen;

  /// Show the page's address under the title instead of only its host.
  final bool showAddress;

  void _open() {
    final cb = onOpen;
    if (cb != null) {
      cb(site);
    } else {
      liveSiteOpener(site.uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Semantics(
      link: true,
      label: 'Open ${site.title}, ${site.host}',
      // The label replaces the row's text, which also drops the InkWell's
      // action; screen readers activate the row through this one.
      onTap: _open,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: _open,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SiteFavicon(host: site.host, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        site.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: t.body.copyWith(
                          fontSize: 16,
                          height: 23 / 16,
                          decoration: TextDecoration.underline,
                          decorationColor: t.hairline,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        showAddress ? siteAddress(site.uri) : site.host,
                        maxLines: showAddress ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.label,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.north_east_rounded, size: 16, color: t.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A 16 dp rounded tile with the host's first letter, tinted per host.
class SiteMonogram extends StatelessWidget {
  const SiteMonogram({super.key, required this.host, this.size = 16});

  final String host;
  final double size;

  static const _hues = [210.0, 160.0, 280.0, 30.0, 340.0, 190.0, 100.0, 250.0];

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    var hash = 0;
    for (final c in host.codeUnits) {
      hash = (hash * 31 + c) & 0x7fffffff;
    }
    final hue = _hues[hash % _hues.length];
    final bg = HSLColor.fromAHSL(1, hue, 0.45, t.dark ? 0.32 : 0.86).toColor();
    final fg = HSLColor.fromAHSL(1, hue, 0.6, t.dark ? 0.86 : 0.30).toColor();
    final letter = host.isEmpty ? '?' : host[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(size / 4),
      ),
      child: Text(
        letter,
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          fontFamily: HermesTokens.fontFamily,
          fontSize: size * 0.62,
          height: 1,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}
