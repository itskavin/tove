import 'package:flutter/foundation.dart';

import 'tts/kokoro_voices.dart';

/// Adds the speech module's notices to Flutter's licence page.
///
/// Pub packages (sherpa_onnx and its per-platform packages, flutter_tts,
/// archive, crypto, path_provider) already contribute their own LICENSE files
/// automatically. These entries cover what pub does not:
///
///  * ONNX Runtime 1.28.2, linked inside the sherpa_onnx native libraries
///    (MIT, Microsoft). No sherpa package mentions it.
///  * The downloaded models: Kokoro-82M weights (Apache-2.0), the CC BY voice
///    credits, Moonshine English (MIT).
///
/// espeak-ng (GPL-3.0) is not linked into sherpa-onnx 2.0.1's native
/// libraries (checked: no espeak-ng symbols, tables or licence text). The
/// `espeak-ng-data/` folder inside the Kokoro archives is deleted after
/// download without being used, so no espeak-ng notice is needed. See
/// docs/design/voice-models.md.
///
/// Call once at start-up, next to the font licences.
void registerSpeechLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['onnxruntime'], _onnxRuntimeMit);
    yield const LicenseEntryWithLineBreaks(['Kokoro-82M (voice model)'], _kokoro);
    yield LicenseEntryWithLineBreaks(['Kokoro voices (CC BY)'], _voiceCredits());
    yield const LicenseEntryWithLineBreaks([
      'Moonshine (offline dictation model)',
    ], _moonshineMit);
  });
}

bool _registered = false;

String _voiceCredits() {
  final b = StringBuffer(
    'Some Kokoro v1.0 voices were trained on data published under Creative '
    'Commons Attribution licences. They are included in the downloaded voice '
    'table:\n\n',
  );
  for (final e in kokoroCcByVoices.entries) {
    b.writeln('${e.key}: ${e.value}');
  }
  b.write(
    '\nSource: https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md',
  );
  return b.toString();
}

const _kokoro = '''
Kokoro-82M and Kokoro-82M-v1.1-zh by hexgrad
https://huggingface.co/hexgrad/Kokoro-82M
https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh

The model weights are licensed under the Apache License, Version 2.0. They are
downloaded on first use from the k2-fsa/sherpa-onnx "tts-models" GitHub
release (ONNX export by the sherpa-onnx project), which includes the licence
text as LICENSE. The full Apache-2.0 text is also listed under "sherpa_onnx".

Licensed under the Apache License, Version 2.0 (the "License"); you may not
use these files except in compliance with the License. You may obtain a copy
of the License at http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.''';

const _onnxRuntimeMit = '''
ONNX Runtime 1.28.2 (bundled in the sherpa-onnx native libraries)
https://github.com/microsoft/onnxruntime

MIT License

Copyright (c) Microsoft Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.''';

const _moonshineMit = '''
Moonshine English speech recognition models
https://github.com/moonshine-ai/moonshine

Downloaded on first use from the k2-fsa/sherpa-onnx "asr-models" GitHub
release. The English-language models are released under the MIT License.

MIT License

Copyright (c) 2025 Useful Sensors, Inc. (dba Moonshine AI)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.''';
