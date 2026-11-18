import 'package:material_ui/material_ui.dart';

import '../../chat/chat.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'message_actions.dart';

/// Sent attachments above a user bubble's text (chat-rendering-v2 §5.2):
/// images as 120 dp radius-16 thumbnails, files as chips. Tapping an image
/// opens [showImageViewer].
class SentAttachments extends StatelessWidget {
  const SentAttachments({super.key, required this.attachments});

  final List<MessageAttachment> attachments;

  @override
  Widget build(BuildContext context) {
    final images = attachments.where((a) => a.isImage).toList();
    final files = attachments.where((a) => !a.isImage).toList();
    final load = MessageActions.of(context)?.attachmentImage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (images.isNotEmpty)
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in images)
                _Thumb(
                  attachment: a,
                  image: load?.call(a, preview: true),
                  onTap: () => showImageViewer(
                    context,
                    attachment: a,
                    image: load?.call(a, preview: false),
                  ),
                ),
            ],
          ),
        if (images.isNotEmpty && files.isNotEmpty) const SizedBox(height: 8),
        if (files.isNotEmpty)
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [for (final a in files) FileChip(attachment: a)],
          ),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.attachment, required this.image, this.onTap});

  final MessageAttachment attachment;
  final ImageProvider? image;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final img = image;
    return Semantics(
      button: true,
      image: true,
      label: 'Image ${attachment.name}',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: 120,
            height: 120,
            color: t.surfaceHigh,
            child: img == null
                ? Icon(Icons.image_outlined, color: t.textMuted)
                : Hero(
                    tag: 'attachment-${attachment.id}',
                    child: Image(
                      image: img,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          Icon(Icons.broken_image_outlined, color: t.textMuted),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// A sent file: type glyph, name (middle-ellipsised to 22 characters) and
/// size, 44 dp tall.
class FileChip extends StatelessWidget {
  const FileChip({super.key, required this.attachment});

  final MessageAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final a = attachment;
    return Semantics(
      label: 'File ${a.name}, ${fileSize(a.size)}',
      excludeSemantics: true,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              a.mime == 'application/pdf'
                  ? Icons.picture_as_pdf_outlined
                  : Icons.insert_drive_file_outlined,
              size: 20,
              color: t.textMuted,
            ),
            const SizedBox(width: 8),
            Text(
              middleEllipsis(a.name, 22),
              style: t.label.copyWith(color: t.text),
            ),
            const SizedBox(width: 8),
            Text(fileSize(a.size), style: t.caption),
          ],
        ),
      ),
    );
  }
}

String middleEllipsis(String s, int max) {
  if (s.length <= max) return s;
  final end = (max - 1) ~/ 2;
  final start = max - 1 - end;
  return '${s.substring(0, start)}…${s.substring(s.length - end)}';
}

String fileSize(int bytes) {
  if (bytes <= 0) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Full-screen image (§5.2): pinch to zoom; swipe down (or Back) to close
/// with a 200 ms fade.
Future<void> showImageViewer(
  BuildContext context, {
  required MessageAttachment attachment,
  required ImageProvider? image,
}) {
  if (image == null) return Future.value();
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      transitionDuration: Motion.of(context, const Duration(milliseconds: 200)),
      reverseTransitionDuration: Motion.of(
        context,
        const Duration(milliseconds: 200),
      ),
      pageBuilder: (context, a, _) => FadeTransition(
        opacity: a,
        child: _Viewer(attachment: attachment, image: image),
      ),
    ),
  );
}

class _Viewer extends StatefulWidget {
  const _Viewer({required this.attachment, required this.image});
  final MessageAttachment attachment;
  final ImageProvider image;

  @override
  State<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<_Viewer> {
  final _zoom = TransformationController();
  double _dy = 0;

  bool get _zoomed => _zoom.value.getMaxScaleOnAxis() > 1.01;

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = (1 - (_dy.abs() / 300)).clamp(0.3, 1.0);
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: fade),
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onVerticalDragUpdate: _zoomed
                  ? null
                  : (d) => setState(() => _dy += d.delta.dy),
              onVerticalDragEnd: _zoomed
                  ? null
                  : (d) {
                      if (_dy.abs() > 120 ||
                          d.velocity.pixelsPerSecond.dy.abs() > 800) {
                        Navigator.of(context).pop();
                      } else {
                        setState(() => _dy = 0);
                      }
                    },
              child: Transform.translate(
                offset: Offset(0, _dy),
                child: InteractiveViewer(
                  transformationController: _zoom,
                  maxScale: 5,
                  onInteractionEnd: (_) => setState(() {}),
                  child: Center(
                    child: Hero(
                      tag: 'attachment-${widget.attachment.id}',
                      child: Image(
                        image: widget.image,
                        fit: BoxFit.contain,
                        semanticLabel: widget.attachment.name,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.paddingOf(context).top + 8,
            right: 8,
            child: IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
