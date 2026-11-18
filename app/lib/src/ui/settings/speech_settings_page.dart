import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../speech/speech.dart';
import '../common/glass.dart';
import '../common/group_card.dart';
import '../theme/tokens.dart';

/// Settings › Dictation and read aloud (chat-rendering-v2 §5.3, §5.4): the
/// engines, voice, speed and the on-device model downloads. Settings shows
/// the same groups inside its Voice and Storage sections
/// ([SpeechSettingsGroups]); this page keeps them together.
class SpeechSettingsPage extends StatelessWidget {
  const SpeechSettingsPage({super.key, required this.speech});

  final SpeechServices speech;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dictation and read aloud'),
        leading: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Center(
            child: GlassButton(
              label: 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
              child: Icon(Icons.arrow_back_rounded, size: 20, color: t.text),
            ),
          ),
        ),
        leadingWidth: 64,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.only(
              bottom: 32 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [SpeechSettingsGroups(speech: speech)],
          ),
        ),
      ),
    );
  }
}

/// The speech groups, for a page or a Settings section: [readAloud],
/// [dictation] and [downloads] pick which show. [anchor] wraps each row
/// Settings search can point at (by id); it defaults to the row itself.
class SpeechSettingsGroups extends StatelessWidget {
  const SpeechSettingsGroups({
    super.key,
    required this.speech,
    this.readAloud = true,
    this.dictation = true,
    this.downloads = true,
    this.anchor,
  });

  final SpeechServices speech;
  final bool readAloud, dictation, downloads;
  final Widget Function(String id, Widget child)? anchor;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    const card = EdgeInsets.symmetric(horizontal: 16);
    Widget a(String id, Widget child) => anchor?.call(id, child) ?? child;
    return ListenableBuilder(
      listenable: Listenable.merge([speech.settings, speech.models]),
      builder: (context, _) {
        final s = speech.settings.value;
        void set(SpeechSettings Function(SpeechSettings) f) =>
            unawaited(speech.settings.update(f));
        final kokoro = s.kokoroModel;
        final moonshine = SpeechModels.moonshineTinyEn;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (readAloud) ...[
              const SectionHeader('Read aloud'),
              a(
                'readAloud',
                GroupCard(
                  margin: card,
                  children: [
                    GroupRow(
                      label: 'Natural voice (on this device)',
                      icon: Icons.record_voice_over_outlined,
                      subtitle: 'Kokoro. Private and offline once downloaded.',
                      selected: s.ttsEngine == TtsEngineKind.kokoro,
                      onTap: () => set(
                        (s) => s.copyWith(ttsEngine: TtsEngineKind.kokoro),
                      ),
                    ),
                    GroupRow(
                      label: 'System voice',
                      icon: Icons.settings_voice_outlined,
                      subtitle: 'Android’s text-to-speech. No download.',
                      selected: s.ttsEngine == TtsEngineKind.system,
                      onTap: () => set(
                        (s) => s.copyWith(ttsEngine: TtsEngineKind.system),
                      ),
                    ),
                    GroupRow(
                      label: 'Voice',
                      icon: Icons.graphic_eq_rounded,
                      value: s.ttsEngine == TtsEngineKind.kokoro
                          ? s.kokoroVoice
                          : (s.systemVoice ?? 'Automatic'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => _VoicePage(speech: speech),
                        ),
                      ),
                    ),
                    a(
                      'speed',
                      _SpeedRow(
                        speed: s.speed,
                        onChanged: (v) => set((s) => s.copyWith(speed: v)),
                      ),
                    ),
                    a(
                      'readReplies',
                      SwitchRow(
                        label: 'Read replies aloud',
                        icon: Icons.volume_up_outlined,
                        subtitle: 'Read each new reply when it finishes.',
                        value: s.autoReadReplies,
                        onChanged: (on) =>
                            set((s) => s.copyWith(autoReadReplies: on)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (dictation) ...[
              const SectionHeader('Dictation'),
              a(
                'dictation',
                GroupCard(
                  margin: card,
                  children: [
                    GroupRow(
                      label: 'Tove server (most accurate)',
                      icon: Icons.cloud_outlined,
                      subtitle:
                          'Your server transcribes each phrase with '
                          'gpt-4o-transcribe. Best with accents. Falls back '
                          'to the phone when the server can’t.',
                      selected: s.dictationEngine == DictationEngineKind.server,
                      onTap: () => set(
                        (s) => s.copyWith(
                          dictationEngine: DictationEngineKind.server,
                        ),
                      ),
                    ),
                    GroupRow(
                      label: 'Phone recogniser',
                      icon: Icons.mic_none_rounded,
                      subtitle:
                          'Google’s online recogniser, live word by word; '
                          'on the device with “On this device only”.',
                      selected: s.dictationEngine == DictationEngineKind.system,
                      onTap: () => set(
                        (s) => s.copyWith(
                          dictationEngine: DictationEngineKind.system,
                        ),
                      ),
                    ),
                    GroupRow(
                      label: 'Offline (Moonshine, English)',
                      icon: Icons.offline_bolt_outlined,
                      subtitle: 'Always on this device. Needs a download.',
                      selected:
                          s.dictationEngine == DictationEngineKind.moonshine,
                      onTap: () => set(
                        (s) => s.copyWith(
                          dictationEngine: DictationEngineKind.moonshine,
                        ),
                      ),
                    ),
                    a(
                      'onDevice',
                      SwitchRow(
                        label: 'On this device only',
                        icon: Icons.lock_outline_rounded,
                        subtitle:
                            'Never use a recogniser that may send audio '
                            'off the phone.',
                        value: s.dictationOnDeviceOnly,
                        onChanged: (on) =>
                            set((s) => s.copyWith(dictationOnDeviceOnly: on)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (downloads) ...[
              const SectionHeader('Voice downloads'),
              a(
                'downloads',
                GroupCard(
                  margin: card,
                  children: [
                    _ModelRow(speech: speech, model: kokoro),
                    _ModelRow(speech: speech, model: moonshine),
                    a(
                      'wifiOnly',
                      SwitchRow(
                        label: 'Download on Wi-Fi only',
                        icon: Icons.wifi_rounded,
                        value: s.downloadOnWifiOnly,
                        onChanged: (on) =>
                            set((s) => s.copyWith(downloadOnWifiOnly: on)),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 12, 32, 0),
                child: Text(
                  'Until the natural voice is downloaded, read aloud uses '
                  'the system voice.',
                  style: t.label,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

String _mb(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.speech, required this.model});

  final SpeechServices speech;
  final SpeechModel model;

  /// Deleting frees the space but needs a new download to use it again.
  Future<void> _confirmDelete(BuildContext context, ModelManager models) async {
    final t = HermesTokens.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${model.title}?'),
        content: Text(
          'This frees ${_mb(model.archiveBytes)} or more on this device. You '
          'can download it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: t.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await models.delete(model.id);
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final models = speech.models;
    final st = models.status(model.id);
    final wifiOnly = speech.settings.value.downloadOnWifiOnly;
    final (
      String sub,
      String? action,
      VoidCallback? onTap,
    ) = switch (st.phase) {
      ModelPhase.notInstalled => (
        _mb(model.archiveBytes),
        'Download',
        () => unawaited(models.download(model.id, wifiOnly: wifiOnly)),
      ),
      ModelPhase.waitingForWifi => (
        'Waiting for Wi-Fi · ${_mb(model.archiveBytes)}',
        'Use mobile data',
        () => unawaited(models.download(model.id, wifiOnly: false)),
      ),
      ModelPhase.downloading => (
        'Downloading ${((st.progress ?? 0) * 100).round()} %',
        'Cancel',
        () => unawaited(models.cancel(model.id)),
      ),
      ModelPhase.paused => (
        'Paused',
        'Resume',
        () => unawaited(models.download(model.id, wifiOnly: wifiOnly)),
      ),
      ModelPhase.verifying => ('Checking…', null, null),
      ModelPhase.extracting => ('Unpacking…', null, null),
      ModelPhase.installed => (
        'Installed',
        'Delete',
        () => unawaited(_confirmDelete(context, models)),
      ),
      ModelPhase.failed => (
        st.error ?? 'Download failed',
        'Retry',
        () => unawaited(models.redownload(model.id, wifiOnly: wifiOnly)),
      ),
    };
    return Semantics(
      container: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(model.title, style: t.row),
                  const SizedBox(height: 2),
                  Text(sub, style: t.label),
                  if (st.phase == ModelPhase.downloading) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: st.progress,
                      minHeight: 2,
                      color: t.text,
                      backgroundColor: t.text.withValues(alpha: 0.12),
                    ),
                  ],
                ],
              ),
            ),
            if (action != null)
              TextButton(onPressed: onTap, child: Text(action)),
          ],
        ),
      ),
    );
  }
}

class _SpeedRow extends StatelessWidget {
  const _SpeedRow({required this.speed, required this.onChanged});

  final double speed;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.speed_rounded, size: 22, color: t.text),
              const SizedBox(width: 12),
              Expanded(child: Text('Speed', style: t.row)),
              Text('${speed.toStringAsFixed(2)}×', style: t.label),
            ],
          ),
          Slider(
            value: speed.clamp(
              SpeechSettings.minSpeed,
              SpeechSettings.maxSpeed,
            ),
            min: SpeechSettings.minSpeed,
            max: SpeechSettings.maxSpeed,
            divisions: 14,
            label: '${speed.toStringAsFixed(2)}×',
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _VoicePage extends StatefulWidget {
  const _VoicePage({required this.speech});
  final SpeechServices speech;

  @override
  State<_VoicePage> createState() => _VoicePageState();
}

class _VoicePageState extends State<_VoicePage> {
  late Future<List<TtsVoice>> _voices = widget.speech.voices();

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final speech = widget.speech;
    return Scaffold(
      appBar: AppBar(title: const Text('Read-aloud voice')),
      body: FutureBuilder<List<TtsVoice>>(
        future: _voices,
        builder: (context, snap) {
          final voices = snap.data;
          if (voices == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ValueListenableBuilder<SpeechSettings>(
            valueListenable: speech.settings,
            builder: (context, s, _) {
              final kokoro = s.ttsEngine == TtsEngineKind.kokoro;
              return ListView(
                children: [
                  if (!kokoro)
                    GroupRow(
                      label: 'Automatic',
                      subtitle: 'The most natural voice installed',
                      selected: s.systemVoice == null,
                      onTap: () => unawaited(
                        speech.settings.update(
                          (s) => s.copyWith(clearSystemVoice: true),
                        ),
                      ),
                    ),
                  for (final v in voices)
                    GroupRow(
                      label: v.label,
                      subtitle: v.attribution,
                      selected: kokoro
                          ? s.kokoroVoice == v.id
                          : s.systemVoice == v.id,
                      onTap: () {
                        unawaited(
                          speech.settings.update(
                            (s) => kokoro
                                ? s.copyWith(kokoroVoice: v.id)
                                : s.copyWith(systemVoice: v.id),
                          ),
                        );
                        setState(() => _voices = speech.voices());
                      },
                    ),
                  if (voices.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('No voices found.', style: t.label),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
