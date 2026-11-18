/// Entity info and page pictures from the bridge (round 8).
///
/// `GET /api/entity/info` answers with a Wikipedia summary of a person,
/// place, organisation or thing, and `/api/link-preview` with a page's
/// preview picture. The entity cards and the entity sheet use them when the
/// reply itself has no picture or summary (Hermes rarely has image URLs for
/// entities and news). Nothing here fetches a remote site directly.
library;

import 'package:flutter/foundation.dart';

import 'md_images.dart';

/// One entity's summary (bridge `GET /api/entity/info`).
@immutable
class EntityInfo {
  const EntityInfo({
    required this.title,
    this.description,
    this.extract,
    this.image,
    this.originalImage,
    this.page,
  });

  final String title;

  /// The short line under the name ("American business executive").
  final String? description;

  /// A few plain sentences.
  final String? extract;

  /// A small picture (a thumbnail URL) and the full one; load both through
  /// the bridge's image proxy.
  final String? image, originalImage;

  /// The Wikipedia page.
  final String? page;

  static EntityInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    String? str(String k) {
      final v = j[k];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    final title = str('title');
    if (title == null) return null;
    String? https(String k) {
      final v = str(k);
      return v != null && v.startsWith('https://') ? v : null;
    }

    return EntityInfo(
      title: title,
      description: str('description'),
      extract: str('extract'),
      image: https('image'),
      originalImage: https('original_image'),
      page: https('page'),
    );
  }
}

/// Looks entities up through the bridge. A null answer means "nothing
/// known" (no page, an older bridge, offline).
abstract class EntityInfoSource {
  EntityInfo? peekEntityInfo(String name, {String? hint});
  Future<EntityInfo?> entityInfo(String name, {String? hint});
}

/// A web page's preview picture (its og:image), loaded through the bridge.
abstract class PageImageSource {
  LinkImageResult? peekPageImage(String pageUrl);
  Future<LinkImageResult> loadPageImage(String pageUrl);
}
