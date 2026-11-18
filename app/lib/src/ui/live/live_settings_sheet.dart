import 'package:material_ui/material_ui.dart';

import '../../call/call_controller.dart';
import '../../config.dart';
import '../../settings/settings.dart';
import '../common/floating_sheet.dart';
import '../common/group_card.dart';
import '../common/popover.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

String voiceTitle(String v) =>
    v.isEmpty ? v : '${v[0].toUpperCase()}${v.substring(1)}';

/// The voices to offer: the server's list when it sends one, else
/// [kVoices]. The bridge has no locale metadata, so they are one group
/// (spec §5.11).
List<String> voiceChoices(List<String>? server) =>
    (server != null && server.isNotEmpty) ? server : kVoices;

/// The voice list in the card style, ✓ on the selected voice.
class VoiceList extends StatelessWidget {
  const VoiceList({
    super.key,
    required this.settings,
    required this.voices,
    this.padding = const EdgeInsets.fromLTRB(12, 0, 12, 16),
  });

  final SettingsController settings;
  final List<String> voices;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => ListView(
        padding: padding,
        children: [
          const SectionHeader(
            'Voices',
            padding: EdgeInsets.fromLTRB(8, 4, 8, 8),
          ),
          GroupCard(
            children: [
              for (final v in voices)
                GroupRow(
                  label: voiceTitle(v),
                  selected: settings.voice == v,
                  onTap: () => settings.setVoice(v),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

SheetPage voicePage({
  required SettingsController settings,
  required List<String> voices,
  required bool live,
}) => SheetPage(
  title: 'Choose a voice',
  heightFraction: 0.75,
  subtitle: live ? 'Applies from the next live session' : null,
  builder: (context) => VoiceList(settings: settings, voices: voices),
);

/// The live settings sheet (spec §4.5, shot13): Voice, Language (hidden
/// until the server supports it) and Audio output (when the platform can
/// switch routes).
Future<void> showLiveSettings(
  BuildContext context, {
  required CallController call,
  required SettingsController settings,
  required List<String> voices,
  required bool languageSupported,
}) {
  return showFloatingSheet<void>(
    context,
    live: call.inCall,
    page: SheetPage(
      title: 'Settings',
      builder: (context) => ListenableBuilder(
        listenable: Listenable.merge([call, settings]),
        builder: (context, _) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: GroupCard(
            children: [
              GroupRow(
                label: 'Voice',
                icon: Icons.graphic_eq_rounded,
                value: voiceTitle(settings.voice),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => SheetPager.of(context).push(
                  voicePage(
                    settings: settings,
                    voices: voices,
                    live: call.inCall,
                  ),
                ),
              ),
              if (languageSupported)
                const GroupRow(
                  label: 'Language',
                  icon: Icons.language_rounded,
                  value: 'Auto-detect',
                  trailing: Icon(Icons.keyboard_arrow_down_rounded),
                ),
              if (call.supportsSpeakerRoute) _AudioOutputRow(call: call),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AudioOutputRow extends StatefulWidget {
  const _AudioOutputRow({required this.call});
  final CallController call;

  @override
  State<_AudioOutputRow> createState() => _AudioOutputRowState();
}

class _AudioOutputRowState extends State<_AudioOutputRow> {
  bool _open = false;

  Future<void> _pick(BuildContext rowContext) async {
    final box = rowContext.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    // Anchored to the right half of the card, above the row (shot09).
    final anchor = Rect.fromLTRB(
      rect.center.dx,
      rect.top,
      rect.right,
      rect.bottom,
    );
    setState(() => _open = true);
    final speaker = await showPopover<bool>(
      anchor: rowContext,
      anchorRect: anchor,
      width: anchor.width,
      align: PopoverAlign.end,
      label: 'Audio output',
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopoverItem(
            label: 'Speaker',
            checked: widget.call.speakerOn,
            onTap: () => Navigator.pop(context, true),
          ),
          PopoverItem(
            label: 'Phone',
            checked: !widget.call.speakerOn,
            onTap: () => Navigator.pop(context, false),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _open = false);
    if (speaker != null) await widget.call.setSpeaker(speaker);
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (rowContext) => GroupRow(
        label: 'Audio output',
        icon: Icons.volume_up_outlined,
        value: widget.call.speakerOn ? 'Speaker' : 'Phone',
        onTap: () => _pick(rowContext),
        trailing: AnimatedRotation(
          turns: _open ? 0.5 : 0,
          duration: Motion.of(context, const Duration(milliseconds: 180)),
          child: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
      ),
    );
  }
}

/// The text-mode equivalent for Settings: a full-page voice picker.
class VoicePickerPage extends StatelessWidget {
  const VoicePickerPage({
    super.key,
    required this.settings,
    required this.voices,
    this.live = false,
  });

  final SettingsController settings;
  final List<String> voices;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Choose a voice')),
      body: Column(
        children: [
          if (live)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('Applies from the next live session', style: t.label),
            ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: VoiceList(settings: settings, voices: voices),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
