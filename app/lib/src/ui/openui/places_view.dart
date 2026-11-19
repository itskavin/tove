// Places cards and the Map (Tove OpenUI components `Places`/`Place`, `Map`/
// `Pin`). Place details come from the bridge's open places service
// (PlaceInfoSource: Overture Maps + OpenStreetMap) by the `place:` id the
// model copied from places_search; what the model wrote (name, facts, a
// sourced rating) is shown as given. Cards and pins share one selection per
// block: tapping a card centres its pin, tapping a pin scrolls to its card.
// Links (Call, Directions, Website) go through the host confirm sheet.

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../../platform/coarse_location.dart';
import '../interactive/scope.dart';
import '../interactive/ui_entities.dart' show UiRemoteImage;
import '../markdown/markdown_style.dart';
import '../markdown/md_images.dart' show MarkdownImageScope;
import '../markdown/place_info.dart';
import '../shell/drawer_swipe.dart' show DrawerSwipeExclusion;
import '../theme/tokens.dart';

/// One place as the reply wrote it.
@immutable
class OuiPlace {
  const OuiPlace({
    required this.ref,
    required this.name,
    this.subtitle,
    this.facts,
    this.rating,
    this.ratingSource,
    this.phone,
    this.url,
    this.lat,
    this.lng,
  });

  /// `place:<id>` from places_search, or "" (a place found on the web, or a
  /// Pin).
  final String ref;
  final String name;
  final String? subtitle, facts, rating, ratingSource, phone, url;

  /// A Pin's own position.
  final double? lat, lng;

  /// The key cards and pins select by.
  String get key => ref.isNotEmpty ? ref : 'name:$name';

  /// "4.8 · 120 reviews on Practo"; a rating without its source is not shown.
  String? get ratingLine {
    final r = rating?.trim(), src = ratingSource?.trim();
    if (r == null || r.isEmpty || src == null || src.isEmpty) return null;
    return '$r on $src';
  }
}

/// The block's selected place ([OuiPlace.key]), shared by its cards and map.
class OuiPlaceSelection extends ValueNotifier<String?> {
  OuiPlaceSelection() : super(null);
  final Map<String, GlobalKey> cards = {};
}

/// Loads [PlaceInfo] for the `place:` refs among [items].
mixin _PlaceInfos<T extends StatefulWidget> on State<T> {
  final Map<String, PlaceInfo> infos = {};
  PlaceInfoSource? _source;

  List<OuiPlace> get placeItems;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final loader = MarkdownImageScope.of(context);
    final source = loader is PlaceInfoSource ? loader as PlaceInfoSource : null;
    if (identical(source, _source)) return;
    _source = source;
    _load();
  }

  void _load() {
    final source = _source;
    if (source == null) return;
    for (final p in placeItems) {
      if (!isPlaceRef(p.ref) || infos.containsKey(p.ref)) continue;
      final known = source.peekPlace(p.ref);
      if (known != null) {
        infos[p.ref] = known;
        continue;
      }
      source.placeInfo(p.ref).then((info) {
        if (info != null && mounted) setState(() => infos[p.ref] = info);
      });
    }
    onSourceReady(source);
  }

  void onSourceReady(PlaceInfoSource source) {}
}

IconData placeIcon(String? category) {
  final c = (category ?? '').toLowerCase();
  bool has(List<String> w) => w.any(c.contains);
  if (has(['dent'])) return Icons.medical_services_outlined;
  if (has(['psych', 'mental', 'counsel'])) return Icons.psychology_outlined;
  if (has(['hospital', 'clinic', 'doctor', 'health', 'physi', 'medic'])) {
    return Icons.local_hospital_outlined;
  }
  if (has(['pharm', 'chemist'])) return Icons.local_pharmacy_outlined;
  if (has(['cafe', 'coffee', 'tea'])) return Icons.local_cafe_outlined;
  if (has(['restaurant', 'food', 'eatery', 'biryani', 'bakery', 'bar'])) {
    return Icons.restaurant_outlined;
  }
  if (has(['hotel', 'lodg', 'resort'])) return Icons.hotel_outlined;
  if (has(['school', 'college', 'learning', 'universit'])) {
    return Icons.school_outlined;
  }
  if (has(['gym', 'fitness', 'sport'])) return Icons.fitness_center_outlined;
  if (has(['shop', 'store', 'market', 'mall'])) {
    return Icons.storefront_outlined;
  }
  if (has(['bank', 'atm', 'financ'])) return Icons.account_balance_outlined;
  if (has(['park', 'garden'])) return Icons.park_outlined;
  if (has(['temple', 'church', 'mosque', 'worship'])) {
    return Icons.temple_hindu_outlined;
  }
  return Icons.place_outlined;
}

/// The link that opens directions to a place in the user's maps app.
String? directionsUrl(OuiPlace p, PlaceInfo? info) {
  final lat = info?.lat ?? p.lat, lng = info?.lng ?? p.lng;
  if (lat != null && lng != null) {
    final label = Uri.encodeComponent(p.name);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'geo:$lat,$lng?q=$lat,$lng($label)';
    }
    return 'https://www.openstreetmap.org/directions?to=$lat%2C$lng';
  }
  final q = [p.name, p.subtitle ?? info?.address ?? ''].join(' ').trim();
  return 'https://www.openstreetmap.org/search?query=${Uri.encodeComponent(q)}';
}

String? telUrl(String? phone) {
  final digits = (phone ?? '').replaceAll(RegExp(r'[^\d+]'), '');
  return digits.length < 5 ? null : 'tel:$digits';
}

class OuiPlacesView extends StatefulWidget {
  const OuiPlacesView({
    super.key,
    required this.items,
    required this.selection,
    required this.style,
  });

  final List<OuiPlace> items;
  final OuiPlaceSelection selection;
  final MarkdownStyle style;

  @override
  State<OuiPlacesView> createState() => _OuiPlacesViewState();
}

class _OuiPlacesViewState extends State<OuiPlacesView>
    with _PlaceInfos<OuiPlacesView> {
  @override
  List<OuiPlace> get placeItems => widget.items;

  @override
  void didUpdateWidget(OuiPlacesView old) {
    super.didUpdateWidget(old);
    if (old.items.length != widget.items.length) _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    return ValueListenableBuilder<String?>(
      valueListenable: widget.selection,
      builder: (context, selected, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, p) in widget.items.indexed) ...[
            if (i > 0) const SizedBox(height: 10),
            _PlaceCard(
              key: widget.selection.cards.putIfAbsent(p.key, GlobalKey.new),
              index: i + 1,
              place: p,
              info: infos[p.ref],
              selected: selected == p.key,
              onSelect: () => widget.selection.value = p.key,
              style: s,
            ),
          ],
        ],
      ),
    );
  }
}

class _PlaceCard extends StatelessWidget {
  const _PlaceCard({
    super.key,
    required this.index,
    required this.place,
    required this.info,
    required this.selected,
    required this.onSelect,
    required this.style,
  });

  final int index;
  final OuiPlace place;
  final PlaceInfo? info;
  final bool selected;
  final VoidCallback onSelect;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final t = HermesTokens.of(context);
    final h = UiActionHandler.of(context);
    final p = place;
    final sub = p.subtitle ?? info?.subtitle;
    final dist = info?.distanceKm;
    final where = [
      ?sub,
      if (dist != null) '${dist.toStringAsFixed(dist < 10 ? 1 : 0)} km',
    ].join(' · ');
    final phone = info?.phone ?? p.phone;
    final website = info?.website ?? (_web(p.url) ? p.url : null);
    final open = info?.openNow;
    final hours = info?.hours;
    final rating = p.ratingLine;
    final tel = telUrl(phone);
    final small = s.caption.copyWith(color: s.textMuted);
    final photo = info?.photo;

    final details = <Widget>[
      Text(p.name, style: s.body.copyWith(fontWeight: FontWeight.w600)),
      if (where.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(where, style: small),
        ),
      if (rating != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Icon(Icons.star_rounded, size: 16, color: s.warning),
              const SizedBox(width: 4),
              Flexible(
                child: Text(rating, style: s.caption.copyWith(color: s.text)),
              ),
            ],
          ),
        ),
      if (open != null || hours != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text.rich(
            TextSpan(
              children: [
                if (open != null)
                  TextSpan(
                    text: open ? 'Open now' : 'Closed now',
                    style: s.caption.copyWith(
                      color: open ? s.success : s.danger,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (open != null && hours != null) const TextSpan(text: ' · '),
                if (hours != null) TextSpan(text: hours),
              ],
            ),
            style: small,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      if (p.facts != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(p.facts!, style: s.caption.copyWith(color: s.text)),
        ),
    ];
    final actions = [
      if (tel != null)
        _Action(Icons.call_outlined, 'Call', () => h.openLink(tel)),
      _Action(Icons.directions_outlined, 'Directions', () {
        final u = directionsUrl(p, info);
        if (u != null) h.openLink(u);
      }),
      if (website != null)
        _Action(Icons.language_rounded, 'Website', () => h.openLink(website)),
    ];

    return Semantics(
      container: true,
      selected: selected,
      label: 'Place $index of the list: ${p.name}',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onSelect,
          borderRadius: BorderRadius.circular(s.frameRadius + 4),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            decoration: BoxDecoration(
              border: Border.all(
                color: selected ? t.accent : s.outline,
                width: selected ? 1.5 : 1,
              ),
              borderRadius: BorderRadius.circular(s.frameRadius + 4),
            ),
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Badge(index: index, selected: selected),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: details,
                      ),
                    ),
                    const SizedBox(width: 10),
                    _PlacePhoto(
                      photo: photo,
                      website: website,
                      icon: placeIcon(info?.category ?? sub),
                      style: s,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(spacing: 4, children: actions),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static bool _web(String? u) {
    final uri = Uri.tryParse(u ?? '');
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty;
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.index, required this.selected});
  final int index;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return ExcludeSemantics(
      child: Container(
        width: 24,
        height: 24,
        margin: const EdgeInsets.only(top: 1),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? t.accent : t.accent.withValues(alpha: 0.14),
          shape: BoxShape.circle,
        ),
        child: Text(
          '$index',
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: selected ? t.onAccent : t.accent,
          ),
        ),
      ),
    );
  }
}

/// The OSM photo, else the website's preview picture, over a category icon
/// tile that stays when neither loads.
class _PlacePhoto extends StatelessWidget {
  const _PlacePhoto({
    required this.photo,
    required this.website,
    required this.icon,
    required this.style,
  });
  final String? photo, website;
  final IconData icon;
  final MarkdownStyle style;

  static const size = 72.0;

  @override
  Widget build(BuildContext context) {
    final s = style;
    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: s.surfaceHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 28, color: s.textMuted),
            ),
            if (photo != null || website != null)
              UiRemoteImage(
                url: photo,
                pageUrl: photo == null ? website : null,
                width: size,
                height: size,
                radius: 12,
                style: s,
                collapseWhenEmpty: true,
              ),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: t.accent,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
    );
  }
}

// ── Map

class OuiMapView extends StatefulWidget {
  const OuiMapView({
    super.key,
    required this.items,
    required this.selection,
    required this.style,
    this.zoom,
  });

  final List<OuiPlace> items;
  final OuiPlaceSelection selection;
  final MarkdownStyle style;
  final double? zoom;

  @override
  State<OuiMapView> createState() => _OuiMapViewState();
}

class _OuiMapViewState extends State<OuiMapView> with _PlaceInfos<OuiMapView> {
  final _map = MapController();
  MapTiles? _tiles;
  bool _ready = false;

  @override
  List<OuiPlace> get placeItems => widget.items;

  @override
  void onSourceReady(PlaceInfoSource source) {
    source.mapTiles().then((t) {
      if (mounted && t != null) setState(() => _tiles = t);
    });
  }

  @override
  void initState() {
    super.initState();
    widget.selection.addListener(_onSelect);
  }

  @override
  void didUpdateWidget(OuiMapView old) {
    super.didUpdateWidget(old);
    if (!identical(old.selection, widget.selection)) {
      old.selection.removeListener(_onSelect);
      widget.selection.addListener(_onSelect);
    }
    if (old.items.length != widget.items.length) _load();
  }

  @override
  void dispose() {
    widget.selection.removeListener(_onSelect);
    _map.dispose();
    super.dispose();
  }

  LatLng? _point(OuiPlace p) {
    final i = infos[p.ref];
    final lat = i?.lat ?? p.lat, lng = i?.lng ?? p.lng;
    return lat == null || lng == null ? null : LatLng(lat, lng);
  }

  void _onSelect() {
    final key = widget.selection.value;
    if (key == null || !_ready) return;
    final p = widget.items.where((x) => x.key == key).firstOrNull;
    final pt = p == null ? null : _point(p);
    if (pt != null) _map.move(pt, _map.camera.zoom);
  }

  void _selectPin(OuiPlace p) {
    widget.selection.value = p.key;
    final card = widget.selection.cards[p.key]?.currentContext;
    if (card != null) {
      Scrollable.ensureVisible(
        card,
        duration: const Duration(milliseconds: 240),
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    final t = HermesTokens.of(context);
    final pins = [
      for (final (i, p) in widget.items.indexed)
        if (_point(p) case final pt?) (i + 1, p, pt),
    ];
    if (pins.isEmpty) return const SizedBox.shrink();
    // Re-fit the camera when the set of located pins changes (infos arrive).
    final key = pins.map((x) => x.$2.key).join('|');
    final points = [for (final x in pins) x.$3];
    final options = MapOptions(
      initialCenter: points.first,
      initialZoom: widget.zoom ?? 14,
      initialCameraFit: points.length > 1 && widget.zoom == null
          ? CameraFit.coordinates(
              coordinates: points,
              padding: const EdgeInsets.fromLTRB(36, 44, 36, 36),
              maxZoom: 16,
            )
          : null,
      backgroundColor: s.surfaceHigh,
      interactionOptions: const InteractionOptions(
        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
      ),
      onMapReady: () => _ready = true,
    );
    final tiles = _tiles;
    final names = pins.map((x) => '${x.$1}, ${x.$2.name}').join('; ');
    return Semantics(
      container: true,
      label:
          'Map of ${pins.length} ${pins.length == 1 ? 'place' : 'places'}: '
          '$names',
      child: DrawerSwipeExclusion(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(s.frameRadius + 4),
          child: Container(
            height: 232,
            decoration: BoxDecoration(
              border: Border.all(color: s.outline),
              borderRadius: BorderRadius.circular(s.frameRadius + 4),
            ),
            child: ValueListenableBuilder<String?>(
              valueListenable: widget.selection,
              builder: (context, selected, _) => FlutterMap(
                key: ValueKey(key),
                mapController: _map,
                options: options,
                children: [
                  if (tiles != null)
                    TileLayer(
                      urlTemplate: tiles.urlTemplate,
                      userAgentPackageName: 'io.github.tovechat.tove',
                      maxZoom: 19,
                    )
                  else
                    _Grid(color: s.hairline),
                  MarkerLayer(
                    markers: [
                      for (final (n, p, pt) in pins)
                        Marker(
                          point: pt,
                          width: 48,
                          height: 48,
                          child: _Pin(
                            index: n,
                            name: p.name,
                            selected: selected == p.key,
                            accent: t.accent,
                            onAccent: t.onAccent,
                            onTap: () => _selectPin(p),
                          ),
                        ),
                    ],
                  ),
                  if (tiles != null && tiles.attribution.isNotEmpty)
                    Align(
                      alignment: Alignment.bottomRight,
                      child: Container(
                        margin: const EdgeInsets.all(4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: s.background.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          tiles.attribution,
                          style: s.caption.copyWith(
                            fontSize: 10,
                            color: s.textMuted,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin({
    required this.index,
    required this.name,
    required this.selected,
    required this.accent,
    required this.onAccent,
    required this.onTap,
  });
  final int index;
  final String name;
  final bool selected;
  final Color accent, onAccent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final size = selected ? 34.0 : 28.0;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Pin $index, $name',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? accent : Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: accent, width: 2),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
            ),
            child: Text(
              '$index',
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: selected ? onAccent : accent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A plain grid where no tiles are offered (and in tests).
class _Grid extends StatelessWidget {
  const _Grid({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _GridPainter(color), size: Size.infinite);
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 32) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += 32) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color;
}

/// The message sent after the user shares their location from a reply.
const locationSharedMessage =
    "I've turned on my approximate location. Please answer again for near me.";

/// `LocationButton`: turns on "Use my approximate location" (permission
/// prompt first) and asks the question again. Hidden where the device can't
/// share a location or it is already on.
class OuiLocationButton extends StatefulWidget {
  const OuiLocationButton({
    super.key,
    required this.label,
    required this.style,
  });
  final String label;
  final MarkdownStyle style;

  @override
  State<OuiLocationButton> createState() => _OuiLocationButtonState();
}

class _OuiLocationButtonState extends State<OuiLocationButton> {
  bool _busy = false;
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    final service = LocationScope.maybeOf(context);
    final h = UiActionHandler.of(context);
    if (service == null || !service.available || service.enabled) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        OutlinedButton.icon(
          onPressed: _busy || !h.canSend || h.nextUserMessage != null
              ? null
              : () async {
                  setState(() => _busy = true);
                  final ok = await service.enable();
                  if (!mounted) return;
                  setState(() {
                    _busy = false;
                    _failed = !ok;
                  });
                  if (ok) h.send(locationSharedMessage);
                },
          icon: const Icon(Icons.near_me_outlined, size: 18),
          label: Text(widget.label),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
        if (_failed)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Location is off or not allowed for Tove.',
              style: widget.style.caption.copyWith(
                color: widget.style.textMuted,
              ),
            ),
          ),
      ],
    );
  }
}
