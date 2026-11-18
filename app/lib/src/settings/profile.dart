/// The user's profile: a display name and a photo (synced as the namespaced
/// settings key `app.profile`, so every device shows the same avatar).
///
/// The photo is uploaded through `POST /api/uploads` ([photoId] is the
/// reference). The bridge drops uploads no message uses after a day, so a
/// small circular JPEG thumbnail ([thumb], base64, about 5 KB) travels in the
/// settings too and is what the avatar draws.
class Profile {
  const Profile({this.name = '', this.photoId, this.thumb});

  static const syncKey = 'app.profile';
  static const empty = Profile();

  final String name;
  final String? photoId;

  /// Base64 JPEG, without a `data:` prefix.
  final String? thumb;

  bool get hasPhoto => (thumb ?? '').isNotEmpty;

  static Profile fromJson(Object? j) {
    if (j is! Map) return empty;
    String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
    final photo = j['photo'];
    return Profile(
      name: s(j['name']) ?? '',
      photoId: photo is Map ? s(photo['upload_id']) : null,
      thumb: photo is Map ? s(photo['thumb']) : null,
    );
  }

  /// Null when empty (removes the key).
  Map<String, Object?>? toJson() => name.isEmpty && !hasPhoto
      ? null
      : {
          if (name.isNotEmpty) 'name': name,
          if (hasPhoto) 'photo': {'upload_id': ?photoId, 'thumb': thumb},
        };

  Profile copyWith({String? name, String? photoId, String? thumb}) => Profile(
    name: name ?? this.name,
    photoId: photoId ?? this.photoId,
    thumb: thumb ?? this.thumb,
  );

  Profile withoutPhoto() => Profile(name: name);

  @override
  bool operator ==(Object other) =>
      other is Profile &&
      other.name == name &&
      other.photoId == photoId &&
      other.thumb == thumb;

  @override
  int get hashCode => Object.hash(name, photoId, thumb);
}

/// Up to two initials of [name] ("Alex R" → "KR"), or "" for none.
String profileInitials(String name) => name
    .trim()
    .split(RegExp(r'\s+'))
    .where((p) => p.isNotEmpty)
    .map((p) => String.fromCharCodes(p.runes.take(1)).toUpperCase())
    .take(2)
    .join();
