/// Downloadable speech models, pinned by SHA-256.
///
/// Every hash below was computed from the downloaded release file on
/// 2026-11-15 and matched GitHub's own asset `digest` field
/// (docs/design/voice-models.md). The URLs are the official k2-fsa/sherpa-onnx
/// release assets. If upstream re-uploads an asset, the hash check fails and
/// nothing is installed until the pin here is updated.
library;

enum SpeechModelKind { tts, stt }

class SpeechModel {
  const SpeechModel({
    required this.id,
    required this.kind,
    required this.title,
    required this.description,
    required this.url,
    required this.sha256,
    required this.archiveBytes,
    required this.installedBytes,
    required this.archiveRoot,
    required this.requiredFiles,
    required this.licence,
    this.skipDirs = const [],
  });

  /// Stable id; also the install directory name.
  final String id;
  final SpeechModelKind kind;
  final String title;
  final String description;
  final String url;
  final String sha256;

  /// Size of the `.tar.bz2` download.
  final int archiveBytes;

  /// Size on disk after extraction, without [skipDirs].
  final int installedBytes;

  /// The single top-level directory inside the archive.
  final String archiveRoot;

  /// Files that must exist after extraction (relative to the install dir).
  final List<String> requiredFiles;

  /// Directories deleted after extraction. `espeak-ng-data` is GPL-3.0 data
  /// that sherpa-onnx 2.0 ignores; `dict` is the unused jieba dictionary.
  final List<String> skipDirs;

  final String licence;
}

/// Kokoro TTS model variants.
enum KokoroVariant {
  /// v1.0: 54 voices, 28 of them English. The default.
  v1_0Fp32('kokoro-multi-lang-v1_0', 'model.onnx'),
  v1_0Int8('kokoro-int8-multi-lang-v1_0', 'model.int8.onnx'),

  /// v1.1-zh: 100 Mandarin voices but only 3 English ones.
  v1_1Fp32('kokoro-multi-lang-v1_1', 'model.onnx'),
  v1_1Int8('kokoro-int8-multi-lang-v1_1', 'model.int8.onnx');

  const KokoroVariant(this.modelId, this.modelFile);
  final String modelId;
  final String modelFile;

  SpeechModel get model => SpeechModels.byId(modelId)!;
  bool get isV1_1 => this == v1_1Fp32 || this == v1_1Int8;
}

const _kokoroSkip = ['espeak-ng-data', 'dict'];
const _kokoroFiles = [
  'voices.bin',
  'tokens.txt',
  'lexicon-us-en.txt',
  'lexicon-gb-en.txt',
  'lexicon-zh.txt',
];

abstract final class SpeechModels {
  static const _tts =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models';
  static const _asr =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models';

  static const kokoroV1_0 = SpeechModel(
    id: 'kokoro-multi-lang-v1_0',
    kind: SpeechModelKind.tts,
    title: 'Natural voices (Kokoro v1.0)',
    description: '54 voices, 28 in English. Full quality.',
    url: '$_tts/kokoro-multi-lang-v1_0.tar.bz2',
    sha256: '60703707bc05ccd48d60e1eb723f38b07d6e474795a0b6a588d7220400e0f7a4',
    archiveBytes: 349886476,
    installedBytes: 368675259,
    archiveRoot: 'kokoro-multi-lang-v1_0',
    requiredFiles: ['model.onnx', ..._kokoroFiles],
    skipDirs: _kokoroSkip,
    licence: 'Apache-2.0 (Kokoro-82M weights, hexgrad)',
  );

  static const kokoroV1_0Int8 = SpeechModel(
    id: 'kokoro-int8-multi-lang-v1_0',
    kind: SpeechModelKind.tts,
    title: 'Natural voices, compact (Kokoro v1.0 int8)',
    description:
        'Smaller download. Slower on most CPUs and slightly lower quality.',
    url: '$_tts/kokoro-int8-multi-lang-v1_0.tar.bz2',
    sha256: '72c347230107ef8a31098ec4d468a605244beef5f1ed00db97efa13518800653',
    archiveBytes: 132353410,
    installedBytes: 157317696,
    archiveRoot: 'kokoro-int8-multi-lang-v1_0',
    requiredFiles: ['model.int8.onnx', ..._kokoroFiles],
    skipDirs: _kokoroSkip,
    licence: 'Apache-2.0 (Kokoro-82M weights, hexgrad)',
  );

  static const kokoroV1_1 = SpeechModel(
    id: 'kokoro-multi-lang-v1_1',
    kind: SpeechModelKind.tts,
    title: 'Mandarin voices (Kokoro v1.1-zh)',
    description: '100 Mandarin voices and 3 English ones.',
    url: '$_tts/kokoro-multi-lang-v1_1.tar.bz2',
    sha256: 'b78e1ac42b852e839cceaafbe88f66806bf5860992d1d7b9a3f2ad1198427aed',
    archiveBytes: 364855331,
    // 426,584,734 extracted, minus espeak-ng-data and dict.
    installedBytes: 394020696,
    archiveRoot: 'kokoro-multi-lang-v1_1',
    requiredFiles: ['model.onnx', ..._kokoroFiles],
    skipDirs: _kokoroSkip,
    licence: 'Apache-2.0 (Kokoro-82M-v1.1-zh weights, hexgrad)',
  );

  static const kokoroV1_1Int8 = SpeechModel(
    id: 'kokoro-int8-multi-lang-v1_1',
    kind: SpeechModelKind.tts,
    title: 'Mandarin voices, compact (Kokoro v1.1-zh int8)',
    description: 'Smaller download. Slower on most CPUs.',
    url: '$_tts/kokoro-int8-multi-lang-v1_1.tar.bz2',
    sha256: '259c9c8bc906d6078e4e0570421885dabb68b539c2f970fcbb890a58eeaf3e9c',
    archiveBytes: 147052523,
    // 215,227,172 extracted, minus espeak-ng-data and dict.
    installedBytes: 182663134,
    archiveRoot: 'kokoro-int8-multi-lang-v1_1',
    requiredFiles: ['model.int8.onnx', ..._kokoroFiles],
    skipDirs: _kokoroSkip,
    licence: 'Apache-2.0 (Kokoro-82M-v1.1-zh weights, hexgrad)',
  );

  static const moonshineTinyEn = SpeechModel(
    id: 'sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27',
    kind: SpeechModelKind.stt,
    title: 'Offline dictation (Moonshine tiny, English)',
    description: 'Works without a network. English only.',
    url: '$_asr/sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27.tar.bz2',
    sha256: '9ec31b342d8fa3240c3b81b8f82e1cf7e3ac467c93ca5a999b741d5887164f8d',
    archiveBytes: 29858559,
    // 44,441,158 extracted, minus test_wavs.
    installedBytes: 44256550,
    archiveRoot: 'sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27',
    requiredFiles: ['encoder_model.ort', 'decoder_model_merged.ort', 'tokens.txt'],
    skipDirs: ['test_wavs'],
    licence: 'MIT (Moonshine English models, Useful Sensors / Moonshine AI)',
  );

  static const all = [
    kokoroV1_0,
    kokoroV1_0Int8,
    kokoroV1_1,
    kokoroV1_1Int8,
    moonshineTinyEn,
  ];

  static SpeechModel? byId(String id) {
    for (final m in all) {
      if (m.id == id) return m;
    }
    return null;
  }
}
