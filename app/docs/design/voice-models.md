# Voice models: downloads, pins, licences

Status: implemented in `lib/src/speech/` on 2026-11-15. This records the facts the code relies on.

Labels: **MEASURED** (done here, on this host), **STATED** (primary source, linked), **INFERRED**, **NOT VERIFIED**.

## 1. Models and SHA-256 pins

All URLs are official k2-fsa/sherpa-onnx GitHub release assets. Each hash was **MEASURED** with `sha256sum`
on the downloaded file, and each matched the `digest` field GitHub returns for the asset
(`gh api repos/k2-fsa/sherpa-onnx/releases/tags/<tag>`). The pins live in
`lib/src/speech/models/model_catalog.dart`.

Base URL: `https://github.com/k2-fsa/sherpa-onnx/releases/download/`

| Model id | Asset | Archive bytes | Installed bytes¹ | SHA-256 |
| --- | --- | --- | --- | --- |
| `kokoro-multi-lang-v1_0` (**default TTS**) | `tts-models/kokoro-multi-lang-v1_0.tar.bz2` | 349,886,476 | 368,675,259 | `60703707bc05ccd48d60e1eb723f38b07d6e474795a0b6a588d7220400e0f7a4` |
| `kokoro-int8-multi-lang-v1_0` | `tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2` | 132,353,410 | 157,317,696 | `72c347230107ef8a31098ec4d468a605244beef5f1ed00db97efa13518800653` |
| `kokoro-multi-lang-v1_1` | `tts-models/kokoro-multi-lang-v1_1.tar.bz2` | 364,855,331 | 394,020,696 | `b78e1ac42b852e839cceaafbe88f66806bf5860992d1d7b9a3f2ad1198427aed` |
| `kokoro-int8-multi-lang-v1_1` | `tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2` | 147,052,523 | 182,663,134 | `259c9c8bc906d6078e4e0570421885dabb68b539c2f970fcbb890a58eeaf3e9c` |
| `sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27` (offline dictation) | `asr-models/sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27.tar.bz2` | 29,858,559 | 44,256,550 | `9ec31b342d8fa3240c3b81b8f82e1cf7e3ac467c93ca5a999b741d5887164f8d` |

¹ After extraction, minus the deleted folders (§1.2).

The four Kokoro assets were re-uploaded on 2026-10-26 (the sherpa-onnx 2.0 lexicon-only builds); Moonshine dates
from 2026-02-27. If upstream re-uploads again, the pinned hash fails, nothing is installed, and the pin must be
updated here and in the catalog.

### 1.1 Why v1.0 is the default, not v1.1

The research note recommended `kokoro-multi-lang-v1_1`. Its speaker table changes that:

- **MEASURED** (model metadata, read with `debug: true`): v1.1 has 103 speakers. Only 3 are English (`af_maple`,
  `af_sol`, `bf_vale`). Ids 3–57 are Mandarin female and 58–102 Mandarin male.
- **STATED** (huggingface.co/hexgrad/Kokoro-82M-v1.1-zh): v1.1-zh "added 100 Chinese speakers", and the model "is
  not a strict upgrade over its predecessor since it drops many voices". Each English voice has "1 hour" of
  crowdsourced synthetic data.
- **MEASURED**: v1.0 has **54** speakers. The sherpa-onnx docs say 53; `em_santa` is id 53. 28 of them are English
  (`af_*`, `am_*`, `bf_*`, `bm_*`), including `af_heart` (id 3), the default voice.

For an English-first chat app, v1.0 is therefore the default. v1.1 is offered as "Mandarin voices".

### 1.2 Deleted after extraction

- `espeak-ng-data/` (18 MB, GPL-3.0 data). sherpa-onnx 2.0 ignores it and logs "--kokoro-data-dir is deprecated
  and ignored in sherpa-onnx >= v2.0.0".
- `dict/` (15 MB, the jieba dictionary). Its config field is marked "unused".
- `test_wavs/` (Moonshine).

They are part of the official archive, so they are downloaded, but they are never used or kept.

### 1.3 int8 vs fp32: fp32 stays the default

**MEASURED** on this host: Intel i7-5600U (2 cores, 4 threads, 2015), shared with other build jobs. Sentences of
1.1–8.4 s at 24 kHz; RTF = synthesis time ÷ audio time.

| Variant | Threads | Load average | RTF per sentence | Peak RSS |
| --- | --- | --- | --- | --- |
| v1.0 fp32 | 2 | 5 | 1.16 / 1.42 / 1.30 / 2.02 | 787 MB |
| v1.0 fp32 | 4 | 5 | 1.13 / 1.21 / 1.69 / 1.34 | 794 MB |
| v1.0 fp32 | 4 | 3 | 1.46 / 1.48 / 1.29 / 1.46 | 789 MB |
| v1.0 fp32, app phonemizer (`phonemeCodepoints`) | 3 | 3–5 | 1.02 / 1.14 / 1.25 / 1.37 / 1.18 | — |
| v1.0 int8 | 2 | 3–5 | 2.28 / 3.55 / 3.08 / 2.78 | 594 MB |
| v1.0 int8 | 4 | 5 | 4.14 / 5.55 / 4.75 / 6.06 | 602 MB |
| v1.1 fp32 | 2 | 5 | 1.55 / 1.43 / 1.46 / 2.25 | 856 MB |
| v1.1 int8 | 2 | 5 | 5.30 / 3.98 / 4.11 / 4.99 | 632 MB |

Model load took 3.1–6.3 s.

- On this x86 CPU, int8 is **2–4× slower** than fp32 (ONNX Runtime's dynamic-quantised ops). It saves about 190 MB
  of RAM and 220 MB of download.
- **Quality check (MEASURED, proxy only)**: the 20 ms RMS envelope of int8 against fp32, for the same sentence and
  voice, correlates at 0.82–0.95 with lengths within 2%. There were no NaNs and no clipping (peak ≤ 0.47). That
  rules out the "garbage audio" failure on x86, but the outputs differ audibly. Nobody listened to them here.
- **NOT VERIFIED**: ARM phone RTF, and the reported int8 garbage audio on ARM (muxable/rtchat#1500). Benchmark on the
  target phone before changing the default. The app reports `TtsPlaybackState.lastRtf`, `meanRtf` and
  `firstAudioLatency`.
- An RTF above 1 still plays: the controller synthesises up to 2 sentences ahead, so there are gaps between
  sentences. Below about 0.7 playback is gapless. On this laptop, fp32 sits near 1.0–1.5.

**Moonshine tiny (MEASURED)**: load 0.9 s; the bundled 3.85 s test clip decoded in 212 ms (RTF 0.055) to "Ask not
what your country can do for you. Ask what you can do for your country." That is cheap enough to re-decode the
current segment every 0.7 s for partials.

## 2. The espeak-ng question

**Finding (MEASURED): sherpa-onnx 2.0.1's native libraries do not contain espeak-ng.**

Method: I inspected every `.so` from the pub cache, for `sherpa_onnx_android_{arm64,armeabi,x86,x86_64}` 2.0.1 and
`sherpa_onnx_linux` 2.0.1 (`libsherpa-onnx-c-api.so`, `libsherpa-onnx-cxx-api.so`, `libonnxruntime.so`):

- `strings -a | grep espeak` (case-sensitive) gives 5–7 hits per C-API library. All are config or metadata words
  (`has_espeak`, `use_espeak`) or deprecation warnings ("espeak-ng is no longer used. Language is determined by
  the lexicon files you provide."). A case-insensitive grep also matches "Offline**Speak**erDiarization", so do
  not use it.
- There are no espeak-ng API symbols (`espeak_ng_*`, `espeak_Synth`, `espeak_SetVoice*`, `espeak_Initialize`), no
  phoneme tables (`phontab`, `phonindex`) and no `ucd_` symbols. No "general public" text appears.
  `nm -D --defined-only` shows no espeak or piper exports.
- `readelf -d`: `libsherpa-onnx-c-api.so` needs only `libandroid`, `liblog`, `libonnxruntime`, `libm`, `libdl` and
  `libc`.

This matches upstream issue #3731 ("We are planning to remove espeak-ng", closed 20 Oct 2026).

**Consequence:** without espeak-ng, sherpa-onnx 2.0 tokenises Kokoro text **only through the lexicon**, and it
**silently drops every other word**. MEASURED: `3`, `42`, `minutes`, `Kubernetes`, `Tailscale` and `Jellyfin` were
all logged as "OOV word skipped". The lexicons hold base forms only (no `cities`, no `minutes`).

The module therefore does its own English G2P (`tts/kokoro_phonemizer.dart`) and passes the result as
`OfflineTtsGenerationConfig.phonemeCodepoints`. In order:

1. Number, date, money, unit and version normalisation (`text_normalizer.dart`).
2. Lexicon lookup, with ALL-CAPS acronyms spelled out.
3. Inflections of a listed stem (-s, -es, -ies, 's, -ed, -ied, -ing, -er, -est, -ly, -ness, -ment…).
4. camelCase, hyphen and compound splits.
5. A short tech glossary.
6. Spelling rules as a last resort.

MEASURED: the codepoint path produces the same token ids as the lexicon path, and it keeps the space after "!"
that the engine's own text path loses. CJK sentences still use sherpa-onnx's text path with `lexicon-zh.txt`.

## 3. Licences and notices

| Component | Licence | How it ships | Notice |
| --- | --- | --- | --- |
| sherpa-onnx 2.0.1 and its platform packages | Apache-2.0 (STATED, pub.dev; LICENSE in the package) | In the APK | Automatic (pub LICENSE) |
| ONNX Runtime **1.28.2** (MEASURED: `VERS_1.28.2` in `libonnxruntime.so`) | MIT, Microsoft | In the APK, inside the sherpa packages | **Added** in `licenses.dart`; no sherpa package mentions it |
| espeak-ng | GPL-3.0 | **Not present** (§2) | None needed; the data folder is deleted after download |
| Kokoro-82M weights (v1.0, v1.1-zh) | Apache-2.0 (STATED, HF cards; `LICENSE` in the archive) | Downloaded by the user | Added (attribution) |
| Kokoro voices `ff_siwis`, `jf_gongitsune`, `jf_nezumi`, `jf_tebukuro`, `jm_kumo` | Have a "CC BY" source in VOICES.md (STATED) | Inside v1.0 `voices.bin` | Added, with source links |
| Kokoro lexicons (`lexicon-*.txt`) | Covered by the archive's Apache-2.0 `LICENSE`. Upstream origin **NOT VERIFIED** (INFERRED: derived from misaki) | Downloaded | Under the Kokoro entry |
| Moonshine tiny, English | MIT, "Copyright (c) 2025 Useful Sensors, Inc. (dba Moonshine AI)" (STATED, archive `LICENSE`). Non-English Moonshine models are non-commercial and are not used | Downloaded | Added |
| flutter_tts 4.2.5 | MIT | In the APK | Automatic |
| archive 4.7.1, crypto 3.0.8, path_provider 2.1.6 | MIT / BSD-3-Clause | In the APK | Automatic |

`registerSpeechLicenses()`, called by `SpeechServices.create`, adds the entries pub does not provide. The app is
GPL-3.0, and every licence above is compatible with it (Apache-2.0, MIT, BSD-3-Clause, CC BY).

**NOT VERIFIED**: ONNX Runtime's `ThirdPartyNotices.txt` (protobuf, abseil and others) for the components linked
into this build. Have a licence reviewer check it before a store release.

## 4. Storage and download behaviour

- **Location:** `getApplicationSupportDirectory()/speech-models/<id>/`. A partial download is
  `<id>.tar.bz2.part`, with `<id>.part.json` recording the URL and pin.
- **Resume:** sends `Range: bytes=N-`. A 206 with a matching `Content-Range` appends. A 200 restarts from zero. A
  partial for another URL or pin is discarded.
- **Install steps:**
  1. SHA-256 check, in an isolate.
  2. Extraction into `<id>.extracting/`, in an isolate (archive 4.7.1 streaming bzip2 and tar, `verify: true`).
  3. Required-files check.
  4. Rename to `<id>/`; `installed.json` is written last.
- **Wi-Fi only** (on by default) uses `NetworkCapabilities.NET_CAPABILITY_NOT_METERED`.
- **Free space:** checked with `StatFs`. The download needs the archive plus the installed size plus 20 MB.

## 4b. Dictation accuracy and engines (16 November 2026)

A user with Indian-accented English said dictation "is not detecting my English properly". Diagnosis of the
build before this change:

- **Locale:** no language was sent unless one was chosen, so the recogniser used its default, en-US on a phone set to
  English (US). Now `resolveDictationLanguage` always sends a tag: the chosen one, else the device locale, and
  English in the UTC+5:30 time zone (or with country IN) becomes **en-IN**. Settings › Voice shows it as "Automatic".
- **Engine:** `SpeechChannel.kt` preferred `createOnDeviceSpeechRecognizer` and put `EXTRA_PREFER_OFFLINE` on every
  intent, including the default recogniser. So every session used the small on-device model, which also falls back
  to en-US when the en-IN pack is missing. That was the main accuracy loss. Now the default (online Google)
  recogniser is used unless "On this device only" is on, and only the on-device path asks for offline models. A
  network error before any words retries once on the device, and a missing on-device pack retries once online.
- **Cut-offs:** the default end of speech (about 1 s of silence) ended dictation mid-sentence. The intent now asks
  for 2 s / 1.5 s (`EXTRA_SPEECH_INPUT_*_SILENCE_LENGTH_MILLIS`; some recognisers ignore them). While the mic is
  held, `DictationController` restarts an engine that ends at a pause and keeps its words.
- **Formatting:** `EXTRA_ENABLE_FORMATTING` (quality) stays on API 33+; `EXTRA_MASK_OFFENSIVE_WORDS=false` stops
  Google from starring the user's own words.

**Measured** (scripts and clips in `~/.local/state/hermes-live-qa/dictation-r6/`): six Indian-English phrases
(names such as Ramesh and Koramangala, homelab terms such as Proxmox and Jellyfin), synthesised by
gpt-realtime-2.1 through CLIProxyAPI with an Indian-English accent. A second set was band-limited to 250–3600 Hz
with noise at 10 dB SNR, roughly a phone in a room. Word error rate:

| Engine | Clean | Phone-band + noise | Time per phrase |
| --- | --- | --- | --- |
| gpt-4o-transcribe (server, via CLIProxyAPI realtime) | **1.3 %** | **1.3 %** | 1.4 s raw, 2.2 s through `/api/transcribe` |
| gpt-4o-mini-transcribe | 4.3 % | 3.0 % | 1.4 s |
| whisper-1 | 2.6 % | not run | 1.3–3.3 s |
| Moonshine tiny (offline, sherpa-onnx 2.0.1 on x86) | 5.6 % | 21.7 % | 0.2–0.8 s |

Caveats: synthetic speech is cleaner than a real voice. Android's recogniser could not be measured here: no device
work in this round, and it has no desktop build. Its ranking (online en-IN far better than on-device en-US for
accents) rests on the diagnosis above and Google's own guidance, not on numbers. Re-measure on the phone in the QA
round.

**Default: "Tove server"** (`DictationEngineKind.server`). The phone records 16 kHz PCM. `EnergyEndpointer` cuts
phrases at 0.8 s pauses with 300 ms of pre-roll, and each phrase goes to the bridge's `POST /api/transcribe` (server
API.md "Transcription") while the user keeps talking. Text therefore appears phrase by phrase, and on release only
the last phrase is waited for. Earlier words go along as the model's `prompt`. When Moonshine is downloaded it also
shows the phrase being spoken as unstable text. The engine falls back to the phone recogniser when the server has no
`transcribe` capability, the network is down, or "On this device only" is on. The other engines stay selectable.
Saves from before this change (schema 1, which stored `system` as the only default) move to the new default.

## 5. Not done / open

- **Phone benchmarks:** RTF, first-audio latency and RSS for v1.0 fp32 and int8, on the target device.
- **iOS:** needs a Swift channel with the same contract as `SpeechChannel.kt` (SFSpeechRecognizer and an
  AVAudioEngine PCM player). Until then iOS has platform TTS only, and dictation reports "unavailable".
- **Web:** no Web Speech API dictation (reported as unavailable). Platform TTS works through flutter_tts.
- **Desktop:** platform TTS only. Kokoro itself runs there (sherpa_onnx_linux works, as measured here), but there
  is no PCM player.
