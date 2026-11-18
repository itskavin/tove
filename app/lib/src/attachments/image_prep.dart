import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

import 'attachment_limits.dart';

/// An image ready for upload: at most [AttachmentLimits.imageMaxEdge] on the
/// long edge, orientation baked in, and no metadata (EXIF, GPS, XMP, text
/// chunks) (spec §5.2).
class PreparedImage {
  const PreparedImage({
    required this.bytes,
    required this.mime,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final String mime;
  final int width;
  final int height;
}

class ImagePrepException implements Exception {
  const ImagePrepException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Turns a picked image into an upload. Injected so tests skip the codecs.
abstract interface class ImagePreparer {
  Future<PreparedImage> prepare(Uint8List bytes, AttachmentLimits limits);
}

/// Decodes with `package:image` on a background isolate (JPEG, PNG, WebP,
/// GIF, BMP, TIFF). Anything it cannot read, HEIC in particular, goes
/// through the engine's platform codec, which on Android uses the system
/// decoder. Opaque images become JPEG at [AttachmentLimits.jpegQuality];
/// images with transparency stay PNG.
class DefaultImagePreparer implements ImagePreparer {
  const DefaultImagePreparer({this.useIsolate = true});

  /// Off in widget tests, where `Isolate.run` needs `runAsync`.
  final bool useIsolate;

  @override
  Future<PreparedImage> prepare(
    Uint8List bytes,
    AttachmentLimits limits,
  ) async {
    final edge = limits.imageMaxEdge;
    final q = limits.jpegQuality;
    PreparedImage? out = useIsolate
        ? await Isolate.run(() => prepareImageSync(bytes, edge, q))
        : prepareImageSync(bytes, edge, q);
    out ??= await _viaEngine(bytes, edge, q);
    if (out == null) {
      throw const ImagePrepException("This picture's format isn't supported");
    }
    return out;
  }

  static Future<PreparedImage?> _viaEngine(
    Uint8List bytes,
    int edge,
    int quality,
  ) async {
    ui.Codec? codec;
    ui.Image? frame;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final desc = await ui.ImageDescriptor.encoded(buffer);
      final w = desc.width, h = desc.height;
      final scale = w >= h ? edge / w : edge / h;
      codec = await desc.instantiateCodec(
        targetWidth: scale < 1 ? (w * scale).round() : null,
        targetHeight: scale < 1 ? (h * scale).round() : null,
      );
      frame = (await codec.getNextFrame()).image;
      final rgba = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) return null;
      final image = img.Image.fromBytes(
        width: frame.width,
        height: frame.height,
        bytes: rgba.buffer,
        numChannels: 4,
      );
      return _encode(image, quality);
    } catch (_) {
      return null;
    } finally {
      frame?.dispose();
      codec?.dispose();
    }
  }
}

/// The pure-Dart path; null when `package:image` cannot decode [bytes].
PreparedImage? prepareImageSync(Uint8List bytes, int maxEdge, int quality) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    decoded = null;
  }
  if (decoded == null) return null;
  var image = img.bakeOrientation(decoded);
  final long = image.width >= image.height ? image.width : image.height;
  if (long > maxEdge) {
    image = image.width >= image.height
        ? img.copyResize(
            image,
            width: maxEdge,
            interpolation: img.Interpolation.average,
          )
        : img.copyResize(
            image,
            height: maxEdge,
            interpolation: img.Interpolation.average,
          );
  }
  return _encode(image, quality);
}

PreparedImage _encode(img.Image image, int quality) {
  image
    ..exif = img.ExifData()
    ..textData = null;
  final alpha = image.hasAlpha && _usesAlpha(image);
  if (alpha) {
    return PreparedImage(
      bytes: img.encodePng(image),
      mime: 'image/png',
      width: image.width,
      height: image.height,
    );
  }
  return PreparedImage(
    bytes: img.encodeJpg(image, quality: quality),
    mime: 'image/jpeg',
    width: image.width,
    height: image.height,
  );
}

/// True when any pixel is not fully opaque (sampled on large images).
bool _usesAlpha(img.Image image) {
  final step = (image.width * image.height / 250000).ceil().clamp(1, 64);
  var i = 0;
  for (final p in image) {
    if (i++ % step == 0 && p.a < p.maxChannelValue) return true;
  }
  return false;
}
