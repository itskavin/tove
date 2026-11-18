/// What the bridge allows for attachments (`docs/design/bridge-requests.md`,
/// "Attachments"). Every value has a client-side default, so a bridge that
/// reports `attachments: true` without `attachment_limits` still works.
class AttachmentLimits {
  const AttachmentLimits({
    this.maxItems = 4,
    this.imageBytes = 10 * _mb,
    this.fileBytes = 25 * _mb,
    this.imageMaxEdge = 2048,
    this.jpegQuality = 85,
    this.mimes = defaultMimes,
  });

  static const _mb = 1024 * 1024;

  /// Read from capabilities' `attachment_limits`. Unknown or invalid values
  /// keep the defaults; values are never raised past what the server says.
  factory AttachmentLimits.fromJson(Object? json) {
    const d = AttachmentLimits();
    if (json is! Map) return d;
    int pos(Object? v, int fallback) =>
        v is num && v > 0 && v.isFinite ? v.toInt() : fallback;
    int mb(Object? v, int fallback) =>
        v is num && v > 0 && v.isFinite ? (v * _mb).round() : fallback;
    final mimes = json['mimes'];
    return AttachmentLimits(
      maxItems: pos(json['max_items'], d.maxItems),
      imageBytes: mb(json['image_mb'], d.imageBytes),
      fileBytes: mb(json['file_mb'], d.fileBytes),
      imageMaxEdge: pos(json['image_max_edge'], d.imageMaxEdge),
      mimes: mimes is List && mimes.isNotEmpty
          ? [
              for (final m in mimes)
                if (m is String && m.contains('/')) m.toLowerCase(),
            ]
          : d.mimes,
    );
  }

  /// At most this many staged items per message.
  final int maxItems;

  /// Largest image after on-device downscaling and re-encoding.
  final int imageBytes;

  /// Largest document.
  final int fileBytes;

  /// Images are downscaled to this many pixels on the long edge.
  final int imageMaxEdge;

  /// JPEG quality for re-encoded images (0–100).
  final int jpegQuality;

  /// Allowed MIME types; `type/*` matches a whole family.
  final List<String> mimes;

  static const defaultMimes = [
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/heic',
    'image/heif',
    'application/pdf',
    'text/*',
    'application/json',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'application/vnd.oasis.opendocument.text',
    'application/vnd.oasis.opendocument.spreadsheet',
  ];

  bool allows(String mime) {
    final m = mime.toLowerCase();
    for (final a in mimes) {
      if (a == m) return true;
      if (a.endsWith('/*') && m.startsWith(a.substring(0, a.length - 1))) {
        return true;
      }
    }
    return false;
  }

  @override
  bool operator ==(Object other) =>
      other is AttachmentLimits &&
      other.maxItems == maxItems &&
      other.imageBytes == imageBytes &&
      other.fileBytes == fileBytes &&
      other.imageMaxEdge == imageMaxEdge &&
      other.jpegQuality == jpegQuality &&
      _listEq(other.mimes, mimes);

  @override
  int get hashCode => Object.hash(
    maxItems,
    imageBytes,
    fileBytes,
    imageMaxEdge,
    jpegQuality,
    Object.hashAll(mimes),
  );
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The attachment part of `GET /api/capabilities`. Kept apart from the chat
/// `Capabilities` model so this module has no dependency on it: build it
/// from the same JSON with [AttachmentCapabilities.fromJson], or from the
/// existing flag with [AttachmentCapabilities.flag].
class AttachmentCapabilities {
  const AttachmentCapabilities({
    this.attachments = false,
    this.vision = false,
    this.webSearch = false,
    this.limits = const AttachmentLimits(),
  });

  /// From the existing `Capabilities.attachments` flag alone.
  const AttachmentCapabilities.flag(bool attachments)
    : this(attachments: attachments);

  factory AttachmentCapabilities.fromJson(Map<String, dynamic> j) =>
      AttachmentCapabilities(
        attachments: j['attachments'] == true,
        vision: j['vision'] == true,
        webSearch: j['web_search'] == true,
        limits: AttachmentLimits.fromJson(j['attachment_limits']),
      );

  /// `POST /api/uploads` exists and `/api/chat` takes attachment ids.
  final bool attachments;

  /// Hermes' model sees images. Without it images are still sent, as files.
  final bool vision;

  /// `/api/chat` honours `web_search: true`.
  final bool webSearch;
  final AttachmentLimits limits;
}

/// "4.2 MB", "880 KB", "12 B".
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb < 10 ? kb.toStringAsFixed(1) : kb.round()} KB';
  final mb = kb / 1024;
  return '${mb < 10 ? mb.toStringAsFixed(1) : mb.round()} MB';
}
