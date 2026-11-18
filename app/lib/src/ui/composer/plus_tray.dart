import 'package:material_ui/material_ui.dart';

import '../../attachments/attachment.dart';
import '../common/glass.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

/// Shown on attachment tiles when the bridge cannot take uploads.
const kNeedsNewerServer = 'Needs a newer server';

/// The "+" tray (chat-rendering-v2 §5.1): a panel that grows upward out of
/// the composer, with three tiles (Camera, Photos, Files), then Think longer
/// and Read replies aloud, then a hairline and the voice settings row.
/// There is no web search switch (round 6 B4): the model decides, and a
/// reply's More menu has Search with web. Our own layout, deliberately unlike the reference app's popover
/// menu (§7 item 5).
///
/// It is laid out by the composer (in an overlay, so the composer's size
/// does not change) and driven by [animation]: 0 closed, 1 open.
class PlusTray extends StatelessWidget {
  const PlusTray({
    super.key,
    required this.animation,
    required this.attachmentsSupported,
    required this.onPick,
    this.attachmentsRemaining,
    this.deepThink,
    this.onDeepThink,
    this.readAloud,
    this.onReadAloud,
    this.settingsLabel = 'Voice and speech settings',
    this.onSettings,
    this.joined = true,
    this.maxHeight = double.infinity,
  });

  final Animation<double> animation;

  /// The bridge takes uploads. Otherwise the tiles are disabled with
  /// [kNeedsNewerServer].
  final bool attachmentsSupported;

  /// How many more items fit; 0 disables the tiles ("Limit reached").
  final int? attachmentsRemaining;
  final ValueChanged<AttachmentOrigin> onPick;

  /// Each switch row is shown only when its callback is set. [deepThink] is
  /// "Think longer": effort High, which reaches the model as
  /// `reasoning_effort: high` (API.md "Effort mapping").
  final bool? deepThink;
  final ValueChanged<bool>? onDeepThink;
  final bool? readAloud;
  final ValueChanged<bool>? onReadAloud;

  final String settingsLabel;
  final VoidCallback? onSettings;

  /// Square bottom corners, sitting flush on the pill (text mode). In live
  /// mode the tray floats 8 dp above the glass pill with all corners round.
  final bool joined;
  final double maxHeight;

  static const radius = 24.0;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final reduced = Motion.reduced(context);
    final shape = RoundedRectangleBorder(
      borderRadius: joined
          ? const BorderRadius.vertical(top: Radius.circular(radius))
          : BorderRadius.circular(radius),
      side: BorderSide(color: t.hairline),
    );
    final rows = <Widget>[
      if (onDeepThink != null)
        _SwitchRow(
          icon: Icons.psychology_alt_outlined,
          label: 'Think longer',
          subtitle: 'More reasoning first; slower replies',
          value: deepThink ?? false,
          onChanged: onDeepThink!,
        ),
      if (onReadAloud != null)
        _SwitchRow(
          icon: Icons.volume_up_outlined,
          label: 'Read replies aloud',
          value: readAloud ?? false,
          onChanged: onReadAloud!,
        ),
      if (onSettings != null) ...[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: 4),
          child: Divider(height: 1, thickness: 1, color: t.hairline),
        ),
        _ChevronRow(
          icon: Icons.tune_rounded,
          label: settingsLabel,
          onTap: onSettings!,
        ),
      ],
    ];
    final full = (attachmentsRemaining ?? 1) <= 0;
    final tileNote = !attachmentsSupported
        ? kNeedsNewerServer
        : full
        ? 'Limit reached'
        : null;
    final tilesEnabled = attachmentsSupported && !full;
    Widget tile(int i, AttachmentOrigin o, String label, IconData icon) =>
        Expanded(
          child: _Stagger(
            animation: animation,
            index: i,
            reduced: reduced,
            child: _Tile(
              label: label,
              icon: icon,
              note: tileNote,
              onTap: tilesEnabled ? () => onPick(o) : null,
            ),
          ),
        );

    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                tile(
                  0,
                  AttachmentOrigin.camera,
                  'Camera',
                  Icons.photo_camera_outlined,
                ),
                const SizedBox(width: Sp.s),
                tile(
                  1,
                  AttachmentOrigin.photos,
                  'Photos',
                  Icons.image_outlined,
                ),
                const SizedBox(width: Sp.s),
                tile(
                  2,
                  AttachmentOrigin.files,
                  'Files',
                  Icons.insert_drive_file_outlined,
                ),
              ],
            ),
          ),
        ),
        for (var i = 0; i < rows.length; i++)
          _Stagger(
            animation: animation,
            index: 3 + i,
            reduced: reduced,
            child: rows[i],
          ),
        SizedBox(height: joined ? Sp.xs : Sp.s),
      ],
    );

    // A joined tray hides its bottom stroke under the pill.
    Widget panel = DecoratedBox(
      decoration: ShapeDecoration(color: t.surface, shape: shape),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(child: body),
      ),
    );
    if (joined) {
      panel = ClipRect(
        child: Transform.translate(offset: const Offset(0, 1), child: panel),
      );
    }

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Add to message',
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final v = animation.value.clamp(0.0, 1.0);
          if (reduced) return Opacity(opacity: v, child: child);
          // Clips in from the composer's top edge (§5.1).
          return ClipRect(
            child: Align(
              alignment: Alignment.bottomCenter,
              heightFactor: animation.value.clamp(0.0, 1.02),
              child: Opacity(
                opacity: Curves.easeOut.transform((v / 0.6).clamp(0.0, 1.0)),
                child: child,
              ),
            ),
          );
        },
        child: panel,
      ),
    );
  }
}

/// Fades (and lifts 6 dp) each tile and row in, 30 ms apart.
class _Stagger extends StatelessWidget {
  const _Stagger({
    required this.animation,
    required this.index,
    required this.reduced,
    required this.child,
  });

  final Animation<double> animation;
  final int index;
  final bool reduced;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (reduced) return child;
    // The open spring settles in about 240 ms; 30 ms ≈ 0.125 of that.
    final start = (index * 0.125).clamp(0.0, 0.6);
    final interval = Interval(
      start,
      (start + 0.4).clamp(0.0, 1.0),
      curve: Curves.easeOut,
    );
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        // The spring may overshoot 1; closing runs everything together.
        final t = animation.value.clamp(0.0, 1.0);
        final v = animation.status == AnimationStatus.reverse
            ? t
            : interval.transform(t);
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, 6 * (1 - v)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.icon,
    required this.onTap,
    this.note,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final enabled = onTap != null;
    final fg = enabled ? t.text : t.textFaint;
    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(16)),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      hint: note,
      excludeSemantics: true,
      onTap: onTap,
      child: FocusRing(
        shape: shape,
        onActivate: onTap,
        child: Material(
          color: t.surfaceHigh,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 76),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 10,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 24, color: fg),
                    const SizedBox(height: 6),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.label.copyWith(color: fg),
                    ),
                    if (note != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        note!,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: t.label.copyWith(
                          color: t.textFaint,
                          fontSize: 11,
                          height: 14 / 11,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RowShell extends StatelessWidget {
  const _RowShell({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.trailing,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: 6),
          child: Row(
            children: [
              Icon(icon, size: 22, color: t.textMuted),
              const SizedBox(width: Sp.m),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: t.row),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: t.label.copyWith(fontWeight: FontWeight.w400),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: Sp.s),
              trailing,
            ],
          ),
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: _RowShell(
      icon: icon,
      label: label,
      subtitle: subtitle,
      onTap: () => onChanged(!value),
      trailing: Switch(value: value, onChanged: onChanged),
    ),
  );
}

class _ChevronRow extends StatelessWidget {
  const _ChevronRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: _RowShell(
        icon: icon,
        label: label,
        onTap: onTap,
        trailing: Icon(Icons.chevron_right_rounded, color: t.textMuted),
      ),
    );
  }
}
