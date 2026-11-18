import 'dart:async';
import 'dart:typed_data';

import 'package:tove_chat/src/attachments/attachments.dart';

/// An uploader whose calls the test finishes by hand.
class FakeUploader implements AttachmentUploader {
  final calls = <FakeUpload>[];
  final deleted = <String>[];

  /// When set, uploads finish at once with this result.
  bool autoComplete = false;
  var _n = 0;

  @override
  Future<UploadedAttachment> upload({
    required String name,
    required String mime,
    required Uint8List bytes,
    String? conversationId,
    void Function(double progress)? onProgress,
    UploadCancel? cancel,
  }) {
    final u = FakeUpload(
      name: name,
      mime: mime,
      bytes: bytes,
      conversationId: conversationId,
      onProgress: onProgress,
      cancel: cancel,
      id: 'up_${_n++}',
    );
    calls.add(u);
    if (autoComplete) u.succeed();
    return u.done.future;
  }

  @override
  Future<void> delete(String id) async => deleted.add(id);
}

class FakeUpload {
  FakeUpload({
    required this.name,
    required this.mime,
    required this.bytes,
    required this.conversationId,
    required this.onProgress,
    required this.cancel,
    required this.id,
  });

  final String name;
  final String mime;
  final Uint8List bytes;
  final String? conversationId;
  final void Function(double)? onProgress;
  final UploadCancel? cancel;
  final String id;
  final done = Completer<UploadedAttachment>();

  void progress(double p) => onProgress?.call(p);

  void succeed() {
    if (done.isCompleted) return;
    done.complete(
      UploadedAttachment(
        id: id,
        name: name,
        mime: mime,
        size: bytes.length,
        kind: mime.startsWith('image/')
            ? AttachmentKind.image
            : AttachmentKind.file,
      ),
    );
  }

  void fail([UploadErrorKind kind = UploadErrorKind.network]) {
    if (done.isCompleted) return;
    done.completeError(UploadException(kind, 'Upload failed (test)'));
  }
}

/// Returns the input unchanged, tagged as a JPEG.
class FakePreparer implements ImagePreparer {
  final seen = <int>[];
  ImagePrepException? error;

  @override
  Future<PreparedImage> prepare(Uint8List bytes, AttachmentLimits l) async {
    seen.add(bytes.length);
    if (error != null) throw error!;
    return PreparedImage(bytes: bytes, mime: 'image/jpeg', width: 1, height: 1);
  }
}

class FakePicker implements AttachmentPicker {
  List<AttachmentSource> next = [];
  PickException? error;
  final asked = <String>[];

  @override
  Future<List<AttachmentSource>> camera() async {
    asked.add('camera');
    if (error != null) throw error!;
    return next.take(1).toList();
  }

  @override
  Future<List<AttachmentSource>> photos({required int max}) async {
    asked.add('photos:$max');
    if (error != null) throw error!;
    return next.take(max).toList();
  }

  @override
  Future<List<AttachmentSource>> files({required int max}) async {
    asked.add('files:$max');
    if (error != null) throw error!;
    return next.take(max).toList();
  }
}

AttachmentSource fakeImage(String name, [int size = 1000]) =>
    AttachmentSource.bytes(
      name,
      Uint8List(size),
      origin: AttachmentOrigin.photos,
    );

AttachmentSource fakeFile(String name, [int size = 2000]) =>
    AttachmentSource.bytes(name, Uint8List(size));

/// Lets queued microtasks and futures run.
Future<void> flush() => Future<void>.delayed(Duration.zero);
