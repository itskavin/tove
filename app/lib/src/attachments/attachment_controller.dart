import 'package:flutter/foundation.dart';

import 'attachment.dart';
import 'attachment_limits.dart';
import 'image_prep.dart';
import 'picker.dart';
import 'upload_client.dart';

enum StagedStatus {
  /// Reading and, for images, downscaling and stripping metadata.
  preparing,
  uploading,
  uploaded,
  failed,
}

/// One item in the composer's strip.
@immutable
class StagedAttachment {
  const StagedAttachment({
    required this.localId,
    required this.name,
    required this.mime,
    required this.size,
    required this.kind,
    this.status = StagedStatus.preparing,
    this.progress = 0,
    this.preview,
    this.error,
    this.retryable = true,
    this.uploaded,
  });

  final String localId;
  final String name;
  final String mime;

  /// Bytes that will be (or were) uploaded.
  final int size;
  final AttachmentKind kind;
  final StagedStatus status;

  /// 0…1 while [StagedStatus.uploading].
  final double progress;

  /// The prepared image, for the thumbnail.
  final Uint8List? preview;
  final String? error;

  /// False when trying again cannot help (too large, unsupported).
  final bool retryable;
  final UploadedAttachment? uploaded;

  bool get isImage => kind == AttachmentKind.image;
  bool get busy =>
      status == StagedStatus.preparing || status == StagedStatus.uploading;

  StagedAttachment copyWith({
    String? mime,
    int? size,
    StagedStatus? status,
    double? progress,
    Uint8List? preview,
    String? error,
    bool clearError = false,
    bool? retryable,
    UploadedAttachment? uploaded,
  }) => StagedAttachment(
    localId: localId,
    name: name,
    mime: mime ?? this.mime,
    size: size ?? this.size,
    kind: kind,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    preview: preview ?? this.preview,
    error: clearError ? null : error ?? this.error,
    retryable: retryable ?? this.retryable,
    uploaded: uploaded ?? this.uploaded,
  );
}

/// Stages, prepares and uploads the composer's attachments.
///
/// The composer shows [items]; the shell sends [uploaded] ids with the
/// message once [ready] and then calls [clear]. Notices (limits, picker
/// errors) are returned to the caller to show as toasts.
class AttachmentController extends ChangeNotifier {
  AttachmentController({
    required this.uploader,
    this.picker,
    this.preparer = const DefaultImagePreparer(),
    AttachmentCapabilities capabilities = const AttachmentCapabilities(),
    this.conversationId,
    this.maxInputBytes = 64 * 1024 * 1024,
  }) : _caps = capabilities;

  final AttachmentUploader uploader;
  final AttachmentPicker? picker;
  final ImagePreparer preparer;

  /// The conversation the uploads belong to, when one exists already.
  final String? Function()? conversationId;

  /// Inputs above this are refused before decoding (memory guard).
  final int maxInputBytes;

  AttachmentCapabilities _caps;
  final _items = <StagedAttachment>[];
  final _sources = <String, AttachmentSource>{};
  final _prepared = <String, ({Uint8List bytes, String mime})>{};
  final _cancels = <String, UploadCancel>{};
  var _next = 0;
  var _disposed = false;

  AttachmentCapabilities get capabilities => _caps;
  set capabilities(AttachmentCapabilities c) {
    _caps = c;
    _notify();
  }

  AttachmentLimits get limits => _caps.limits;
  bool get enabled => _caps.attachments;

  List<StagedAttachment> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;
  int get remaining => (limits.maxItems - _items.length).clamp(0, 1 << 20);
  bool get busy => _items.any((i) => i.busy);
  bool get hasFailed => _items.any((i) => i.status == StagedStatus.failed);

  /// Every item uploaded (true when empty): the message may be sent.
  bool get ready => _items.every((i) => i.status == StagedStatus.uploaded);

  List<UploadedAttachment> get uploaded => [
    for (final i in _items) ?i.uploaded,
  ];

  StagedAttachment? byId(String localId) {
    for (final i in _items) {
      if (i.localId == localId) return i;
    }
    return null;
  }

  /// Opens the picker for [origin] and stages what comes back. Returns
  /// notices for the user (empty when all went well or the user cancelled).
  Future<List<String>> pick(AttachmentOrigin origin) async {
    final picker = this.picker;
    if (picker == null || !enabled) return const [];
    if (remaining == 0) return [_limitNotice()];
    final List<AttachmentSource> picked;
    try {
      picked = switch (origin) {
        AttachmentOrigin.camera => await picker.camera(),
        AttachmentOrigin.photos => await picker.photos(max: remaining),
        AttachmentOrigin.files => await picker.files(max: remaining),
      };
    } on PickException catch (e) {
      return [e.message];
    } catch (_) {
      return ["Couldn't open the picker"];
    }
    return add(picked);
  }

  String _limitNotice() =>
      'You can attach up to ${limits.maxItems} items to a message';

  /// Stages [sources] (over the count limit, or of a refused type or size,
  /// they are dropped with a notice) and starts preparing and uploading.
  List<String> add(List<AttachmentSource> sources) {
    if (_disposed) return const [];
    final notices = <String>[];
    var over = 0;
    for (final s in sources) {
      if (remaining == 0) {
        over++;
        continue;
      }
      final problem = _check(s);
      if (problem != null) {
        notices.add(problem);
        continue;
      }
      final id = 'a${_next++}';
      _sources[id] = s;
      _items.add(
        StagedAttachment(
          localId: id,
          name: s.name,
          mime: s.mime,
          size: s.size,
          kind: s.isImage ? AttachmentKind.image : AttachmentKind.file,
        ),
      );
      _run(id);
    }
    if (over > 0) notices.add(_limitNotice());
    _notify();
    return notices;
  }

  String? _check(AttachmentSource s) {
    final l = limits;
    if (!l.allows(s.mime)) {
      final dot = s.name.lastIndexOf('.');
      final ext = dot < 0 ? '' : s.name.substring(dot).toLowerCase();
      return ext.isEmpty
          ? "Hermes can't read ${s.name}"
          : "Hermes can't read $ext files";
    }
    if (s.isImage) {
      if (s.size > maxInputBytes) {
        return '${s.name} is too large (${formatBytes(s.size)})';
      }
    } else if (s.size > l.fileBytes) {
      return '${s.name} is larger than ${formatBytes(l.fileBytes)}';
    }
    return null;
  }

  /// Removes an item, cancelling its upload or dropping it on the server.
  void remove(String localId) {
    final i = _items.indexWhere((e) => e.localId == localId);
    if (i < 0) return;
    final item = _items.removeAt(i);
    _cancels.remove(localId)?.cancel();
    _sources.remove(localId);
    _prepared.remove(localId);
    final up = item.uploaded;
    if (up != null) uploader.delete(up.id).ignore();
    _notify();
  }

  /// Tries a failed item again.
  void retry(String localId) {
    final item = byId(localId);
    if (item == null || item.status != StagedStatus.failed) return;
    _replace(
      item.copyWith(
        status: _prepared.containsKey(localId)
            ? StagedStatus.uploading
            : StagedStatus.preparing,
        progress: 0,
        clearError: true,
      ),
    );
    _run(localId);
  }

  /// Forgets everything after a send (the uploads now belong to the
  /// message, so nothing is deleted on the server).
  void clear() {
    for (final c in _cancels.values) {
      c.cancel();
    }
    _cancels.clear();
    _items.clear();
    _sources.clear();
    _prepared.clear();
    _notify();
  }

  /// Removes and deletes everything (the user discarded the draft).
  void discardAll() {
    for (final i in [..._items]) {
      remove(i.localId);
    }
  }

  Future<void> _run(String id) async {
    final src = _sources[id];
    if (src == null) return;
    var prepared = _prepared[id];
    try {
      if (prepared == null) {
        final raw = await src.read();
        if (!_alive(id)) return;
        if (src.isImage) {
          final p = await preparer.prepare(raw, limits);
          prepared = (bytes: p.bytes, mime: p.mime);
        } else {
          prepared = (bytes: raw, mime: src.mime);
        }
        if (!_alive(id)) return;
        final cap = src.isImage ? limits.imageBytes : limits.fileBytes;
        if (prepared.bytes.length > cap) {
          _fail(
            id,
            'Larger than ${formatBytes(cap)}, even after shrinking',
            retryable: false,
          );
          return;
        }
        _prepared[id] = prepared;
        _replace(
          byId(id)!.copyWith(
            mime: prepared.mime,
            size: prepared.bytes.length,
            preview: src.isImage ? prepared.bytes : null,
            status: StagedStatus.uploading,
            progress: 0,
          ),
        );
      }
    } on ImagePrepException catch (e) {
      _fail(id, e.message, retryable: false);
      return;
    } catch (_) {
      _fail(id, "Couldn't read ${src.name}");
      return;
    }

    final cancel = UploadCancel();
    _cancels[id] = cancel;
    var lastShown = -1.0;
    try {
      final up = await uploader.upload(
        name: _uploadName(src.name, prepared.mime),
        mime: prepared.mime,
        bytes: prepared.bytes,
        conversationId: conversationId?.call(),
        cancel: cancel,
        onProgress: (p) {
          // Repaint at most every 2 %.
          if (!_alive(id) || cancel.cancelled) return;
          if (p < 1 && p - lastShown < 0.02) return;
          lastShown = p;
          _replace(byId(id)!.copyWith(progress: p.clamp(0.0, 1.0)));
        },
      );
      if (!_alive(id) || cancel.cancelled) return;
      _cancels.remove(id);
      _replace(
        byId(id)!
            .copyWith(status: StagedStatus.uploaded, progress: 1, uploaded: up),
      );
    } on UploadException catch (e) {
      if (cancel.cancelled || !_alive(id)) return;
      _cancels.remove(id);
      _fail(id, e.message, retryable: e.retryable);
    } catch (_) {
      if (cancel.cancelled || !_alive(id)) return;
      _cancels.remove(id);
      _fail(id, 'Upload failed');
    }
  }

  /// A re-encoded HEIC keeps its base name with the new extension.
  static String _uploadName(String name, String mime) {
    final ext = switch (mime) {
      'image/jpeg' => 'jpg',
      'image/png' => 'png',
      _ => null,
    };
    if (ext == null) return name;
    final dot = name.lastIndexOf('.');
    final base = dot <= 0 ? name : name.substring(0, dot);
    return '$base.$ext';
  }

  bool _alive(String id) => !_disposed && byId(id) != null;

  void _fail(String id, String message, {bool retryable = true}) {
    final item = byId(id);
    if (item == null) return;
    _replace(
      item.copyWith(
        status: StagedStatus.failed,
        error: message,
        retryable: retryable,
      ),
    );
  }

  void _replace(StagedAttachment next) {
    final i = _items.indexWhere((e) => e.localId == next.localId);
    if (i < 0) return;
    _items[i] = next;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final c in _cancels.values) {
      c.cancel();
    }
    super.dispose();
  }
}
