/// Markdown images loaded through the bridge: `/api/image` (raw bytes, a
/// sized copy where the host has one) or, on older bridges,
/// `/api/link-preview`.
///
/// The app never fetches an image host itself: the bridge fetches the URL
/// (public addresses only, bounded size, signature-checked bytes) and
/// returns the bytes, so the access key and the user's address never reach
/// the image host. Without a [MarkdownImageScope]
/// loader, images stay "[image: alt]" pills.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../theme/motion.dart';
import 'entity_info.dart';
import 'favicons.dart';
import 'links.dart';
import 'markdown_style.dart';
import 'source_pill.dart';

/// Image bytes the bridge returned for one URL.
@immutable
class LinkImage {
  const LinkImage({
    required this.bytes,
    required this.url,
    this.width,
    this.height,
  });

  final Uint8List bytes;

  /// The final URL after redirects.
  final String url;

  /// From the image header, when the bridge could read it.
  final int? width, height;

  double? get aspect =>
      width != null && height != null && height! > 0 ? width! / height! : null;
}

/// The outcome of one load: [image] is null when the URL gave no image.
@immutable
class LinkImageResult {
  const LinkImageResult(this.image);
  final LinkImage? image;
}

/// Loads markdown images. [peek] answers from memory without waiting, so a
/// rebuilt or remounted image never flashes its placeholder again.
abstract class MarkdownImageLoader {
  LinkImageResult? peek(String url);
  Future<LinkImageResult> load(String url, {bool retry = false});
}

final _dataUrl = RegExp(r'^data:(image/(?:jpeg|png|gif|webp));base64,');

/// Parses a `/api/link-preview` body into an image (off the UI thread: a
/// direct image can be a 2 MB JSON body).
LinkImage? parseLinkPreviewImage(Uint8List body) {
  final Object? j;
  try {
    j = jsonDecode(utf8.decode(body));
  } on FormatException {
    return null;
  }
  if (j is! Map) return null;
  final image = j['image'];
  if (image is! String) return null;
  final m = _dataUrl.firstMatch(image);
  if (m == null) return null;
  final Uint8List bytes;
  try {
    bytes = base64Decode(image.substring(m.end));
  } on FormatException {
    return null;
  }
  if (bytes.isEmpty) return null;
  int? dim(Object? v) => v is int && v > 0 && v < 100000 ? v : null;
  final url = j['url'];
  return LinkImage(
    bytes: bytes,
    url: url is String ? url : '',
    width: dim(j['width']),
    height: dim(j['height']),
  );
}

/// Loads images with the bridge's link preview. Results (and definite
/// failures) are kept in memory, least recently used first out, up to
/// [maxBytes]; concurrent loads of one URL share a request.
///
/// Favicons ([FaviconSource]) use `GET /api/favicon?host=` (bridge round 3)
/// and fall back to the link preview of `https://<host>/` while the bridge
/// answers 404 for that route. They are cached per host in the same way.
class BridgeImageLoader
    implements
        MarkdownImageLoader,
        FaviconSource,
        EntityInfoSource,
        PageImageSource {
  BridgeImageLoader({
    required Uri baseUrl,
    required String accessKey,
    http.Client? client,
    this.maxBytes = 48 << 20,
    this.maxEntries = 128,
    this.timeout = const Duration(seconds: 15),
  }) : _base = _normalise(baseUrl),
       _key = accessKey,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final Uri _base;
  final String _key;
  final http.Client _client;
  final bool _ownsClient;
  final int maxBytes;
  final int maxEntries;
  final Duration timeout;

  /// Bodies up to this size are parsed on the UI isolate.
  static const inlineParseBytes = 64 << 10;

  final _cache = <String, LinkImageResult>{}; // insertion order = LRU
  final _pending = <String, Future<LinkImageResult>>{};
  int _bytes = 0;

  static Uri _normalise(Uri u) {
    final path = u.path.endsWith('/')
        ? u.path.substring(0, u.path.length - 1)
        : u.path;
    return u.replace(path: path, query: null, fragment: null);
  }

  @override
  LinkImageResult? peek(String url) {
    final hit = _cache.remove(url);
    if (hit != null) _cache[url] = hit;
    return hit;
  }

  @override
  Future<LinkImageResult> load(String url, {bool retry = false}) {
    if (retry) {
      _drop(url);
    } else {
      final hit = peek(url);
      if (hit != null) return SynchronousFuture(hit);
    }
    // A block body: returning the removed future would make whenComplete
    // wait for itself.
    return _pending[url] ??= _fetch(url).whenComplete(() {
      _pending.remove(url);
    });
  }

  /// Null until known: whether the bridge has `/api/image` (round 6 B5).
  bool? imageRoute;

  /// The width asked of `/api/image`; the bridge picks the host's nearest
  /// sized copy (a Wikimedia thumbnail, say) instead of a multi-MB original.
  static const proxyWidth = 1280;

  Future<LinkImageResult> _fetch(String url) async {
    if (imageRoute != false) {
      final proxied = await _fetchProxied(url);
      if (proxied != null) return proxied;
    }
    final uri = _base.replace(
      path: '${_base.path}/api/link-preview',
      queryParameters: {'url': url},
    );
    final http.Response r;
    try {
      r = await _client
          .get(
            uri,
            headers: {
              'Authorization': 'Bearer $_key',
              'Accept': 'application/json',
            },
          )
          .timeout(timeout);
    } catch (_) {
      // Offline or timed out: not remembered, so a later build tries again.
      return const LinkImageResult(null);
    }
    // Any answer is remembered (the bridge caches failures too); the failed
    // frame's retry asks again.
    // Decoding a direct image's JSON and base64 (up to ~2 MB) takes longer
    // than a 120 Hz frame, so large bodies decode on another isolate; small
    // ones are cheaper than the isolate hop.
    final body = r.bodyBytes;
    final image = r.statusCode != 200
        ? null
        : body.length > inlineParseBytes
        ? await compute(parseLinkPreviewImage, body)
        : parseLinkPreviewImage(body);
    final result = LinkImageResult(image);
    _store(url, result);
    return result;
  }

  /// `GET /api/image`: the picture's own bytes (no base64 JSON), with its
  /// size in `X-Image-Width`/`X-Image-Height`. Null means "use
  /// link-preview": an older bridge (a plain-text 404) or the app offline.
  Future<LinkImageResult?> _fetchProxied(String url) async {
    final http.Response r;
    try {
      r = await _client
          .get(
            _base.replace(
              path: '${_base.path}/api/image',
              queryParameters: {'url': url, 'w': '$proxyWidth'},
            ),
            headers: {'Authorization': 'Bearer $_key', 'Accept': 'image/*'},
          )
          .timeout(timeout);
    } catch (_) {
      return const LinkImageResult(null); // offline: not remembered
    }
    if (r.statusCode == 404 && !_isJson(r)) {
      imageRoute = false;
      return null;
    }
    imageRoute = true;
    final type = (r.headers['content-type'] ?? '').split(';').first.trim();
    LinkImage? image;
    if (r.statusCode == 200 && _proxyTypes.contains(type)) {
      image = LinkImage(
        bytes: r.bodyBytes,
        url: url,
        width: int.tryParse(r.headers['x-image-width'] ?? ''),
        height: int.tryParse(r.headers['x-image-height'] ?? ''),
      );
    }
    final result = LinkImageResult(image);
    // A 429 from the image host is cached only briefly by the bridge; leave
    // it unremembered here so the failed frame's retry asks again.
    if (r.statusCode != 502) _store(url, result);
    return result;
  }

  static const _proxyTypes = {
    'image/jpeg',
    'image/png',
    'image/gif',
    'image/webp',
  };

  void _store(String url, LinkImageResult result) {
    _drop(url);
    _cache[url] = result;
    _bytes += result.image?.bytes.length ?? 0;
    while (_cache.length > 1 &&
        (_bytes > maxBytes || _cache.length > maxEntries)) {
      _drop(_cache.keys.first);
    }
  }

  void _drop(String url) {
    final old = _cache.remove(url);
    _bytes -= old?.image?.bytes.length ?? 0;
  }

  // ------------------------------------------------------------ favicons

  final _icons = <String, LinkImageResult>{}; // insertion order = LRU
  final _iconsPending = <String, Future<LinkImageResult>>{};

  /// Null until known: whether the bridge has `/api/favicon`.
  bool? faviconRoute;

  static const maxIcons = 256;

  @override
  LinkImageResult? peekFavicon(String host) {
    final key = faviconHost(host);
    final hit = _icons.remove(key);
    if (hit != null) _icons[key] = hit;
    return hit;
  }

  @override
  Future<LinkImageResult> loadFavicon(String host) {
    final key = faviconHost(host);
    final hit = peekFavicon(key);
    if (hit != null) return SynchronousFuture(hit);
    return _iconsPending[key] ??= _fetchFavicon(key).whenComplete(() {
      _iconsPending.remove(key);
    });
  }

  Future<http.Response?> _get(String path, Map<String, String> query) async {
    try {
      return await _client
          .get(
            _base.replace(path: '${_base.path}$path', queryParameters: query),
            headers: {
              'Authorization': 'Bearer $_key',
              'Accept': 'application/json',
            },
          )
          .timeout(timeout);
    } catch (_) {
      return null;
    }
  }

  Future<LinkImageResult> _fetchFavicon(String host) async {
    if (host.isEmpty || !host.contains('.')) return const LinkImageResult(null);
    http.Response? r;
    if (faviconRoute != false) {
      r = await _get('/api/favicon', {'host': host});
      if (r == null) return const LinkImageResult(null); // offline: retry later
      if (r.statusCode == 404 && !_isJson(r)) {
        faviconRoute = false; // an older bridge: plain-text 404
        r = null;
      } else {
        faviconRoute = true;
      }
    }
    r ??= await _get('/api/link-preview', {'url': 'https://$host/'});
    if (r == null) return const LinkImageResult(null);
    final icon = r.statusCode == 200 ? parseFaviconBody(r.bodyBytes) : null;
    final result = LinkImageResult(icon);
    _icons[host] = result;
    while (_icons.length > maxIcons) {
      _icons.remove(_icons.keys.first);
    }
    return result;
  }

  static bool _isJson(http.Response r) =>
      (r.headers['content-type'] ?? '').contains('json');

  // ------------------------------------------------------------ entity info

  final _entities = <String, EntityInfo?>{}; // insertion order = LRU
  final _entitiesPending = <String, Future<EntityInfo?>>{};

  /// Null until known: whether the bridge has `/api/entity/info` (round 8).
  bool? entityRoute;

  static String _entityKey(String name, String? hint) =>
      '${name.trim().toLowerCase()}\n${(hint ?? '').trim().toLowerCase()}';

  @override
  EntityInfo? peekEntityInfo(String name, {String? hint}) =>
      _entities[_entityKey(name, hint)];

  @override
  Future<EntityInfo?> entityInfo(String name, {String? hint}) {
    final key = _entityKey(name, hint);
    if (_entities.containsKey(key)) {
      return SynchronousFuture(_entities[key]);
    }
    if (entityRoute == false || name.trim().isEmpty) {
      return SynchronousFuture(null);
    }
    return _entitiesPending[key] ??= _fetchEntity(name, hint, key).whenComplete(
      () {
        // A block body: returning the removed future would deadlock.
        _entitiesPending.remove(key);
      },
    );
  }

  Future<EntityInfo?> _fetchEntity(
    String name,
    String? hint,
    String key,
  ) async {
    final r = await _get('/api/entity/info', {
      'name': name.trim(),
      if (hint != null && hint.trim().isNotEmpty) 'hint': hint.trim(),
    });
    if (r == null) return null; // offline: ask again later
    if (r.statusCode == 404 && !_isJson(r)) {
      entityRoute = false; // an older bridge
      return null;
    }
    entityRoute = true;
    if (r.statusCode == 502) return null; // Wikipedia busy: not remembered
    EntityInfo? info;
    if (r.statusCode == 200) {
      try {
        info = EntityInfo.fromJson(jsonDecode(utf8.decode(r.bodyBytes)));
      } on FormatException {
        info = null;
      }
    }
    _entities[key] = info;
    while (_entities.length > 256) {
      _entities.remove(_entities.keys.first);
    }
    return info;
  }

  // ------------------------------------------------------------ page images

  static String _pageKey(String url) => 'page:$url';

  @override
  LinkImageResult? peekPageImage(String pageUrl) => peek(_pageKey(pageUrl));

  /// Through `/api/link-preview` (the page's og:image), cached with the
  /// other images under a `page:` key.
  @override
  Future<LinkImageResult> loadPageImage(String pageUrl) {
    final key = _pageKey(pageUrl);
    final hit = peek(key);
    if (hit != null) return SynchronousFuture(hit);
    return _pending[key] ??=
        () async {
          final r = await _get('/api/link-preview', {'url': pageUrl});
          if (r == null) return const LinkImageResult(null);
          final body = r.bodyBytes;
          final image = r.statusCode != 200
              ? null
              : body.length > inlineParseBytes
              ? await compute(parseLinkPreviewImage, body)
              : parseLinkPreviewImage(body);
          final result = LinkImageResult(image);
          _store(key, result);
          return result;
        }().whenComplete(() {
          _pending.remove(key);
        });
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

/// Provides the image loader to markdown below it. A null [loader] keeps
/// images as pills.
class MarkdownImageScope extends InheritedWidget {
  const MarkdownImageScope({
    super.key,
    required this.loader,
    required super.child,
  });

  final MarkdownImageLoader? loader;

  static MarkdownImageLoader? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MarkdownImageScope>()?.loader;

  @override
  bool updateShouldNotify(MarkdownImageScope old) => old.loader != loader;
}

/// One markdown image: `![alt](src "title")`, optionally inside a link to
/// the page it came from (`[![alt](src)](source)`).
@immutable
class MdImage {
  const MdImage({required this.src, this.alt = '', this.title, this.source});

  final String src;
  final String alt;
  final String? title;

  /// The page the image came from, when the markdown linked one.
  final String? source;

  String get caption {
    final t = title?.trim() ?? '';
    return t.isNotEmpty ? t : alt.trim();
  }

  /// Where the source action goes: the page, else the image itself.
  String get sourceHref => source ?? src;

  String get host {
    final u = safeLink(sourceHref);
    return u == null ? '' : linkHost(u);
  }

  @override
  bool operator ==(Object other) =>
      other is MdImage &&
      other.src == src &&
      other.alt == alt &&
      other.title == title &&
      other.source == source;

  @override
  int get hashCode => Object.hash(src, alt, title, source);
}

/// Most images shown for one paragraph; the rest are dropped.
const mdMaxGalleryImages = 8;

/// A paragraph of images: one full-width card, a pair side by side, or a
/// horizontal strip for three or more. Every frame has a fixed height from
/// the available width alone, so loading, loaded and failed images take the
/// same space and the reply never jumps per token. An image that fails is
/// dropped while another in the paragraph can still show; a failure card
/// shows only when every image failed.
class MdImageGallery extends StatefulWidget {
  const MdImageGallery({
    super.key,
    required this.images,
    required this.loader,
    required this.style,
    required this.onLinkTap,
    this.opacity = 1,
  });

  final List<MdImage> images;
  final MarkdownImageLoader loader;
  final MarkdownStyle style;
  final void Function(String href) onLinkTap;

  /// The streaming fade.
  final double opacity;

  static const gap = 8.0;

  /// The frame height of a single image at [width].
  static double singleHeight(double width) =>
      (width * 0.5625).clamp(160.0, 300.0);

  /// The frame height of a pair tile at tile [width].
  static double pairHeight(double width) => (width * 1.0).clamp(132.0, 240.0);

  /// The tile width of a strip at [width]: two tiles side by side and the
  /// edge of the next, so the row reads as scrollable.
  static double stripWidth(double width) => (width * 0.45).clamp(140.0, 240.0);

  @override
  State<MdImageGallery> createState() => _MdImageGalleryState();
}

class _MdImageGalleryState extends State<MdImageGallery> {
  /// Sources known to have failed (from memory or reported by a tile).
  final _failed = <String>{};

  void _onResult(String src, bool ok) {
    final changed = ok ? _failed.remove(src) : _failed.add(src);
    if (changed && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.images.take(mdMaxGalleryImages).toList();
    for (final im in all) {
      final known = widget.loader.peek(im.src);
      if (known != null && known.image == null) _failed.add(im.src);
    }
    var shown = all.where((im) => !_failed.contains(im.src)).toList();
    if (shown.isEmpty) shown = all;
    final loader = widget.loader;
    final style = widget.style;
    final onLinkTap = widget.onLinkTap;
    const gap = MdImageGallery.gap;
    Widget body = LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        MdImageTile tile(int i, MdImageLayout layout, double fw, double fh) =>
            MdImageTile(
              key: ValueKey<String>(shown[i].src),
              image: shown[i],
              loader: loader,
              style: style,
              onLinkTap: onLinkTap,
              onResult: _onResult,
              layout: layout,
              frameWidth: fw,
              frameHeight: fh,
              index: i,
              gallery: shown,
            );
        if (shown.length == 1) {
          return tile(
            0,
            MdImageLayout.single,
            w,
            MdImageGallery.singleHeight(w),
          );
        }
        if (shown.length == 2) {
          final tw = (w - gap) / 2;
          final th = MdImageGallery.pairHeight(tw);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: tile(0, MdImageLayout.tile, tw, th)),
              const SizedBox(width: gap),
              Expanded(child: tile(1, MdImageLayout.tile, tw, th)),
            ],
          );
        }
        final tw = MdImageGallery.stripWidth(w);
        final th = MdImageGallery.pairHeight(tw) * 0.85;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < shown.length; i++) ...[
                if (i > 0) const SizedBox(width: gap),
                SizedBox(width: tw, child: tile(i, MdImageLayout.tile, tw, th)),
              ],
            ],
          ),
        );
      },
    );
    if (shown.length > 1) {
      body = Semantics(
        container: true,
        label: '${shown.length} images',
        child: body,
      );
    }
    final opacity = widget.opacity;
    return opacity >= 1 ? body : Opacity(opacity: opacity, child: body);
  }
}

enum MdImageLayout {
  /// Full width; a narrow (portrait) image shrinks the card's width, never
  /// its height.
  single,

  /// A fixed tile in a pair or strip, filled edge to edge.
  tile,
}

/// One image frame with its caption and source action.
class MdImageTile extends StatefulWidget {
  const MdImageTile({
    super.key,
    required this.image,
    required this.loader,
    required this.style,
    required this.onLinkTap,
    required this.layout,
    required this.frameWidth,
    required this.frameHeight,
    this.onResult,
    this.index = 0,
    this.gallery = const [],
  });

  final MdImage image;
  final MarkdownImageLoader loader;
  final MarkdownStyle style;
  final void Function(String href) onLinkTap;

  /// Told whether the image loaded (false: no image, or undecodable bytes).
  final void Function(String src, bool ok)? onResult;
  final MdImageLayout layout;
  final double frameWidth, frameHeight;

  /// Position in [gallery], for the viewer.
  final int index;
  final List<MdImage> gallery;

  @override
  State<MdImageTile> createState() => _MdImageTileState();
}

class _MdImageTileState extends State<MdImageTile> {
  LinkImageResult? _result;
  bool _decodeFailed = false;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(MdImageTile old) {
    super.didUpdateWidget(old);
    if (old.image.src != widget.image.src || old.loader != widget.loader) {
      _result = null;
      _decodeFailed = false;
      _decodedAspect = null;
      _unwatch();
      _start();
    }
  }

  void _start({bool retry = false}) {
    final src = widget.image.src;
    if (!retry) {
      final hit = widget.loader.peek(src);
      if (hit != null) {
        _result = hit;
        return;
      }
    }
    final attempt = ++_attempt;
    widget.loader.load(src, retry: retry).then((r) {
      if (!mounted || attempt != _attempt || widget.image.src != src) return;
      setState(() => _result = r);
      widget.onResult?.call(src, r.image != null);
    });
  }

  /// The decoded size's aspect: the header size ignores EXIF rotation.
  double? _decodedAspect;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  void _watch(ImageProvider provider) {
    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key && _stream != null) return;
    _unwatch();
    _listener = ImageStreamListener((info, sync) {
      final a = info.image.height > 0
          ? info.image.width / info.image.height
          : null;
      void apply() {
        if (mounted && a != null && a != _decodedAspect) {
          setState(() => _decodedAspect = a);
        }
      }

      // A cached image answers at once, inside build.
      if (sync) {
        WidgetsBinding.instance.addPostFrameCallback((_) => apply());
      } else {
        apply();
      }
    }, onError: (_, _) {});
    _stream = stream..addListener(_listener!);
  }

  void _unwatch() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _unwatch();
    super.dispose();
  }

  void _retry() {
    setState(() {
      _result = null;
      _decodeFailed = false;
    });
    _start(retry: true);
  }

  LinkImage? get _image => _decodeFailed ? null : _result?.image;
  bool get _failed => _result != null && _image == null;

  void _open() {
    final image = _image;
    if (image == null) return;
    showMdImageViewer(
      context,
      images: widget.gallery.isEmpty ? [widget.image] : widget.gallery,
      initial: widget.gallery.isEmpty ? 0 : widget.index,
      loader: widget.loader,
      style: widget.style,
      onLinkTap: widget.onLinkTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    final im = widget.image;
    final image = _image;
    final reduced = Motion.reduced(context);
    final single = widget.layout == MdImageLayout.single;
    final fh = widget.frameHeight;
    var fw = widget.frameWidth;
    final aspect = _decodedAspect ?? image?.aspect;
    if (single && image != null && aspect != null) {
      fw = (fh * aspect).clamp(fh * 0.56, widget.frameWidth);
    }

    final Widget content;
    if (image != null) {
      content = _picture(image, fw, fh, reduced);
    } else if (_failed) {
      content = _FailedFrame(style: s);
    } else {
      content = _LoadingFrame(style: s);
    }

    final radius = BorderRadius.circular(single ? 14 : 12);
    Widget frame = AnimatedContainer(
      duration: reduced ? Duration.zero : const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      width: fw,
      height: fh,
      decoration: BoxDecoration(
        color: s.surfaceHigh,
        borderRadius: radius,
        border: Border.all(color: s.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );

    final alt = im.alt.trim();
    final what = alt.isEmpty ? 'Image' : 'Image: $alt';
    final VoidCallback? onTap = image != null
        ? _open
        : (_failed ? _retry : null);
    frame = Semantics(
      image: true,
      button: onTap != null,
      label: _failed ? '$what, could not load' : what,
      hint: image != null
          ? 'Opens the image'
          : (_failed ? 'Tries again' : 'Loading'),
      excludeSemantics: true,
      onTap: onTap,
      child: FocusableActionDetector(
        enabled: onTap != null,
        mouseCursor: onTap != null
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: frame,
        ),
      ),
    );

    final caption = im.caption;
    final host = im.host;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(alignment: AlignmentDirectional.centerStart, child: frame),
        if (caption.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            caption,
            style: s.caption.copyWith(color: s.textMuted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (host.isNotEmpty)
          SourcePill(
            label: host,
            semanticsLabel: im.source != null
                ? 'Image source: $host'
                : 'Open image from $host',
            icon: Icons.north_east_rounded,
            style: s,
            onTap: () => widget.onLinkTap(im.sourceHref),
          ),
      ],
    );
  }

  Widget _picture(LinkImage image, double fw, double fh, bool reduced) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final single = widget.layout == MdImageLayout.single;
    final aspect = image.aspect;
    // Decode only as many pixels as the frame can show. The width must not
    // depend on the decoded size, or the image would decode twice.
    var need = widget.frameWidth;
    if (!single) {
      need = aspect == null ? fw * 1.5 : (fh * aspect > fw ? fh * aspect : fw);
    }
    final cacheWidth = (need * dpr).ceil().clamp(1, 4096);
    final provider = ResizeImage.resizeIfNeeded(
      cacheWidth,
      null,
      MemoryImage(image.bytes),
    );
    if (single) _watch(provider);
    return Image(
      image: provider,
      fit: single ? BoxFit.contain : BoxFit.cover,
      width: fw,
      height: fh,
      gaplessPlayback: true,
      excludeFromSemantics: true,
      filterQuality: FilterQuality.medium,
      frameBuilder: (context, child, frame, sync) {
        if (sync || reduced) return child;
        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: child,
        );
      },
      errorBuilder: (context, error, stack) {
        // Bytes the platform decoder rejects: show the failure instead.
        if (!_decodeFailed) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _decodeFailed) return;
            setState(() => _decodeFailed = true);
            widget.onResult?.call(widget.image.src, false);
          });
        }
        return _FailedFrame(style: widget.style);
      },
    );
  }
}

class _LoadingFrame extends StatelessWidget {
  const _LoadingFrame({required this.style});
  final MarkdownStyle style;

  // Static on purpose: no shimmer, so a loading image costs no frames.
  @override
  Widget build(BuildContext context) => Center(
    child: Icon(
      Icons.image_outlined,
      size: 28,
      color: style.textMuted.withValues(alpha: style.textMuted.a * 0.5),
    ),
  );
}

class _FailedFrame extends StatelessWidget {
  const _FailedFrame({required this.style});
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 28, color: style.textMuted),
            const SizedBox(height: 6),
            Text(
              'Image unavailable',
              style: style.caption.copyWith(color: style.textMuted),
            ),
            Text(
              'Tap to retry',
              style: style.caption.copyWith(
                color: style.textMuted.withValues(
                  alpha: style.textMuted.a * 0.7,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Shows [images] full screen from [initial]: pinch to zoom, swipe between
/// images, with the caption and source action below.
Future<void> showMdImageViewer(
  BuildContext context, {
  required List<MdImage> images,
  required int initial,
  required MarkdownImageLoader loader,
  required MarkdownStyle style,
  required void Function(String href) onLinkTap,
}) {
  final reduced = Motion.reduced(context);
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      barrierDismissible: true,
      barrierLabel: 'Close image',
      transitionDuration: reduced
          ? Duration.zero
          : const Duration(milliseconds: 200),
      reverseTransitionDuration: reduced
          ? Duration.zero
          : const Duration(milliseconds: 160),
      pageBuilder: (context, _, _) => MdImageViewer(
        images: images,
        initial: initial,
        loader: loader,
        style: style,
        onLinkTap: onLinkTap,
      ),
      transitionsBuilder: (context, a, _, child) =>
          FadeTransition(opacity: a, child: child),
    ),
  );
}

class MdImageViewer extends StatefulWidget {
  const MdImageViewer({
    super.key,
    required this.images,
    required this.initial,
    required this.loader,
    required this.style,
    required this.onLinkTap,
  });

  final List<MdImage> images;
  final int initial;
  final MarkdownImageLoader loader;
  final MarkdownStyle style;
  final void Function(String href) onLinkTap;

  @override
  State<MdImageViewer> createState() => _MdImageViewerState();
}

class _MdImageViewerState extends State<MdImageViewer> {
  late final _pages = PageController(initialPage: widget.initial);
  late int _index = widget.initial;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    final im = widget.images[_index];
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    const fg = Colors.white;
    final muted = Colors.white.withValues(alpha: 0.72);
    return Material(
      color: Colors.black,
      child: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Close',
                  color: fg,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                const Spacer(),
                if (widget.images.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Text(
                      '${_index + 1} of ${widget.images.length}',
                      style: s.caption.copyWith(color: muted),
                    ),
                  ),
              ],
            ),
            Expanded(
              child: PageView.builder(
                controller: _pages,
                itemCount: widget.images.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) {
                  final image = widget.loader.peek(widget.images[i].src)?.image;
                  if (image == null) {
                    return Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: muted,
                        size: 40,
                      ),
                    );
                  }
                  return InteractiveViewer(
                    maxScale: 5,
                    child: Center(
                      child: Image.memory(
                        image.bytes,
                        cacheWidth: (size.width * dpr * 2).ceil().clamp(
                          1,
                          4096,
                        ),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        semanticLabel: widget.images[i].alt.trim().isEmpty
                            ? 'Image'
                            : widget.images[i].alt.trim(),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (im.caption.isNotEmpty)
                    Text(
                      im.caption,
                      style: s.body.copyWith(color: fg),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (im.host.isNotEmpty)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: fg,
                          padding: EdgeInsets.zero,
                        ),
                        onPressed: () => widget.onLinkTap(im.sourceHref),
                        icon: const Icon(Icons.north_east_rounded, size: 16),
                        label: Text(
                          im.source != null
                              ? 'Source: ${im.host}'
                              : 'Open from ${im.host}',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
