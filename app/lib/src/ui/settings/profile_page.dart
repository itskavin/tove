import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../attachments/upload_client.dart';
import '../../settings/profile.dart';
import '../../settings/settings.dart';
import '../common/group_card.dart';
import '../common/profile_avatar.dart';
import '../theme/tokens.dart';
import 'settings_widgets.dart';

/// Picks a photo's bytes (the gallery; injectable for tests).
typedef PhotoSource = Future<Uint8List?> Function();

Future<Uint8List?> galleryPhoto() async {
  final x = await ImagePicker().pickImage(source: ImageSource.gallery);
  return x?.readAsBytes();
}

/// The Profile page: the user's name and round photo, synced across devices
/// as `app.profile` (no email: there are no accounts, one user per server).
/// The avatar in the chat list opens it.
class ProfilePage extends StatefulWidget {
  const ProfilePage({
    super.key,
    required this.settings,
    this.uploader,
    this.pickPhoto = galleryPhoto,
    this.onSettings,
  });

  final SettingsController settings;

  /// Uploads the photo through `POST /api/uploads`; null keeps it local
  /// to the synced thumbnail only.
  final AttachmentUploader? uploader;
  final PhotoSource pickPhoto;

  /// Shows a Settings row (the avatar used to open the settings menu).
  final VoidCallback? onSettings;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final _name = TextEditingController(
    text: widget.settings.profile.name.isNotEmpty
        ? widget.settings.profile.name
        : widget.settings.nickname,
  );
  bool _busy = false;
  String? _problem;

  SettingsController get s => widget.settings;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _saveName() =>
      s.setProfile(s.profile.copyWith(name: _name.text.trim()));

  Future<void> _pick() async {
    setState(() => _problem = null);
    final Uint8List? bytes;
    try {
      bytes = await widget.pickPhoto();
    } catch (_) {
      setState(() => _problem = 'Couldn’t open your photos.');
      return;
    }
    if (bytes == null || !mounted) return;
    final cropped = await Navigator.of(context).push<CroppedPhoto>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PhotoCropPage(bytes: bytes!),
      ),
    );
    if (cropped == null || !mounted) return;
    setState(() => _busy = true);
    String? photoId;
    try {
      photoId = (await widget.uploader?.upload(
        name: 'profile.jpg',
        mime: 'image/jpeg',
        bytes: cropped.photo,
      ))?.id;
    } catch (_) {
      // The synced thumbnail is enough to show the avatar everywhere.
      photoId = null;
    }
    await s.setProfile(
      Profile(
        name: _name.text.trim(),
        photoId: photoId,
        thumb: base64Encode(cropped.thumb),
      ),
    );
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _remove() => s.setProfile(s.profile.withoutPhoto());

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => SettingsSubPage(
        title: 'Profile',
        children: [
          const SizedBox(height: 16),
          Center(
            child: Semantics(
              button: true,
              label: s.profile.hasPhoto ? 'Change photo' : 'Add photo',
              onTap: _busy ? null : _pick,
              child: GestureDetector(
                key: const ValueKey('profile-photo'),
                onTap: _busy ? null : _pick,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    ProfileAvatar(
                      profile: s.profile,
                      name: s.displayName,
                      size: 112,
                    ),
                    if (_busy)
                      const SizedBox.square(
                        dimension: 112,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: t.accent,
                          shape: BoxShape.circle,
                          border: Border.all(color: t.bg, width: 3),
                        ),
                        child: Icon(
                          Icons.photo_camera_outlined,
                          size: 18,
                          color: t.onAccent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              s.displayName.isEmpty ? 'Add your name' : s.displayName,
              style: t.headline,
            ),
          ),
          if (_problem != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Text(
                _problem!,
                textAlign: TextAlign.center,
                style: t.label.copyWith(color: t.danger),
              ),
            ),
          const SectionHeader('Name'),
          GroupCard(
            margin: settingsCard,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  key: const ValueKey('profile-name'),
                  controller: _name,
                  maxLength: 60,
                  textCapitalization: TextCapitalization.words,
                  style: t.row.hermesWeight(400),
                  decoration: const InputDecoration(
                    hintText: 'Your name',
                    border: InputBorder.none,
                    counterText: '',
                  ),
                  onSubmitted: (_) => unawaited(_saveName()),
                  onTapOutside: (_) {
                    FocusScope.of(context).unfocus();
                    unawaited(_saveName());
                  },
                ),
              ),
            ],
          ),
          const SettingsNote(
            'Shown on your avatar. Your name and photo appear on every '
            'device connected to this server.',
          ),
          const SizedBox(height: 16),
          GroupCard(
            margin: settingsCard,
            children: [
              GroupRow(
                label: s.profile.hasPhoto ? 'Change photo' : 'Add photo',
                icon: Icons.photo_library_outlined,
                onTap: _busy ? null : _pick,
              ),
              if (s.profile.hasPhoto)
                GroupRow(
                  key: const ValueKey('profile-remove-photo'),
                  label: 'Remove photo',
                  icon: Icons.delete_outline_rounded,
                  danger: true,
                  onTap: _busy ? null : _remove,
                ),
            ],
          ),
          if (widget.onSettings != null) ...[
            const SizedBox(height: 16),
            GroupCard(
              margin: settingsCard,
              children: [
                GroupRow(
                  key: const ValueKey('profile-settings'),
                  label: 'Settings',
                  icon: Icons.settings_outlined,
                  onTap: widget.onSettings,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A cropped photo: [photo] (512 px JPEG, for the upload) and [thumb]
/// (96 px JPEG, synced in the settings).
class CroppedPhoto {
  const CroppedPhoto(this.photo, this.thumb);
  final Uint8List photo;
  final Uint8List thumb;
}

/// The part of an image (in pixels) a square [viewport] shows: the image is
/// laid out with [BoxFit.cover] and then moved by [m] (an
/// [InteractiveViewer] transform: scale and translation only).
Rect visibleImageRect(Size image, double viewport, Matrix4 m) {
  final cover = viewport / math.min(image.width, image.height);
  final dx = (viewport - image.width * cover) / 2;
  final dy = (viewport - image.height * cover) / 2;
  final k = m.getMaxScaleOnAxis();
  final tx = m.storage[12], ty = m.storage[13];
  Offset toImage(Offset p) => Offset(
    ((p.dx - tx) / k - dx) / cover,
    ((p.dy - ty) / k - dy) / cover,
  );
  final r = Rect.fromPoints(
    toImage(Offset.zero),
    toImage(Offset(viewport, viewport)),
  );
  return r.intersect(Offset.zero & image);
}

/// Crops [src] to [r] and makes the upload and thumbnail JPEGs.
CroppedPhoto cropPhoto(img.Image src, Rect r) {
  final side = math.max(1, math.min(r.width, r.height).round());
  final square = img.copyCrop(
    src,
    x: r.left.round(),
    y: r.top.round(),
    width: side,
    height: side,
  );
  Uint8List jpg(int edge, int quality) => img.encodeJpg(
    img.copyResize(
      square,
      width: math.min(edge, side),
      height: math.min(edge, side),
      interpolation: img.Interpolation.average,
    ),
    quality: quality,
  );
  return CroppedPhoto(jpg(512, 88), jpg(96, 78));
}

/// Move and zoom the photo inside a circle, then Use.
class PhotoCropPage extends StatefulWidget {
  const PhotoCropPage({super.key, required this.bytes});
  final Uint8List bytes;

  @override
  State<PhotoCropPage> createState() => _PhotoCropPageState();
}

class _PhotoCropPageState extends State<PhotoCropPage> {
  final _transform = TransformationController();
  img.Image? _image;
  bool _failed = false;
  double _viewport = 300;

  @override
  void initState() {
    super.initState();
    try {
      final d = img.decodeImage(widget.bytes);
      _image = d == null ? null : img.bakeOrientation(d);
    } catch (_) {
      _image = null;
    }
    _failed = _image == null;
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _use() {
    final i = _image;
    if (i == null) return;
    final r = visibleImageRect(
      Size(i.width.toDouble(), i.height.toDouble()),
      _viewport,
      _transform.value,
    );
    Navigator.of(context).pop(cropPhoto(i, r));
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Move and scale'),
        actions: [
          TextButton(
            key: const ValueKey('crop-use'),
            onPressed: _failed ? null : _use,
            child: Text('Use', style: t.row.copyWith(color: Colors.white)),
          ),
        ],
      ),
      body: _failed
          ? Center(
              child: Text(
                'This photo can’t be opened.',
                style: t.row.copyWith(color: Colors.white),
              ),
            )
          : LayoutBuilder(
              builder: (context, box) {
                _viewport = math.min(box.maxWidth, box.maxHeight) - 32;
                return Center(
                  child: SizedBox.square(
                    dimension: _viewport,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        InteractiveViewer(
                          transformationController: _transform,
                          minScale: 1,
                          maxScale: 5,
                          clipBehavior: Clip.none,
                          child: Image.memory(widget.bytes, fit: BoxFit.cover),
                        ),
                        IgnorePointer(
                          child: CustomPaint(painter: _CircleMask()),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _CircleMask extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    final path = Path.combine(
      PathOperation.difference,
      Path()..addRect(r.inflate(2000)),
      Path()..addOval(r),
    );
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.6));
    canvas.drawCircle(
      r.center,
      size.width / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white70,
    );
  }

  @override
  bool shouldRepaint(_CircleMask oldDelegate) => false;
}
