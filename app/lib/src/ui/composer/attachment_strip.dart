import 'package:flutter/semantics.dart';
import 'package:material_ui/material_ui.dart';

import '../../attachments/attachment.dart';
import '../../attachments/attachment_controller.dart';
import '../../attachments/attachment_limits.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

/// The staged attachments inside the pill, above the text field
/// (chat-rendering-v2 §5.2): 56 dp image thumbnails and 44 dp file chips in
/// a horizontal strip, each with a remove button, upload progress and, on
/// failure, a retry badge.
class AttachmentStrip extends StatelessWidget {
  const AttachmentStrip({
    super.key,
    required this.items,
    required this.onRemove,
    required this.onRetry,
  });

  final List<StagedAttachment> items;
  final ValueChanged<String> onRemove;
  final ValueChanged<String> onRetry;

  static const thumb = 56.0;
  static const chipH = 44.0;

  /// Room for the × that overhangs the thumbnails' top-right corner.
  static const _overhang = 6.0;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    // File chips grow with large text; thumbnails stay 56.
    final height = _overhang + (chipH * scale > thumb ? chipH * scale : thumb);
    return SizedBox(
      height: height + Sp.xs,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(Sp.s, 0, Sp.s, 0),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: Sp.s),
        itemBuilder: (context, i) {
          final item = items[i];
          return Padding(
            key: ValueKey(item.localId),
            padding: const EdgeInsets.only(top: _overhang, right: _overhang),
            child: Align(
              alignment: Alignment.topLeft,
              widthFactor: 1,
              child: _Appear(
                child: item.isImage
                    ? _ImageThumb(
                        item: item,
                        onRemove: () => onRemove(item.localId),
                        onRetry: () => onRetry(item.localId),
                      )
                    : _FileChip(
                        item: item,
                        onRemove: () => onRemove(item.localId),
                        onRetry: () => onRetry(item.localId),
                      ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Screen-reader text for an item.
String describeAttachment(StagedAttachment a) {
  final what = a.isImage ? 'Photo ${a.name}' : a.name;
  return switch (a.status) {
    StagedStatus.preparing => '$what, preparing',
    StagedStatus.uploading =>
      '$what, uploading ${(a.progress * 100).round()} %',
    StagedStatus.uploaded => '$what, ${formatBytes(a.size)}, ready',
    StagedStatus.failed => '$what, failed: ${a.error ?? 'upload failed'}',
  };
}

class _Appear extends StatelessWidget {
  const _Appear({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final d = Motion.of(context, const Duration(milliseconds: 180));
    if (d == Duration.zero) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: d,
      curve: Motion.emphasizedDecel,
      builder: (context, v, child) => Opacity(
        opacity: v,
        // Announced at once, not after the fade.
        alwaysIncludeSemantics: true,
        child: Transform.scale(scale: 0.85 + 0.15 * v, child: child),
      ),
      child: child,
    );
  }
}

class _ItemSemantics extends StatelessWidget {
  const _ItemSemantics({
    required this.item,
    required this.onRemove,
    required this.onRetry,
    required this.child,
  });

  final StagedAttachment item;
  final VoidCallback onRemove;
  final VoidCallback onRetry;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final failed = item.status == StagedStatus.failed;
    return Semantics(
      container: true,
      label: describeAttachment(item),
      customSemanticsActions: {
        CustomSemanticsAction(label: 'Remove ${item.name}'): onRemove,
        if (failed && item.retryable)
          CustomSemanticsAction(label: 'Retry ${item.name}'): onRetry,
      },
      child: child,
    );
  }
}

class _ImageThumb extends StatelessWidget {
  const _ImageThumb({
    required this.item,
    required this.onRemove,
    required this.onRetry,
  });

  final StagedAttachment item;
  final VoidCallback onRemove;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final failed = item.status == StagedStatus.failed;
    final preview = item.preview;
    const s = AttachmentStrip.thumb;
    return _ItemSemantics(
      item: item,
      onRemove: onRemove,
      onRetry: onRetry,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox.square(
              dimension: s,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: t.surfaceHigh),
                  if (preview != null)
                    ExcludeSemantics(
                      child: Image.memory(
                        preview,
                        fit: BoxFit.cover,
                        cacheWidth: (s * dpr).round(),
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => Icon(
                          Icons.broken_image_outlined,
                          color: t.textFaint,
                        ),
                      ),
                    )
                  else
                    Icon(Icons.image_outlined, color: t.textFaint),
                  if (item.busy || failed)
                    ColoredBox(color: t.bg.withValues(alpha: 0.45)),
                  if (item.busy)
                    Center(
                      child: SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(
                          value: item.status == StagedStatus.uploading
                              ? item.progress.clamp(0.02, 1.0)
                              : null,
                          strokeWidth: 2,
                          color: t.text,
                          backgroundColor: t.text.withValues(alpha: 0.2),
                        ),
                      ),
                    ),
                  if (failed)
                    Center(
                      child: _RetryBadge(item: item, onRetry: onRetry),
                    ),
                ],
              ),
            ),
          ),
          // A 28 dp target that overhangs the corner by 6 dp.
          Positioned(
            top: -6,
            right: -6,
            child: _RemoveButton(name: item.name, onTap: onRemove),
          ),
        ],
      ),
    );
  }
}

class _FileChip extends StatelessWidget {
  const _FileChip({
    required this.item,
    required this.onRemove,
    required this.onRetry,
  });

  final StagedAttachment item;
  final VoidCallback onRemove;
  final VoidCallback onRetry;

  static IconData glyphFor(String mime) {
    if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
    if (mime.contains('spreadsheet') ||
        mime.contains('excel') ||
        mime == 'text/csv') {
      return Icons.table_chart_outlined;
    }
    if (mime.contains('presentation') || mime.contains('powerpoint')) {
      return Icons.slideshow_outlined;
    }
    if (mime.startsWith('text/') ||
        mime.contains('word') ||
        mime.contains('opendocument.text') ||
        mime == 'application/json') {
      return Icons.description_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final failed = item.status == StagedStatus.failed;
    final caption = t.label.copyWith(fontWeight: FontWeight.w400);
    final sub = switch (item.status) {
      StagedStatus.failed => Text(
        item.error ?? 'Upload failed',
        style: caption.copyWith(color: t.danger),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      _ => Text(formatBytes(item.size), style: caption, maxLines: 1),
    };
    return _ItemSemantics(
      item: item,
      onRemove: onRemove,
      onRetry: onRetry,
      child: Container(
        constraints: const BoxConstraints(
          minHeight: AttachmentStrip.chipH,
          maxWidth: 240,
        ),
        decoration: BoxDecoration(
          color: t.surfaceHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (failed)
                    _RetryBadge(item: item, onRetry: onRetry)
                  else
                    Icon(glyphFor(item.mime), size: 22, color: t.textMuted),
                  const SizedBox(width: Sp.s),
                  Flexible(
                    child: ExcludeSemantics(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            middleEllipsis(item.name),
                            style: t.label.copyWith(color: t.text),
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            softWrap: false,
                          ),
                          sub,
                        ],
                      ),
                    ),
                  ),
                  _RemoveButton(name: item.name, onTap: onRemove, inline: true),
                ],
              ),
            ),
            if (item.busy)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  minHeight: 2,
                  value: item.status == StagedStatus.uploading
                      ? item.progress
                      : null,
                  color: t.text,
                  backgroundColor: t.text.withValues(alpha: 0.12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The `danger` ⟳ badge on a failed item; inert when retrying cannot help.
class _RetryBadge extends StatelessWidget {
  const _RetryBadge({required this.item, required this.onRetry});
  final StagedAttachment item;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final badge = Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(color: t.danger, shape: BoxShape.circle),
      child: Icon(
        item.retryable ? Icons.refresh_rounded : Icons.priority_high_rounded,
        size: 18,
        color: Colors.white,
      ),
    );
    if (!item.retryable) {
      return Tooltip(message: item.error ?? 'Failed', child: badge);
    }
    return Semantics(
      container: true,
      button: true,
      label: 'Retry ${item.name}',
      excludeSemantics: true,
      onTap: onRetry,
      child: Tooltip(
        message: item.error ?? 'Retry',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onRetry,
          child: Padding(padding: const EdgeInsets.all(4), child: badge),
        ),
      ),
    );
  }
}

/// A 20 dp × with a 32 dp touch target.
class _RemoveButton extends StatelessWidget {
  const _RemoveButton({
    required this.name,
    required this.onTap,
    this.inline = false,
  });
  final String name;
  final VoidCallback onTap;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Semantics(
      container: true,
      button: true,
      label: 'Remove $name',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: inline
              ? const EdgeInsets.all(8)
              : const EdgeInsets.only(left: 8, bottom: 8),
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: inline ? t.surface : t.closeFill,
              shape: BoxShape.circle,
              border: inline ? null : Border.all(color: t.surface, width: 1.5),
            ),
            child: Icon(
              Icons.close_rounded,
              size: 14,
              color: inline ? t.textMuted : t.onClose,
            ),
          ),
        ),
      ),
    );
  }
}
