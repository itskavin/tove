import 'tts_engine.dart';

/// Speaker order of `kokoro-multi-lang-v1_0` (sid = index), read from the
/// model's `speaker_names` metadata with sherpa-onnx 2.0.1 on 2026-11-15.
/// The sherpa-onnx docs list 53; the model has 54 (`em_santa` is last).
const kokoroV1_0Speakers = [
  'af_alloy', 'af_aoede', 'af_bella', 'af_heart', 'af_jessica', 'af_kore',
  'af_nicole', 'af_nova', 'af_river', 'af_sarah', 'af_sky', 'am_adam',
  'am_echo', 'am_eric', 'am_fenrir', 'am_liam', 'am_michael', 'am_onyx',
  'am_puck', 'am_santa', 'bf_alice', 'bf_emma', 'bf_isabella', 'bf_lily',
  'bm_daniel', 'bm_fable', 'bm_george', 'bm_lewis', 'ef_dora', 'em_alex',
  'ff_siwis', 'hf_alpha', 'hf_beta', 'hm_omega', 'hm_psi', 'if_sara',
  'im_nicola', 'jf_alpha', 'jf_gongitsune', 'jf_nezumi', 'jf_tebukuro',
  'jm_kumo', 'pf_dora', 'pm_alex', 'pm_santa', 'zf_xiaobei', 'zf_xiaoni',
  'zf_xiaoxiao', 'zf_xiaoyi', 'zm_yunjian', 'zm_yunxi', 'zm_yunxia',
  'zm_yunyang', 'em_santa',
];

/// Speaker order of `kokoro-multi-lang-v1_1` (Kokoro-82M-v1.1-zh), from the
/// model metadata: 3 English voices, then 55 Mandarin female and 45 male.
const kokoroV1_1Speakers = [
  'af_maple', 'af_sol', 'bf_vale',
  'zf_001', 'zf_002', 'zf_003', 'zf_004', 'zf_005', 'zf_006', 'zf_007',
  'zf_008', 'zf_017', 'zf_018', 'zf_019', 'zf_021', 'zf_022', 'zf_023',
  'zf_024', 'zf_026', 'zf_027', 'zf_028', 'zf_032', 'zf_036', 'zf_038',
  'zf_039', 'zf_040', 'zf_042', 'zf_043', 'zf_044', 'zf_046', 'zf_047',
  'zf_048', 'zf_049', 'zf_051', 'zf_059', 'zf_060', 'zf_067', 'zf_070',
  'zf_071', 'zf_072', 'zf_073', 'zf_074', 'zf_075', 'zf_076', 'zf_077',
  'zf_078', 'zf_079', 'zf_083', 'zf_084', 'zf_085', 'zf_086', 'zf_087',
  'zf_088', 'zf_090', 'zf_092', 'zf_093', 'zf_094', 'zf_099',
  'zm_009', 'zm_010', 'zm_011', 'zm_012', 'zm_013', 'zm_014', 'zm_015',
  'zm_016', 'zm_020', 'zm_025', 'zm_029', 'zm_030', 'zm_031', 'zm_033',
  'zm_034', 'zm_035', 'zm_037', 'zm_041', 'zm_045', 'zm_050', 'zm_052',
  'zm_053', 'zm_054', 'zm_055', 'zm_056', 'zm_057', 'zm_058', 'zm_061',
  'zm_062', 'zm_063', 'zm_064', 'zm_065', 'zm_066', 'zm_068', 'zm_069',
  'zm_080', 'zm_081', 'zm_082', 'zm_089', 'zm_091', 'zm_095', 'zm_096',
  'zm_097', 'zm_098', 'zm_100',
];

/// Voices listed with a "CC BY" source in Kokoro-82M's VOICES.md
/// (huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md). They ship inside
/// v1.0's `voices.bin`, so their credit is shown whether or not they are used.
const kokoroCcByVoices = {
  'ff_siwis':
      'SIWIS French speech synthesis database, CC BY '
      '(https://datashare.ed.ac.uk/handle/10283/2353)',
  'jf_gongitsune':
      'koniwa corpus, "gongitsune", CC BY '
      '(https://github.com/koniwa/koniwa/blob/master/source/tnc/tnc__gongitsune.txt)',
  'jf_nezumi':
      'koniwa corpus, "nezuminoyomeiri", CC BY '
      '(https://github.com/koniwa/koniwa/blob/master/source/tnc/tnc__nezuminoyomeiri.txt)',
  'jf_tebukuro':
      'koniwa corpus, "tebukurowokaini", CC BY '
      '(https://github.com/koniwa/koniwa/blob/master/source/tnc/tnc__tebukurowokaini.txt)',
  'jm_kumo':
      'koniwa corpus, "kumonoito", CC BY '
      '(https://github.com/koniwa/koniwa/blob/master/source/tnc/tnc__kumonoito.txt)',
};

const defaultKokoroVoice = 'af_heart';

List<TtsVoice> kokoroVoices({required bool v1_1}) {
  final names = v1_1 ? kokoroV1_1Speakers : kokoroV1_0Speakers;
  return [
    for (var i = 0; i < names.length; i++) kokoroVoice(names[i], i),
  ];
}

TtsVoice kokoroVoice(String id, int sid) {
  final lang = switch (id[0]) {
    'a' => 'en-US',
    'b' => 'en-GB',
    'e' => 'es',
    'f' => 'fr',
    'h' => 'hi',
    'i' => 'it',
    'j' => 'ja',
    'p' => 'pt-BR',
    'z' => 'zh',
    _ => 'und',
  };
  final gender = id.length > 1
      ? (id[1] == 'f' ? 'female' : id[1] == 'm' ? 'male' : null)
      : null;
  final raw = id.length > 3 ? id.substring(3) : id;
  final name = RegExp(r'^\d+$').hasMatch(raw)
      ? '${gender == 'male' ? 'Male' : 'Female'} $raw'
      : raw[0].toUpperCase() + raw.substring(1);
  return TtsVoice(
    id: id,
    name: name,
    language: lang,
    engine: TtsEngineKind.kokoro,
    gender: gender,
    speakerId: sid,
    attribution: kokoroCcByVoices[id],
  );
}
