/// Site favicons for source chips, the sources cluster and the sources sheet
/// (round 3).
///
/// Favicons come through the bridge like every other remote image: the app
/// never contacts a site itself. A [MarkdownImageLoader] that also
/// implements [FaviconSource] (the [BridgeImageLoader] does) provides them;
/// without one, every site shows its letter tile ([SiteLetterTile]).
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import 'md_images.dart';

/// Loads one favicon per host. [peekFavicon] answers from memory without
/// waiting, so a rebuilt cluster never flashes its letter tiles again.
abstract class FaviconSource {
  LinkImageResult? peekFavicon(String host);
  Future<LinkImageResult> loadFavicon(String host);
}

final _iconDataUrl = RegExp(
  r'^data:(image/(?:jpeg|png|gif|webp|x-icon|vnd\.microsoft\.icon));base64,',
);

/// Reads a favicon from a `/api/favicon` or `/api/link-preview` body: the
/// `favicon` field, a signature-checked `data:` URL.
LinkImage? parseFaviconBody(List<int> body) {
  final Object? j;
  try {
    j = jsonDecode(utf8.decode(body));
  } on FormatException {
    return null;
  }
  if (j is! Map) return null;
  final icon = j['favicon'];
  if (icon is! String) return null;
  final m = _iconDataUrl.firstMatch(icon);
  if (m == null) return null;
  try {
    final bytes = base64Decode(icon.substring(m.end));
    if (bytes.isEmpty) return null;
    int? dim(Object? v) => v is int && v > 0 && v < 4096 ? v : null;
    return LinkImage(
      bytes: bytes,
      url: '${j['url'] ?? ''}',
      width: dim(j['width']),
      height: dim(j['height']),
    );
  } on FormatException {
    return null;
  }
}

/// The host a favicon is keyed by: lower case, without `www.`.
String faviconHost(String host) {
  final h = host.trim().toLowerCase();
  return h.startsWith('www.') ? h.substring(4) : h;
}

/// A round site icon: the favicon on a white disc, or the site's letter
/// tile while it loads or when it has none. [ring] draws a separating ring
/// in that colour (overlapping clusters).
class SiteFavicon extends StatefulWidget {
  const SiteFavicon({
    super.key,
    required this.host,
    this.size = 20,
    this.ring,
    this.ringWidth = 1.5,
  });

  final String host;
  final double size;
  final Color? ring;
  final double ringWidth;

  @override
  State<SiteFavicon> createState() => _SiteFaviconState();
}

class _SiteFaviconState extends State<SiteFavicon> {
  LinkImage? _icon;
  bool _failed = false;
  String? _key;
  FaviconSource? _source;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(SiteFavicon old) {
    super.didUpdateWidget(old);
    if (old.host != widget.host) _resolve();
  }

  void _resolve() {
    final loader = MarkdownImageScope.of(context);
    final source = loader is FaviconSource ? loader as FaviconSource : null;
    final key = faviconHost(widget.host);
    if (key == _key && identical(source, _source)) return;
    _key = key;
    _source = source;
    _icon = null;
    _failed = false;
    if (source == null || key.isEmpty) return;
    final hit = source.peekFavicon(key);
    if (hit != null) {
      _icon = hit.image;
      _failed = hit.image == null;
      return;
    }
    source.loadFavicon(key).then((r) {
      if (!mounted || _key != key) return;
      setState(() {
        _icon = r.image;
        _failed = r.image == null;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final icon = _icon;
    Widget face;
    if (icon != null && !_failed) {
      final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2;
      face = DecoratedBox(
        decoration: const BoxDecoration(
          color: Color(0xFFFFFFFF),
          shape: BoxShape.circle,
        ),
        child: Padding(
          padding: EdgeInsets.all(size * 0.12),
          child: ClipOval(
            child: Image(
              image: ResizeImage.resizeIfNeeded(
                (size * dpr).ceil(),
                null,
                MemoryImage(icon.bytes),
              ),
              width: size,
              height: size,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              excludeFromSemantics: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (context, error, stack) =>
                  SiteLetterTile(host: widget.host, size: size * 0.76),
            ),
          ),
        ),
      );
    } else {
      face = SiteLetterTile(host: widget.host, size: size);
    }
    face = SizedBox.square(
      dimension: size,
      child: ClipOval(child: face),
    );
    final ring = widget.ring;
    if (ring == null) return face;
    return Container(
      padding: EdgeInsets.all(widget.ringWidth),
      decoration: BoxDecoration(color: ring, shape: BoxShape.circle),
      child: face,
    );
  }
}

/// A round tile with the host's first letter, tinted per host: the favicon
/// stand-in.
class SiteLetterTile extends StatelessWidget {
  const SiteLetterTile({super.key, required this.host, this.size = 20});

  final String host;
  final double size;

  static const _hues = [210.0, 160.0, 280.0, 30.0, 340.0, 190.0, 100.0, 250.0];

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final h = faviconHost(host);
    var hash = 0;
    for (final c in h.codeUnits) {
      hash = (hash * 31 + c) & 0x7fffffff;
    }
    final hue = _hues[hash % _hues.length];
    final bg = HSLColor.fromAHSL(1, hue, 0.45, t.dark ? 0.32 : 0.86).toColor();
    final fg = HSLColor.fromAHSL(1, hue, 0.6, t.dark ? 0.86 : 0.30).toColor();
    final letter = h.isEmpty ? '?' : h[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Text(
        letter,
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          fontFamily: HermesTokens.fontFamily,
          fontSize: size * 0.55,
          height: 1,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}
