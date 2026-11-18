import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'attachment.dart';

/// Why a pick failed (a cancel is not a failure: it returns an empty list).
enum PickErrorKind {
  /// The user refused the camera permission.
  permissionDenied,

  /// No camera, or no app answers the intent.
  unavailable,
  other,
}

class PickException implements Exception {
  const PickException(this.kind, this.message);
  final PickErrorKind kind;
  final String message;
  @override
  String toString() => message;
}

/// Opens the system pickers. Injected so tests use a fake.
abstract interface class AttachmentPicker {
  /// One photo from the camera, or nothing.
  Future<List<AttachmentSource>> camera();

  /// Up to [max] images from the system photo picker.
  Future<List<AttachmentSource>> photos({required int max});

  /// Up to [max] documents from the system document picker.
  Future<List<AttachmentSource>> files({required int max});
}

/// The platform pickers. On Android:
///
/// - Photos: `image_picker`, which uses the system Photo Picker
///   (`ACTION_PICK_IMAGES`, back-ported through Play services before API 33).
///   No `READ_MEDIA_*` permission.
/// - Camera: `ACTION_IMAGE_CAPTURE` through `image_picker`'s own
///   FileProvider. It asks for `CAMERA` only if the app's manifest declares
///   it.
/// - Files: the Storage Access Framework (`ACTION_OPEN_DOCUMENT`) through
///   `file_picker`. No storage permission.
///
/// Images are not resized here: [ImagePreparer] does that on every
/// platform, so metadata stripping does not depend on the plugin.
class SystemAttachmentPicker implements AttachmentPicker {
  SystemAttachmentPicker({ImagePicker? images})
    : _images = images ?? ImagePicker();

  final ImagePicker _images;

  @override
  Future<List<AttachmentSource>> camera() => _guard(() async {
    final x = await _images.pickImage(
      source: ImageSource.camera,
      requestFullMetadata: false,
    );
    return [if (x != null) await _fromX(x, AttachmentOrigin.camera)];
  });

  @override
  Future<List<AttachmentSource>> photos({required int max}) => _guard(() async {
    if (max <= 0) return const [];
    final List<XFile> xs;
    if (max == 1) {
      final x = await _images.pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: false,
      );
      xs = [?x];
    } else {
      xs = await _images.pickMultiImage(limit: max, requestFullMetadata: false);
    }
    return [
      for (final x in xs.take(max)) await _fromX(x, AttachmentOrigin.photos),
    ];
  });

  @override
  Future<List<AttachmentSource>> files({required int max}) => _guard(() async {
    if (max <= 0) return const [];
    final picked = await fp.FilePicker.pickFiles();
    return [
      for (final f in picked.take(max))
        AttachmentSource(
          name: f.name,
          mime: mimeForName(f.name),
          size: f.lengthSync() ?? await f.length() ?? 0,
          read: f.readAsBytes,
          origin: AttachmentOrigin.files,
        ),
    ];
  });

  static Future<AttachmentSource> _fromX(XFile x, AttachmentOrigin o) async {
    final name = x.name.isEmpty ? 'photo.jpg' : x.name;
    return AttachmentSource(
      name: name,
      mime: x.mimeType ?? mimeForName(name),
      size: await x.length(),
      read: x.readAsBytes,
      origin: o,
    );
  }

  static Future<List<AttachmentSource>> _guard(
    Future<List<AttachmentSource>> Function() f,
  ) async {
    try {
      return await f();
    } on PlatformException catch (e) {
      final code = e.code.toLowerCase();
      if (code.contains('denied') || code.contains('permission')) {
        throw const PickException(
          PickErrorKind.permissionDenied,
          'Camera access is off. Allow it in Settings › Apps › Hermes.',
        );
      }
      if (code.contains('no_available_camera') ||
          code.contains('unavailable')) {
        throw const PickException(
          PickErrorKind.unavailable,
          'No camera is available',
        );
      }
      throw PickException(
        PickErrorKind.other,
        e.message ?? "Couldn't open the picker",
      );
    }
  }
}
