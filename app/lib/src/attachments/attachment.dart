import 'dart:typed_data';

/// Whether the bridge treats an upload as a picture or a document.
enum AttachmentKind { image, file }

/// Where a picked item came from. Camera shots are always images.
enum AttachmentOrigin { camera, photos, files }

/// A file the user picked, before any processing. [read] is called once per
/// upload attempt, so a retry re-reads it (picker results are temp files the
/// platform keeps until the app clears them).
class AttachmentSource {
  AttachmentSource({
    required this.name,
    required this.mime,
    required this.size,
    required this.read,
    this.origin = AttachmentOrigin.files,
  });

  /// A source whose bytes are already in memory (tests, paste).
  factory AttachmentSource.bytes(
    String name,
    Uint8List bytes, {
    String? mime,
    AttachmentOrigin origin = AttachmentOrigin.files,
  }) => AttachmentSource(
    name: name,
    mime: mime ?? mimeForName(name),
    size: bytes.length,
    read: () async => bytes,
    origin: origin,
  );

  final String name;
  final String mime;

  /// As reported by the picker; images shrink after processing.
  final int size;
  final Future<Uint8List> Function() read;
  final AttachmentOrigin origin;

  bool get isImage => mime.startsWith('image/');
}

/// `POST /api/uploads` → this.
class UploadedAttachment {
  const UploadedAttachment({
    required this.id,
    required this.name,
    required this.mime,
    required this.size,
    required this.kind,
    this.sha256,
    this.width,
    this.height,
    this.previewUrl,
  });

  factory UploadedAttachment.fromJson(Map<String, dynamic> j) {
    final id = j['id'] ?? j['upload_id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('upload answer has no id');
    }
    int? n(Object? v) => v is num ? v.toInt() : null;
    String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
    return UploadedAttachment(
      id: id,
      name: s(j['name']) ?? 'file',
      mime: s(j['mime']) ?? 'application/octet-stream',
      size: n(j['size']) ?? 0,
      kind: j['kind'] == 'image' ? AttachmentKind.image : AttachmentKind.file,
      sha256: s(j['sha256']),
      width: n(j['width']),
      height: n(j['height']),
      previewUrl: s(j['preview_url']),
    );
  }

  final String id;
  final String name;
  final String mime;
  final int size;
  final AttachmentKind kind;
  final String? sha256;
  final int? width;
  final int? height;

  /// Relative to the bridge base URL, for example `/api/uploads/u_1/preview`.
  final String? previewUrl;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mime': mime,
    'size': size,
    'kind': kind.name,
    'sha256': ?sha256,
    'width': ?width,
    'height': ?height,
    'preview_url': ?previewUrl,
  };
}

/// A best guess from the file name; the bridge sniffs the content again.
String mimeForName(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return _mimes[ext] ?? 'application/octet-stream';
}

const _mimes = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
  'gif': 'image/gif',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'bmp': 'image/bmp',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'markdown': 'text/markdown',
  'csv': 'text/csv',
  'tsv': 'text/tab-separated-values',
  'log': 'text/plain',
  'html': 'text/html',
  'htm': 'text/html',
  'xml': 'text/xml',
  'yaml': 'text/yaml',
  'yml': 'text/yaml',
  'json': 'application/json',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'odt': 'application/vnd.oasis.opendocument.text',
  'ods': 'application/vnd.oasis.opendocument.spreadsheet',
  'zip': 'application/zip',
};

/// The name cut in the middle so the extension stays visible:
/// `quarterly-repo…2026.pdf` (§5.2: 22 characters).
String middleEllipsis(String name, [int max = 22]) {
  if (name.length <= max) return name;
  final keepEnd = (max - 1) ~/ 2;
  final keepStart = max - 1 - keepEnd;
  return '${name.substring(0, keepStart)}…'
      '${name.substring(name.length - keepEnd)}';
}
