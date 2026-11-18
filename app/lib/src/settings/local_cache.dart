import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'local_cache_files.dart'
    if (dart.library.js_interop) 'local_cache_files_web.dart'
    as files;

/// Settings › Data controls › "Images and attachments": what this device
/// keeps that the server can send again (decoded images, picked
/// attachments copied to the cache directory).
abstract interface class LocalCache {
  /// Bytes in use, or null when unknown.
  Future<int?> size();

  /// Frees it. Voice downloads, settings and the access key are kept.
  Future<void> clear();
}

class AppLocalCache implements LocalCache {
  const AppLocalCache();

  @override
  Future<int?> size() async {
    var bytes = PaintingBinding.instance.imageCache.currentSizeBytes;
    final temp = await files.temporaryBytes();
    if (temp != null) bytes += temp;
    return bytes;
  }

  @override
  Future<void> clear() async {
    final images = PaintingBinding.instance.imageCache;
    images.clear();
    images.clearLiveImages();
    if (!kIsWeb) {
      try {
        await FilePicker.clearTemporaryFiles();
      } catch (_) {
        // Not on this platform.
      }
    }
    await files.clearTemporary();
  }
}

/// A short size like "12 MB" or "840 KB".
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  final mb = bytes / (1024 * 1024);
  return mb < 10 ? '${mb.toStringAsFixed(1)} MB' : '${mb.round()} MB';
}
