import 'text_normalizer.dart';

/// Word → phoneme string for Kokoro, read from the model's
/// `lexicon-us-en.txt` / `lexicon-gb-en.txt` (`word p h o n e s` per line).
class KokoroLexicon {
  KokoroLexicon(this._entries);

  factory KokoroLexicon.parse(String content) {
    final map = <String, String>{};
    var start = 0;
    while (start < content.length) {
      var end = content.indexOf('\n', start);
      if (end < 0) end = content.length;
      final sp = content.indexOf(' ', start);
      if (sp > start && sp < end) {
        final word = content.substring(start, sp);
        // First entry wins, matching sherpa-onnx.
        map.putIfAbsent(
          word,
          () => content.substring(sp + 1, end).replaceAll(' ', '').trim(),
        );
      }
      start = end + 1;
    }
    return KokoroLexicon(map);
  }

  final Map<String, String> _entries;

  String? operator [](String word) => _entries[word];
  bool contains(String word) => _entries.containsKey(word);
  int get length => _entries.length;
}

/// Parses `tokens.txt` (`<symbol> <id>` per line) into the set of codepoints
/// the model accepts.
Set<int> parseKokoroTokens(String content) {
  final out = <int>{0x20};
  for (final line in content.split('\n')) {
    if (line.isEmpty) continue;
    final sp = line.lastIndexOf(' ');
    if (sp <= 0) continue;
    final sym = line.substring(0, sp);
    if (sym.runes.length == 1) out.add(sym.runes.first);
  }
  return out;
}

/// English grapheme-to-phoneme for Kokoro without espeak-ng.
///
/// sherpa-onnx 2.0 tokenises text only through its lexicon and silently drops
/// every other word (numbers, unlisted plurals, product names). This builds
/// the phoneme string itself and passes it as `phonemeCodepoints`:
///
///  1. [normalizeEnglish] turns numbers, units and symbols into words;
///  2. lexicon lookup, with short ALL-CAPS words spelled out;
///  3. inflections (plural, possessive, -ed, -ing, -er, -ly …) of a listed
///     stem;
///  4. camelCase, hyphen and compound splits into listed words;
///  5. spelling rules as a last resort, so no word is skipped.
class KokoroPhonemizer {
  KokoroPhonemizer({
    required this.lexicon,
    required this.tokens,
    this.british = false,
  });

  final KokoroLexicon lexicon;
  final Set<int> tokens;
  final bool british;

  /// Words that needed the spelling rules in the last call (tests, debugging).
  final List<String> lastRuleWords = [];

  static final _cjk = RegExp(
    r'[぀-ヿ㐀-䶿一-鿿豈-﫿]',
  );

  /// True when the sentence holds CJK text, which goes to sherpa-onnx's own
  /// Chinese lexicon instead.
  static bool hasCjk(String s) => _cjk.hasMatch(s);

  static final _piece = RegExp(
    r"[A-Za-zÀ-ɏ]+(?:['’][A-Za-z]+)*|\d+|[,.!?;:—–…()]",
  );

  /// Phonemes for one sentence.
  String phonemize(String sentence) {
    lastRuleWords.clear();
    final text = normalizeEnglish(sentence);
    final out = StringBuffer();
    for (final m in _piece.allMatches(text)) {
      final p = m.group(0)!;
      final punct = _punctuation(p);
      if (punct != null) {
        if (out.isEmpty) continue;
        final s = out.toString();
        if (',.!?;:—…'.contains(s[s.length - 1])) continue;
        out.write(punct);
        continue;
      }
      final ph = RegExp(r'^\d+$').hasMatch(p)
          ? _words(numberToWords(int.tryParse(p) ?? 0))
          : _word(p);
      if (ph.isEmpty) continue;
      if (out.isNotEmpty) out.write(' ');
      out.write(ph);
    }
    return _filter(out.toString().trim());
  }

  String? _punctuation(String p) => switch (p) {
    ',' || ';' || ':' || '.' || '!' || '?' || '…' => p,
    '—' || '–' => '—',
    '(' || ')' => ',',
    _ => null,
  };

  String _words(String s) => s
      .split(RegExp(r'[\s-]+'))
      .where((w) => w.isNotEmpty)
      .map(_word)
      .join(' ');

  String _filter(String s) {
    final b = StringBuffer();
    for (final r in s.runes) {
      if (tokens.contains(r)) b.writeCharCode(r);
    }
    return b.toString().replaceAll(RegExp(r' {2,}'), ' ');
  }

  // ---- words ---------------------------------------------------------------

  static const _commonCaps = {
    'I', 'A', 'OK', 'OH', 'NO', 'SO', 'GO', 'TO', 'DO', 'WE', 'ME', 'BE', 'MY',
    'AN', 'AT', 'IN', 'IS', 'ON', 'OR', 'UP', 'IF', 'BY', 'OF', 'HE',
    'THE', 'AND', 'FOR', 'NOT', 'YOU', 'ALL', 'ARE', 'BUT', 'CAN', 'HAS',
    'NEW', 'NOW', 'OUT', 'WAS', 'YES', 'STOP', 'NOTE', 'DONE', 'TODO',
  };

  String _word(String raw) {
    var w = _fold(raw).replaceAll('’', "'");
    w = w.replaceAll(RegExp(r"^'+|'+$"), '');
    if (w.isEmpty) return '';

    // Acronyms: GPU, SSD, API, NAS. Longer all-caps words (NASA, HTTPS) use
    // the lexicon when it knows them and they have a vowel.
    final possessive = w.endsWith("'s");
    final letters = possessive ? w.substring(0, w.length - 2) : w;
    if (letters.length >= 2 &&
        letters.length <= 5 &&
        RegExp(r'^[A-Z]+$').hasMatch(letters) &&
        !_commonCaps.contains(letters) &&
        (letters.length <= 3 ||
            !lexicon.contains(letters.toLowerCase()) ||
            !RegExp('[AEIOUY]').hasMatch(letters))) {
      final spelled = _spell(letters);
      return possessive ? '$spelled${_sSuffix(spelled)}' : spelled;
    }

    // camelCase and PascalCase compounds: TailScale, iPhone, OpenWebUI.
    final camel = _splitCamel(w);
    if (camel.length > 1) return _joinCompound(camel.map(_word).toList());

    final lower = w.toLowerCase();
    return techTerms[lower] ??
        _lookup(lower) ??
        _compound(lower) ??
        _rules(lower);
  }

  /// Common homelab and software words the lexicon lacks or gets wrong
  /// (American phonemes; British voices use them too).
  static const techTerms = {
    'kubernetes': 'kˌubəɹnˈɛɾiz',
    'k8s': 'kˈAts',
    'nginx': 'ˈɛnʤɪnˌɛks',
    'onnx': 'ˈɑnɪks',
    'sqlite': 'ˌɛskjuˈɛlˌIt',
    'postgres': 'pˈOstɡɹɛs',
    'postgresql': 'pˈOstɡɹɛs kjˌu ˈɛl',
    'proxmox': 'pɹˈɑksmɑks',
    'homelab': 'hˈOmlˌæb',
    'systemd': 'sˈɪstəm dˈi',
    'json': 'ʤˈAsᵊn',
    'yaml': 'jˈæmᵊl',
    'oauth': 'ˈOˌɔθ',
    'wifi': 'wˈIfˌI',
    'ubuntu': 'ʊbˈʊntu',
    'debian': 'dˈɛbiən',
    'github': 'ɡˈɪthˌʌb',
    'gitlab': 'ɡˈɪtlˌæb',
    'sudo': 'sˈudu',
    'async': 'ˈAsˌɪŋk',
    'regex': 'ɹˈɛʤˌɛks',
    'grafana': 'ɡɹəfˈɑnə',
    'jellyfin': 'ʤˈɛlifˌɪn',
    'sonarr': 'sˈOnˌɑɹ',
    'radarr': 'ɹˈAdˌɑɹ',
    'seerr': 'sˈɪɹ',
    'adguard': 'ˈædɡˌɑɹd',
    'tailscale': 'tˈAlskˌAl',
    'cloudflare': 'klˈWdflˌɛɹ',
    'searxng': 'sˈɜɹʧ ˌɛn ʤˈi',
    'meilisearch': 'mˈAlisˌɜɹʧ',
    'sherpa': 'ʃˈɜɹpə',
    'kokoro': 'kˈOkəɹO',
  };

  String? _lookup(String w) {
    final hit = lexicon[w];
    if (hit != null) return hit;
    if (w.contains('-')) {
      final parts = w.split('-').where((p) => p.isNotEmpty).toList();
      if (parts.length > 1) {
        return _joinCompound(
          parts.map((p) => _lookup(p) ?? _compound(p) ?? _rules(p)).toList(),
        );
      }
    }
    return _inflected(w, allowPrefix: true);
  }

  /// Inflections of a listed stem.
  String? _inflected(String w, {required bool allowPrefix}) {
    String? lex(String s) => s.length >= 2 ? lexicon[s] : null;

    if (w.endsWith("'s")) {
      final base = _lookup(w.substring(0, w.length - 2));
      if (base != null) return '$base${_sSuffix(base)}';
    }
    if (w.endsWith("s'")) {
      final base = _lookup(w.substring(0, w.length - 1));
      if (base != null) return base;
    }
    if (w.endsWith("'")) return _lookup(w.substring(0, w.length - 1));

    // Plural and third person.
    if (w.endsWith('ies') && w.length > 4) {
      final base = lex('${w.substring(0, w.length - 3)}y');
      if (base != null) return '${base}z';
    }
    if (w.endsWith('es') && w.length > 3) {
      final stem = w.substring(0, w.length - 2);
      if (RegExp(r'(s|x|z|ch|sh)$').hasMatch(stem)) {
        final base = lex(stem);
        if (base != null) return '$baseɪz';
      }
    }
    if (w.endsWith('s') && !w.endsWith('ss') && w.length > 3) {
      final base = lex(w.substring(0, w.length - 1));
      if (base != null) return '$base${_sSuffix(base)}';
    }

    // Past tense.
    if (w.endsWith('ied') && w.length > 4) {
      final base = lex('${w.substring(0, w.length - 3)}y');
      if (base != null) return '${base}d';
    }
    if (w.endsWith('ed') && w.length > 3) {
      for (final stem in _stems(w.substring(0, w.length - 2))) {
        final base = lex(stem);
        if (base != null) return '$base${_edSuffix(base)}';
      }
    }

    // Suffixes that append.
    for (final (suffix, us, gb) in _suffixes) {
      if (!w.endsWith(suffix) || w.length <= suffix.length + 2) continue;
      final head = w.substring(0, w.length - suffix.length);
      final candidates = [
        ..._stems(head),
        if (head.endsWith('i')) '${head.substring(0, head.length - 1)}y',
      ];
      for (final stem in candidates) {
        final base = lex(stem);
        if (base != null) return '$base${british ? gb : us}';
      }
    }

    if (!allowPrefix) return null;
    for (final (prefix, ph) in _prefixes) {
      if (w.startsWith(prefix) && w.length > prefix.length + 3) {
        final rest = w.substring(prefix.length);
        final restPh = lexicon[rest] ?? _inflected(rest, allowPrefix: false);
        if (restPh != null) return '$ph${_demote(restPh)}';
      }
    }
    return null;
  }

  static const _suffixes = [
    ('ing', 'ɪŋ', 'ɪŋ'),
    ('ers', 'əɹz', 'əz'),
    ('er', 'əɹ', 'ə'),
    ('est', 'ɪst', 'ɪst'),
    ('ly', 'li', 'li'),
    ('ness', 'nəs', 'nəs'),
    ('ments', 'mənts', 'mənts'),
    ('ment', 'mənt', 'mənt'),
    ('ful', 'fəl', 'fəl'),
    ('less', 'ləs', 'ləs'),
    ('able', 'əbᵊl', 'əbᵊl'),
    ('ization', 'əzˈAʃən', 'IzˈAʃən'),
    ('ized', 'ˌIzd', 'ˌIzd'),
    ('izes', 'ˌIzɪz', 'ˌIzɪz'),
    ('ize', 'ˌIz', 'ˌIz'),
    ('ish', 'ɪʃ', 'ɪʃ'),
  ];

  static const _prefixes = [
    ('un', 'ˌʌn'),
    ('re', 'ɹˌi'),
    ('pre', 'pɹˌi'),
    ('non', 'nˌɑn'),
    ('auto', 'ˌɔɾO'),
    ('multi', 'mˌʌlti'),
    ('sub', 'sˌʌb'),
    ('over', 'ˌOvəɹ'),
    ('micro', 'mˌIkɹO'),
    ('self', 'sˌɛlf'),
  ];

  /// Candidate stems once a suffix is removed: as is, with the silent e
  /// restored, and with a doubled final consonant undone.
  List<String> _stems(String head) => [
    head,
    '${head}e',
    if (head.length > 2 &&
        head[head.length - 1] == head[head.length - 2] &&
        !'aeiou'.contains(head[head.length - 1]))
      head.substring(0, head.length - 1),
  ];

  static const _sibilants = {'s', 'z', 'ʃ', 'ʒ', 'ʧ', 'ʤ'};
  static const _voiceless = {'p', 't', 'k', 'f', 'θ'};

  String _lastPhone(String ph) {
    for (var i = ph.length - 1; i >= 0; i--) {
      final c = ph[i];
      if (c != 'ː' && c != 'ˈ' && c != 'ˌ' && c != ' ') return c;
    }
    return '';
  }

  String _sSuffix(String base) {
    final last = _lastPhone(base);
    if (_sibilants.contains(last)) return 'ɪz';
    if (_voiceless.contains(last)) return 's';
    return 'z';
  }

  String _edSuffix(String base) {
    final last = _lastPhone(base);
    if (last == 't' || last == 'd') return 'ɪd';
    if (_voiceless.contains(last) || const {'s', 'ʃ', 'ʧ'}.contains(last)) {
      return 't';
    }
    return 'd';
  }

  // ---- compounds -----------------------------------------------------------

  List<String> _splitCamel(String w) {
    final plain = w.replaceAll("'", '');
    final parts = RegExp(
      r'[A-Z]+(?![a-z])|[A-Z]?[a-z]+',
    ).allMatches(plain).map((m) => m.group(0)!).toList();
    if (parts.length < 2 || parts.join() != plain) return [w];
    return parts;
  }

  /// Joins compound parts, keeping the first primary stress and demoting the
  /// others, so the word is said as one unit.
  String _joinCompound(List<String> parts) {
    final nonEmpty = parts.where((p) => p.isNotEmpty).toList();
    if (nonEmpty.isEmpty) return '';
    return nonEmpty.first + nonEmpty.skip(1).map(_demote).join();
  }

  String _demote(String ph) => ph.replaceAll('ˈ', 'ˌ');

  /// Splits an unknown word into two or three listed words of at least three
  /// letters each, preferring fewer parts.
  String? _compound(String w) {
    if (w.length < 6 || !RegExp(r'^[a-z]+$').hasMatch(w)) return null;
    final n = w.length;
    final best = List<int>.filled(n + 1, 99);
    final back = List<int>.filled(n + 1, -1);
    best[0] = 0;
    for (var i = 0; i < n; i++) {
      if (best[i] >= 3) continue;
      for (var j = n; j >= i + 3; j--) {
        if (best[i] + 1 < best[j] && lexicon.contains(w.substring(i, j))) {
          best[j] = best[i] + 1;
          back[j] = i;
        }
      }
    }
    if (best[n] < 2 || best[n] > 3) return null;
    final parts = <String>[];
    for (var j = n; j > 0; j = back[j]) {
      parts.insert(0, lexicon[w.substring(back[j], j)]!);
    }
    return _joinCompound(parts);
  }

  // ---- spelling ------------------------------------------------------------

  String _spell(String letters) {
    final parts = <String>[];
    for (final c in letters.toLowerCase().split('')) {
      final ph = c == 'a' ? 'ˈA' : (lexicon[c] ?? _letterNames[c] ?? '');
      if (ph.isNotEmpty) parts.add(ph);
    }
    // Stress the last letter, as in "G P U".
    for (var i = 0; i < parts.length - 1; i++) {
      parts[i] = _demote(parts[i]);
    }
    return parts.join(' ');
  }

  static const _letterNames = {
    'a': 'ˈA', 'b': 'bˈi', 'c': 'sˈi', 'd': 'dˈi', 'e': 'ˈi', 'f': 'ˈɛf',
    'g': 'ʤˈi', 'h': 'ˈAʧ', 'i': 'ˈI', 'j': 'ʤˈA', 'k': 'kˈA', 'l': 'ˈɛl',
    'm': 'ˈɛm', 'n': 'ˈɛn', 'o': 'ˈO', 'p': 'pˈi', 'q': 'kjˈu', 'r': 'ˈɑɹ',
    's': 'ˈɛs', 't': 'tˈi', 'u': 'jˈu', 'v': 'vˈi', 'w': 'dˈʌbᵊlju',
    'x': 'ˈɛks', 'y': 'wˈI', 'z': 'zˈi',
  };

  // ---- spelling rules (last resort) ----------------------------------------

  static const _vowelPhones = 'aeiouæɑɐɒɔəɚɛɜɪʊʌAIOQWYᵊ';

  /// Multi-letter graphemes, longest first, then single consonants.
  static const _graphemes = [
    ('tion', 'ʃən'), ('sion', 'ʒən'), ('ture', 'ʧəɹ'), ('eigh', 'A'),
    ('ough', 'O'), ('igh', 'I'), ('tch', 'ʧ'), ('dge', 'ʤ'), ('sch', 'sk'),
    ('ch', 'ʧ'), ('sh', 'ʃ'), ('th', 'θ'), ('ph', 'f'), ('wh', 'w'),
    ('ck', 'k'), ('ng', 'ŋ'), ('qu', 'kw'), ('gh', 'ɡ'), ('ee', 'i'),
    ('ea', 'i'), ('oo', 'u'), ('ou', 'W'), ('ow', 'W'), ('oa', 'O'),
    ('ai', 'A'), ('ay', 'A'), ('ei', 'A'), ('oi', 'Y'), ('oy', 'Y'),
    ('au', 'ɔ'), ('aw', 'ɔ'), ('ew', 'u'), ('ue', 'u'), ('ie', 'i'),
    ('ar', 'ɑɹ'), ('or', 'ɔɹ'), ('er', 'əɹ'), ('ir', 'ɜɹ'), ('ur', 'ɜɹ'),
    ('x', 'ks'), ('j', 'ʤ'), ('q', 'k'), ('r', 'ɹ'), ('w', 'w'),
    ('b', 'b'), ('d', 'd'), ('f', 'f'), ('h', 'h'), ('k', 'k'), ('l', 'l'),
    ('m', 'm'), ('n', 'n'), ('p', 'p'), ('s', 's'), ('t', 't'), ('v', 'v'),
    ('z', 'z'),
  ];

  static const _short = {'a': 'æ', 'e': 'ɛ', 'i': 'ɪ', 'o': 'ɑ', 'u': 'ʌ'};
  static const _long = {'a': 'A', 'e': 'i', 'i': 'I', 'o': 'O', 'u': 'u'};

  String _rules(String w) {
    final word = w.replaceAll(RegExp(r'[^a-z]'), '');
    if (word.isEmpty) return '';
    lastRuleWords.add(word);
    // A silent final e after one consonant lengthens the vowel before it.
    var silentE = -1, longVowel = -1;
    final m = RegExp(r'([aeiou])([^aeiouwy])e$').firstMatch(word);
    if (m != null && word.length > 3) {
      silentE = word.length - 1;
      longVowel = m.start;
    }
    final out = StringBuffer();
    var i = 0;
    while (i < word.length) {
      if (i == silentE) break;
      final c = word[i];
      if (i > 0 && c == word[i - 1] && !'aeiou'.contains(c)) {
        i++; // Doubled consonants sound once.
        continue;
      }
      if (i == 0 && (word.startsWith('kn') || word.startsWith('wr'))) {
        out.write(word[1] == 'n' ? 'n' : 'ɹ');
        i += 2;
        continue;
      }
      final next = i + 1 < word.length ? word[i + 1] : '';
      if (c == 'c' && next != 'h' && next != 'k') {
        out.write(next.isNotEmpty && 'eiy'.contains(next) ? 's' : 'k');
        i++;
        continue;
      }
      if (c == 'g' && next != 'h') {
        out.write(next.isNotEmpty && 'eiy'.contains(next) ? 'ʤ' : 'ɡ');
        i++;
        continue;
      }
      if (c == 'y') {
        out.write(i == 0 ? 'j' : (i == word.length - 1 ? 'i' : 'ɪ'));
        i++;
        continue;
      }
      if (i != longVowel) {
        final g = _graphemes
            .where((g) => g.$1.length >= 2 && word.startsWith(g.$1, i))
            .firstOrNull;
        if (g != null) {
          out.write(g.$2);
          i += g.$1.length;
          continue;
        }
      }
      if (_short.containsKey(c)) {
        if (i == longVowel) {
          out.write(_long[c]);
        } else if (i == word.length - 1) {
          out.write(switch (c) {
            'a' => 'ə',
            'o' => 'O',
            'e' => '',
            _ => _long[c]!,
          });
        } else {
          out.write(_short[c]);
        }
        i++;
        continue;
      }
      final g = _graphemes.where((g) => word.startsWith(g.$1, i)).firstOrNull;
      if (g != null) {
        out.write(g.$2);
        i += g.$1.length;
      } else {
        i++;
      }
    }
    var ph = out.toString();
    if (british) {
      ph = ph
          .replaceAll('ɑɹ', 'ɑː')
          .replaceAll('ɔɹ', 'ɔː')
          .replaceAll('əɹ', 'ə')
          .replaceAll('ɜɹ', 'ɜː')
          .replaceAll('O', 'Q');
    }
    final first = ph.split('').indexWhere(_vowelPhones.contains);
    if (first >= 0) ph = '${ph.substring(0, first)}ˈ${ph.substring(first)}';
    return ph;
  }

  static String _fold(String s) {
    const from = 'àáâãäåçèéêëìíîïñòóôõöùúûüýÿÀÁÂÃÄÅÇÈÉÊËÌÍÎÏÑÒÓÔÕÖÙÚÛÜÝ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyAAAAAACEEEEIIIINOOOOOUUUUY';
    final b = StringBuffer();
    for (final ch in s.split('')) {
      final i = from.indexOf(ch);
      b.write(i >= 0 ? to[i] : ch);
    }
    return b.toString();
  }
}
