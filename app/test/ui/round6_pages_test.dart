import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/attachments/attachment.dart';
import 'package:tove_chat/src/attachments/upload_client.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/settings/profile.dart';
import 'package:tove_chat/src/ui/drawer/chat_drawer.dart';
import 'package:tove_chat/src/ui/settings/profile_page.dart';

import '../chat/fake_http.dart';
import 'settings_harness.dart';
import 'test_harness.dart';

Map<String, dynamic> _conv(String id, String title, {bool pinned = false}) => {
  'id': id,
  'title': title,
  'pinned': pinned,
  'kind': 'text',
  'created': 1794691021626,
  'updated': 1794691024435,
};

class _Uploads implements AttachmentUploader {
  final sent = <Uint8List>[];

  @override
  Future<UploadedAttachment> upload({
    required String name,
    required String mime,
    required Uint8List bytes,
    String? conversationId,
    void Function(double progress)? onProgress,
    UploadCancel? cancel,
  }) async {
    sent.add(bytes);
    return UploadedAttachment.fromJson({
      'id': 'up_profile',
      'name': name,
      'mime': mime,
      'size': bytes.length,
      'kind': 'image',
    });
  }

  @override
  Future<void> delete(String id) async {}
}

Uint8List _photo() {
  final i = img.Image(width: 300, height: 200);
  img.fill(i, color: img.ColorRgb8(40, 120, 200));
  img.fillCircle(
    i,
    x: 150,
    y: 100,
    radius: 60,
    color: img.ColorRgb8(240, 200, 160),
  );
  return img.encodePng(i);
}

void main() {
  setUpAll(loadAppFonts);

  group('chat list', () {
    late ConversationsController convs;

    Future<void> pump(
      WidgetTester tester, {
      Brightness brightness = Brightness.dark,
      Profile profile = Profile.empty,
      String name = 'Alex',
      VoidCallback? onProfile,
    }) async {
      final net = FakeHttp()
        ..on(
          'GET /api/conversations',
          (_) => jsonResponse({
            'conversations': [
              _conv('p1', 'Homelab disk alerts', pinned: true),
              _conv('p2', 'Weekly meal plan ideas', pinned: true),
              _conv('c1', 'Fix the backup schedule tonight'),
              _conv('c2', 'Trip to Ooty'),
              _conv('c3', 'Explain Kubernetes ingress simply please'),
            ],
            'next_cursor': null,
          }),
        );
      convs = ConversationsController(
        api: ChatApi(
          baseUrl: chatTestBase,
          accessKey: chatTestKey,
          client: net,
        ),
      );
      addTearDown(convs.dispose);
      await convs.refresh();
      convs.currentId = 'c1';
      phoneSize(tester, size: const Size(340, 760));
      await tester.pumpWidget(
        themed(
          brightness: brightness,
          Scaffold(
            body: ChatDrawer(
              conversations: convs,
              historyAvailable: true,
              serverHost: 'core.example.test',
              onSelect: (_) {},
              onNewChat: () {},
              onSettings: () {},
              onDelete: (_) {},
              profile: profile,
              displayName: name,
              onProfile: onProfile,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('one list: Pinned with bubbles, then Chats, no dates', (
      tester,
    ) async {
      var profileOpened = 0;
      await pump(tester, onProfile: () => profileOpened++);
      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('Chats'), findsOneWidget);
      for (final d in ['Today', 'Yesterday', 'Previous 7 days']) {
        expect(find.text(d), findsNothing, reason: d);
      }
      expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsNWidgets(2));
      expect(find.byKey(const ValueKey('drawer-title')), findsOneWidget);
      // The primary action reads "Chat" and still announces "New chat".
      expect(find.text('Chat'), findsOneWidget);
      expect(find.bySemanticsLabel('New chat'), findsOneWidget);
      // Rows are large; the open chat gets a full-width highlight.
      final row = tester.getRect(find.byKey(const ValueKey('chat-row-c1')));
      expect(row.height, greaterThanOrEqualTo(56));
      expect(row.width, 340);
      // The avatar shows the user's initials and opens Profile.
      expect(find.text('A'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('drawer-avatar')));
      expect(profileOpened, 1);
    });

    for (final b in Brightness.values) {
      testWidgets('golden ${b.name}', (tester) async {
        await pump(tester, brightness: b);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/chat_list_${b.name}.png'),
        );
      });
    }
  });

  group('profile', () {
    late SettingsHarness h;

    Future<void> pump(
      WidgetTester tester, {
      Brightness brightness = Brightness.dark,
      AttachmentUploader? uploader,
      PhotoSource? pick,
    }) async {
      h = SettingsHarness();
      await h.setUp();
      addTearDown(h.dispose);
      phoneSize(tester);
      await tester.pumpWidget(
        themed(
          brightness: brightness,
          ProfilePage(
            settings: h.settings,
            uploader: uploader,
            pickPhoto: pick ?? () async => null,
            onSettings: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('name syncs under app.profile and shows on the avatar', (
      tester,
    ) async {
      await pump(tester);
      await tester.enterText(
        find.byKey(const ValueKey('profile-name')),
        'Alex',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(h.settings.profile.name, 'Alex');
      expect(h.settings.displayName, 'Alex');
      expect(h.settings.sync.view[Profile.syncKey], {'name': 'Alex'});
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('a photo is cropped, uploaded and synced as a thumbnail', (
      tester,
    ) async {
      final uploads = _Uploads();
      final photo = _photo();
      await pump(tester, uploader: uploads, pick: () async => photo);
      await tester.tap(find.byKey(const ValueKey('profile-photo')));
      await tester.pumpAndSettle();
      expect(find.text('Move and scale'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('crop-use')));
      await tester.pumpAndSettle();
      expect(uploads.sent, hasLength(1));
      final p = h.settings.profile;
      expect(p.photoId, 'up_profile');
      final thumb = img.decodeJpg(base64Decode(p.thumb!))!;
      expect(thumb.width, 96);
      expect(thumb.height, 96);
      expect(
        find.byKey(const ValueKey('profile-remove-photo')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('profile-remove-photo')));
      await tester.pumpAndSettle();
      expect(h.settings.profile.hasPhoto, isFalse);
    });

    test('the crop maps the circle back to image pixels', () {
      // A 300 × 200 image in a 100 dp square: cover scale 0.5, centred.
      final r = visibleImageRect(const Size(300, 200), 100, Matrix4.identity());
      expect(r, const Rect.fromLTWH(50, 0, 200, 200));
      // Zoomed 2× at the origin: the top-left quarter of that square.
      final z = visibleImageRect(
        const Size(300, 200),
        100,
        Matrix4.diagonal3Values(2, 2, 1),
      );
      expect(z, const Rect.fromLTWH(50, 0, 100, 100));
    });

    for (final b in Brightness.values) {
      testWidgets('golden ${b.name}', (tester) async {
        await pump(tester, brightness: b);
        await h.settings.setProfile(const Profile(name: 'Alex'));
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/profile_${b.name}.png'),
        );
      });
    }
  });

  group('about', () {
    Future<void> open(WidgetTester tester, Brightness b) async {
      final h = SettingsHarness();
      await h.setUp();
      addTearDown(h.dispose);
      await h.open(tester, brightness: b, size: const Size(412, 1300));
      await openSection(tester, 'About');
    }

    testWidgets('icon, version and build, mission, maker and links', (
      tester,
    ) async {
      await open(tester, Brightness.dark);
      expect(find.byKey(const ValueKey('about-version')), findsOneWidget);
      expect(find.textContaining('Build'), findsOneWidget);
      expect(find.byKey(const ValueKey('about-mission')), findsOneWidget);
      expect(find.text('Made by'), findsOneWidget);
      expect(find.textContaining('self-hosted Hermes Agent'), findsOneWidget);
      expect(find.text('Licences'), findsOneWidget);
      expect(find.text('Privacy policy'), findsOneWidget);
      expect(find.text('Private for now'), findsNothing);
      expect(find.textContaining('no analytics'), findsOneWidget);
    });

    for (final b in Brightness.values) {
      testWidgets('golden ${b.name}', (tester) async {
        await open(tester, b);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/about_${b.name}.png'),
        );
      });
    }
  });
}
