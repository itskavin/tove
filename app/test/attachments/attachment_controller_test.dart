import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/attachments/attachments.dart';

import 'fakes.dart';

void main() {
  late FakeUploader up;
  late FakePreparer prep;
  late FakePicker picker;
  late AttachmentController c;

  AttachmentController make({
    AttachmentLimits limits = const AttachmentLimits(),
  }) => AttachmentController(
    uploader: up,
    picker: picker,
    preparer: prep,
    capabilities: AttachmentCapabilities(attachments: true, limits: limits),
    conversationId: () => 'c1',
  );

  setUp(() {
    up = FakeUploader();
    prep = FakePreparer();
    picker = FakePicker();
    c = make();
  });
  tearDown(() => c.dispose());

  test(
    'an added item prepares, uploads with progress, then is ready',
    () async {
      expect(c.ready, isTrue, reason: 'empty is ready');
      final notices = c.add([fakeImage('a.jpg')]);
      expect(notices, isEmpty);
      expect(c.items.single.status, StagedStatus.preparing);
      expect(c.ready, isFalse);
      await flush();
      await flush();
      expect(prep.seen, [1000], reason: 'images go through the preparer');
      expect(c.items.single.status, StagedStatus.uploading);
      expect(c.items.single.preview, isNotNull);
      expect(up.calls.single.conversationId, 'c1');
      expect(up.calls.single.name, 'a.jpg');

      up.calls.single.progress(0.5);
      expect(c.items.single.progress, 0.5);
      expect(c.busy, isTrue);
      up.calls.single.succeed();
      await flush();
      expect(c.items.single.status, StagedStatus.uploaded);
      expect(c.ready, isTrue);
      expect(c.uploaded.single.id, 'up_0');
    },
  );

  test('documents skip the image preparer', () async {
    c.add([fakeFile('notes.pdf')]);
    await flush();
    await flush();
    expect(prep.seen, isEmpty);
    expect(up.calls.single.mime, 'application/pdf');
    expect(c.items.single.kind, AttachmentKind.file);
  });

  test('count limit: extra items are dropped with one notice', () async {
    c.add([fakeImage('1.jpg'), fakeImage('2.jpg'), fakeImage('3.jpg')]);
    final notices = c.add([fakeFile('4.pdf'), fakeFile('5.pdf')]);
    expect(c.items, hasLength(4));
    expect(c.remaining, 0);
    expect(notices, ['You can attach up to 4 items to a message']);
    expect(await c.pick(AttachmentOrigin.files), [
      'You can attach up to 4 items to a message',
    ]);
    expect(picker.asked, isEmpty, reason: 'the picker is not opened when full');
  });

  test('size and type limits come from the capabilities', () async {
    c.dispose();
    c = make(
      limits: AttachmentLimits.fromJson({
        'max_items': 2,
        'file_mb': 1,
        'mimes': ['application/pdf', 'image/*'],
      }),
    );
    expect(c.limits.maxItems, 2);
    final n1 = c.add([fakeFile('big.pdf', 2 * 1024 * 1024)]);
    expect(n1.single, 'big.pdf is larger than 1.0 MB');
    final n2 = c.add([fakeFile('archive.zip')]);
    expect(n2.single, "Hermes can't read .zip files");
    expect(c.items, isEmpty);
  });

  test(
    'an image still too large after shrinking fails without retry',
    () async {
      c.dispose();
      c = make(limits: const AttachmentLimits(imageBytes: 500));
      c.add([fakeImage('huge.jpg', 900)]);
      await flush();
      await flush();
      final item = c.items.single;
      expect(item.status, StagedStatus.failed);
      expect(item.retryable, isFalse);
      expect(up.calls, isEmpty);
    },
  );

  test('a failed upload can be retried', () async {
    c.add([fakeFile('a.txt')]);
    await flush();
    await flush();
    up.calls.single.fail();
    await flush();
    expect(c.items.single.status, StagedStatus.failed);
    expect(c.items.single.error, 'Upload failed (test)');
    expect(c.items.single.retryable, isTrue);
    expect(c.hasFailed, isTrue);
    expect(c.ready, isFalse);

    c.retry(c.items.single.localId);
    expect(c.items.single.status, StagedStatus.uploading);
    await flush();
    expect(up.calls, hasLength(2), reason: 'prepared bytes are reused');
    up.calls.last.succeed();
    await flush();
    expect(c.items.single.status, StagedStatus.uploaded);
  });

  test('unsupported type from the server is not retryable', () async {
    c.add([fakeFile('a.txt')]);
    await flush();
    await flush();
    up.calls.single.fail(UploadErrorKind.unsupported);
    await flush();
    expect(c.items.single.retryable, isFalse);
  });

  test('remove cancels a running upload, or deletes a finished one', () async {
    c.add([fakeFile('a.txt'), fakeFile('b.txt')]);
    await flush();
    await flush();
    final first = c.items.first.localId;
    c.remove(first);
    expect(up.calls.first.cancel!.cancelled, isTrue);
    up.calls.last.succeed();
    await flush();
    c.remove(c.items.single.localId);
    expect(up.deleted, ['up_1']);
    expect(c.isEmpty, isTrue);
  });

  test('clear forgets items without deleting them on the server', () async {
    up.autoComplete = true;
    c.add([fakeFile('a.txt')]);
    await flush();
    await flush();
    expect(c.ready, isTrue);
    c.clear();
    expect(c.isEmpty, isTrue);
    expect(up.deleted, isEmpty);
  });

  test('pick passes the remaining count and returns picker errors', () async {
    picker.next = [fakeImage('p.jpg')];
    c.add([fakeFile('a.txt')]);
    await c.pick(AttachmentOrigin.photos);
    expect(picker.asked, ['photos:3']);
    expect(c.items, hasLength(2));
    picker.error = const PickException(
      PickErrorKind.permissionDenied,
      'Camera access is off',
    );
    expect(await c.pick(AttachmentOrigin.camera), ['Camera access is off']);
  });

  test('nothing is picked while the bridge has no uploads', () async {
    c.capabilities = const AttachmentCapabilities();
    picker.next = [fakeImage('p.jpg')];
    expect(await c.pick(AttachmentOrigin.photos), isEmpty);
    expect(picker.asked, isEmpty);
  });

  test('a re-encoded image is uploaded under its new extension', () async {
    c.add([
      AttachmentSource.bytes(
        'IMG_1.HEIC',
        Uint8List(10),
        origin: AttachmentOrigin.photos,
      ),
    ]);
    await flush();
    await flush();
    expect(up.calls.single.name, 'IMG_1.jpg');
    expect(up.calls.single.mime, 'image/jpeg');
  });
}
