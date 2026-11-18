import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/speech/speech.dart';
import 'package:tove_chat/src/speech/tts/kokoro_phonemizer.dart';
import 'package:tove_chat/src/speech/tts/text_normalizer.dart';

void main() {
  group('markdownToSpeakable', () {
    test('strips formatting and reads lists item by item', () {
      final s = markdownToSpeakable(
        '# Status\n\nAll **three** disks are *healthy*.\n\n- core is up\n- storage: 2 alerts\n',
      );
      expect(s.split('\n'), [
        'Status.',
        'All three disks are healthy.',
        'core is up.',
        'storage: 2 alerts.',
      ]);
    });

    test('skips code, summarises tables, skips URLs and footnotes', () {
      final s = markdownToSpeakable('''
Run this[^1]:

```bash
sudo reboot
```

| Host | CPU |
| --- | --- |
| core | 12% |
| storage | 3% |

See https://example.com/docs or [the guide](https://example.com/guide).

[^1]: A footnote.
''');
      expect(s, contains('Code block skipped.'));
      expect(s, contains('Table with 2 rows. Host, CPU.'));
      expect(s, isNot(contains('sudo')));
      expect(s, isNot(contains('https')));
      expect(s, contains('the guide'));
      expect(s, isNot(contains('A footnote')));
      expect(s, isNot(contains('core |')));
    });

    test('reads hermes-ui labels and values, never JSON', () {
      final s = markdownToSpeakable('''
```hermes-ui
{"type": "stat", "v": 1, "title": "Disk", "items": [{"label": "Free", "value": "1.2 TB"}]}
```
''');
      expect(s, 'Disk. Free. 1.2 TB.');
    });

    test('drops hosts, IPs and emoji', () {
      final s = markdownToSpeakable(
        'Ping 192.168.1.10 and core.example.com now 🎉',
      );
      expect(s, 'Ping and now.');
    });
  });

  group('splitSentences', () {
    test('splits on terminators, keeps abbreviations and decimals', () {
      final s = splitSentences(
        'Dr. Smith paid 3.14 dollars, e.g. a lot. Then he left! Why?',
      );
      expect(s.map((x) => x.text), [
        'Dr. Smith paid 3.14 dollars, e.g. a lot.',
        'Then he left!',
        'Why?',
      ]);
    });

    test('offsets point into the text', () {
      const t = 'One. Two two.\nThree';
      for (final s in splitSentences(t)) {
        expect(t.substring(s.start, s.end), s.text);
      }
    });

    test('long sentences are cut at clause boundaries', () {
      final long = List.filled(30, 'word').join(' ');
      final t = '$long, $long; $long.';
      final s = splitSentences(t);
      expect(s.length, greaterThan(1));
      expect(s.first.text.length, lessThanOrEqualTo(firstSentenceChars));
      for (final x in s.skip(1)) {
        expect(x.text.length, lessThanOrEqualTo(maxSentenceChars));
      }
    });
  });

  group('normalizeEnglish', () {
    test('numbers, money, time, percent, ordinals, versions, units, dates', () {
      expect(numberToWords(1234), 'one thousand two hundred thirty-four');
      expect(numberToWords(1000000), 'one million');
      expect(ordinalWords(22), 'twenty-second');
      expect(ordinalWords(12), 'twelfth');
      expect(yearWords(2026), 'twenty twenty-six');
      expect(yearWords(2005), 'two thousand five');
      expect(normalizeEnglish(r'$12.50'), 'twelve dollars and fifty cents');
      expect(normalizeEnglish('3:42 PM'), 'three forty-two PM');
      expect(normalizeEnglish('78%'), 'seventy-eight percent');
      expect(normalizeEnglish('the 3rd try'), 'the third try');
      expect(normalizeEnglish('v2.0.1'), 'version two point oh point one');
      expect(normalizeEnglish('365 MB'), 'three hundred sixty-five megabytes');
      expect(normalizeEnglish('1 GB'), 'one gigabyte');
      expect(normalizeEnglish('3-5 days'), 'three to five days');
      expect(
        normalizeEnglish('2026-11-15'),
        'November fifteenth, twenty twenty-six',
      );
      expect(normalizeEnglish('pi is 3.14'), 'pi is three point one four');
      expect(normalizeEnglish('-4 degrees'), 'minus four degrees');
      expect(normalizeEnglish('and/or'), 'and or or');
    });
  });

  group('KokoroPhonemizer', () {
    // A tiny lexicon in the model's format.
    final lexicon = KokoroLexicon.parse('''
the ð ə
city s ˈ ɪ ɾ i
stop s t ˈ ɑ p
box b ˈ ɑ k s
dog d ˈ ɔ ɡ
cat k ˈ æ t
tail t ˈ A l
scale s k ˈ A l
jelly ʤ ˈ ɛ l i
fin f ˈ ɪ n
play p l ˈ A
want w ˈ ɑ n t
three θ ɹ ˈ i
g ʤ ˈ i
p p ˈ i
u j ˈ u
''');
    final tokens = parseKokoroTokens(
      [
        ' 16',
        ...'ðəsˈɪɾitɑpbkdɔɡæAlʤɛfnwθɹjuˌz,.!?'.split('').map((c) => '$c 1'),
      ].join('\n'),
    );
    final p = KokoroPhonemizer(lexicon: lexicon, tokens: tokens);

    test('lexicon words and punctuation', () {
      expect(p.phonemize('The cat!'), 'ðə kˈæt!');
    });

    test('inflections of listed stems', () {
      expect(p.phonemize('cities'), 'sˈɪɾiz');
      expect(p.phonemize('cats'), 'kˈæts');
      expect(p.phonemize('dogs'), 'dˈɔɡz');
      expect(p.phonemize('boxes'), 'bˈɑksɪz');
      expect(p.phonemize('stopped'), 'stˈɑpt');
      expect(p.phonemize('wanted'), 'wˈɑntɪd');
      expect(p.phonemize('played'), 'plˈAd');
      expect(p.phonemize("dog's"), 'dˈɔɡz');
    });

    test('compounds and camelCase keep one primary stress', () {
      expect(p.phonemize('tailscale'), 'tˈAlskˌAl');
      expect(p.phonemize('JellyFin'), 'ʤˈɛlifˌɪn');
    });

    test('acronyms are spelled', () {
      expect(p.phonemize('GPU'), 'ʤˌi pˌi jˈu');
    });

    test('digits become words instead of being dropped', () {
      expect(p.phonemize('3 cats'), 'θɹˈi kˈæts');
    });

    test('unknown words use the spelling rules, never vanish', () {
      final out = p.phonemize('zorblax');
      expect(out, isNotEmpty);
      expect(p.lastRuleWords, ['zorblax']);
    });

    test('codepoints outside the model tokens are removed', () {
      for (final r in p.phonemize('the city, stopped.').runes) {
        expect(tokens, contains(r));
      }
    });

    test('CJK goes to the engine', () {
      expect(KokoroPhonemizer.hasCjk('你好'), isTrue);
      expect(KokoroPhonemizer.hasCjk('hello'), isFalse);
    });
  });
}
