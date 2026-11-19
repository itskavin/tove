/// Places from the bridge's open places service (`GET /api/places/info`;
/// server/API.md "Places": an Overture Maps extract plus OpenStreetMap
/// details). A reply names a place by its stable `place:` id; the card loads
/// the phone, website, hours and position from the bridge, so a model never
/// has to copy them. There are no ratings in open data: a rating shown on a
/// card is the model's, with the listing it came from.
library;

import 'package:flutter/foundation.dart';

/// One place (the bridge's compact shape).
@immutable
class PlaceInfo {
  const PlaceInfo({
    required this.id,
    required this.name,
    this.category,
    this.subtitle,
    this.address,
    this.lat,
    this.lng,
    this.distanceKm,
    this.phone,
    this.website,
    this.hours,
    this.openNow,
    this.wheelchair,
    this.photo,
  });

  final String id, name;
  final String? category, subtitle, address, phone, website, hours;
  final String? wheelchair;

  /// An http(s) picture from OpenStreetMap (`image` or Wikimedia Commons).
  final String? photo;
  final double? lat, lng, distanceKm;
  final bool? openNow;

  bool get located => lat != null && lng != null;

  static PlaceInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    String? s(String k) {
      final v = j[k];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    double? d(String k) => j[k] is num ? (j[k] as num).toDouble() : null;
    String? web(String k) {
      final v = s(k);
      final u = v == null ? null : Uri.tryParse(v);
      return u != null && (u.scheme == 'https' || u.scheme == 'http')
          ? v
          : null;
    }

    final id = s('id'), name = s('name');
    if (id == null || !isPlaceRef(id) || name == null) return null;
    final lat = d('lat'), lng = d('lng');
    final ok =
        lat != null && lng != null && lat.abs() <= 90 && lng.abs() <= 180;
    return PlaceInfo(
      id: id,
      name: name,
      category: s('category'),
      subtitle: s('subtitle'),
      address: s('address'),
      lat: ok ? lat : null,
      lng: ok ? lng : null,
      distanceKm: d('distance_km'),
      phone: s('phone'),
      website: web('website'),
      hours: s('hours'),
      openNow: j['open_now'] is bool ? j['open_now'] as bool : null,
      wheelchair: s('wheelchair'),
      photo: web('photo'),
    );
  }
}

final _placeRef = RegExp(r'^place:[A-Za-z0-9_-]{8,64}$');

/// Whether [v] is a `place:<id>` reference from places_search.
bool isPlaceRef(String? v) => v != null && _placeRef.hasMatch(v);

/// Map tiles the bridge offers (capability `places.map_tiles`); null = a
/// map without tiles (pins on a plain grid).
@immutable
class MapTiles {
  const MapTiles(this.urlTemplate, this.attribution);
  final String urlTemplate;
  final String attribution;
}

/// Looks places up through the bridge. Null means "nothing known" (no
/// places database, an older bridge, offline).
abstract class PlaceInfoSource {
  PlaceInfo? peekPlace(String id);
  Future<PlaceInfo?> placeInfo(String id);

  /// The map tile source, or null when the bridge offers none.
  Future<MapTiles?> mapTiles();
}
