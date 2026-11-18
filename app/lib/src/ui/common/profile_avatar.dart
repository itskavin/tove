import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../settings/profile.dart';
import '../theme/tokens.dart';

/// The user's round avatar: the synced profile photo, else the initials of
/// [name], else a person glyph.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    required this.profile,
    required this.name,
    this.size = 40,
  });

  final Profile profile;
  final String name;
  final double size;

  static final _decoded = <String, Uint8List?>{};

  static Uint8List? _bytes(String? thumb) {
    if (thumb == null || thumb.isEmpty) return null;
    return _decoded.putIfAbsent(thumb, () {
      try {
        return base64Decode(thumb);
      } catch (_) {
        return null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final bytes = _bytes(profile.thumb);
    final initials = profileInitials(name);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: t.surfaceHigh, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: bytes != null
            ? Image.memory(
                bytes,
                width: size,
                height: size,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => _fallback(t, initials),
              )
            : _fallback(t, initials),
      ),
    );
  }

  Widget _fallback(HermesTokens t, String initials) => initials.isEmpty
      ? Icon(Icons.person_rounded, size: size * 0.55, color: t.textMuted)
      : Text(
          initials,
          style: t.label
              .copyWith(color: t.text, fontSize: size * 0.36, height: 1)
              .hermesWeight(600),
        );
}
