/// English text normalisation for the Kokoro phonemizer: numbers, times,
/// money, percentages, ordinals, versions, units and symbols become words.
///
/// sherpa-onnx 2.0 no longer has espeak-ng, so anything outside its lexicon
/// (every digit included) would otherwise be dropped silently.
library;

const _ones = [
  'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
  'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen',
  'sixteen', 'seventeen', 'eighteen', 'nineteen',
];
const _tens = [
  '', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty',
  'ninety',
];
const _scales = [
  (1000000000000, 'trillion'),
  (1000000000, 'billion'),
  (1000000, 'million'),
  (1000, 'thousand'),
];

/// 0 ≤ n < 10^15 → words, e.g. 1234 → "one thousand two hundred thirty-four".
String numberToWords(int n) {
  if (n < 0) return 'minus ${numberToWords(-n)}';
  if (n < 20) return _ones[n];
  if (n < 100) {
    final t = _tens[n ~/ 10];
    return n % 10 == 0 ? t : '$t-${_ones[n % 10]}';
  }
  if (n < 1000) {
    final rest = n % 100;
    final h = '${_ones[n ~/ 100]} hundred';
    return rest == 0 ? h : '$h ${numberToWords(rest)}';
  }
  for (final (value, name) in _scales) {
    if (n >= value) {
      final rest = n % value;
      final head = '${numberToWords(n ~/ value)} $name';
      return rest == 0 ? head : '$head ${numberToWords(rest)}';
    }
  }
  return n.toString();
}

/// Ordinal words: 1 → "first", 22 → "twenty-second".
String ordinalWords(int n) {
  final w = numberToWords(n);
  const irregular = {
    'one': 'first', 'two': 'second', 'three': 'third', 'five': 'fifth',
    'eight': 'eighth', 'nine': 'ninth', 'twelve': 'twelfth',
  };
  final m = RegExp(r'([a-z]+)$').firstMatch(w)!;
  final last = m.group(1)!;
  final head = w.substring(0, m.start);
  if (irregular.containsKey(last)) return '$head${irregular[last]}';
  if (last.endsWith('y')) return '$head${last.substring(0, last.length - 1)}ieth';
  return '$head${last}th';
}

/// 1900–2099 read as years: 1984 → "nineteen eighty-four", 2005 → "two
/// thousand five", 2026 → "twenty twenty-six".
String yearWords(int y) {
  if (y >= 2000 && y < 2010) return numberToWords(y);
  final hi = y ~/ 100, lo = y % 100;
  if (lo == 0) return '${numberToWords(hi)} hundred';
  return '${numberToWords(hi)} ${lo < 10 ? 'oh ${_ones[lo]}' : numberToWords(lo)}';
}

String _digits(String s) => s.split('').map((d) {
  final v = int.tryParse(d);
  return v == null ? '' : _ones[v];
}).where((w) => w.isNotEmpty).join(' ');

const _units = {
  'kb': ('kilobyte', 'kilobytes'),
  'mb': ('megabyte', 'megabytes'),
  'gb': ('gigabyte', 'gigabytes'),
  'tb': ('terabyte', 'terabytes'),
  'pb': ('petabyte', 'petabytes'),
  'kib': ('kibibyte', 'kibibytes'),
  'mib': ('mebibyte', 'mebibytes'),
  'gib': ('gibibyte', 'gibibytes'),
  'tib': ('tebibyte', 'tebibytes'),
  'mbps': ('megabit per second', 'megabits per second'),
  'gbps': ('gigabit per second', 'gigabits per second'),
  'ms': ('millisecond', 'milliseconds'),
  'us': ('microsecond', 'microseconds'),
  'ns': ('nanosecond', 'nanoseconds'),
  'sec': ('second', 'seconds'),
  'secs': ('second', 'seconds'),
  'min': ('minute', 'minutes'),
  'mins': ('minute', 'minutes'),
  'h': ('hour', 'hours'),
  'hr': ('hour', 'hours'),
  'hrs': ('hour', 'hours'),
  'hz': ('hertz', 'hertz'),
  'khz': ('kilohertz', 'kilohertz'),
  'mhz': ('megahertz', 'megahertz'),
  'ghz': ('gigahertz', 'gigahertz'),
  'km': ('kilometre', 'kilometres'),
  'cm': ('centimetre', 'centimetres'),
  'mm': ('millimetre', 'millimetres'),
  'kg': ('kilogram', 'kilograms'),
  'g': ('gram', 'grams'),
  'w': ('watt', 'watts'),
  'kw': ('kilowatt', 'kilowatts'),
  'kwh': ('kilowatt hour', 'kilowatt hours'),
  'v': ('volt', 'volts'),
  'px': ('pixel', 'pixels'),
  'dp': ('d p', 'd p'),
  'fps': ('frame per second', 'frames per second'),
  'rpm': ('r p m', 'r p m'),
  '°c': ('degree Celsius', 'degrees Celsius'),
  '°f': ('degree Fahrenheit', 'degrees Fahrenheit'),
  '°': ('degree', 'degrees'),
};

const _currency = {
  r'$': ('dollar', 'dollars', 'cent', 'cents'),
  '£': ('pound', 'pounds', 'penny', 'pence'),
  '€': ('euro', 'euros', 'cent', 'cents'),
  '₹': ('rupee', 'rupees', 'paisa', 'paise'),
  '¥': ('yen', 'yen', '', ''),
};

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
  'September', 'October', 'November', 'December',
];

int? _int(String s) => int.tryParse(s.replaceAll(',', ''));

/// A decimal like "3.14" → "three point one four".
String decimalWords(String s) {
  final neg = s.startsWith('-');
  final body = neg ? s.substring(1) : s;
  final parts = body.split('.');
  final whole = _int(parts[0]);
  final head = whole == null ? _digits(parts[0]) : numberToWords(whole);
  final out = parts.length > 1 && parts[1].isNotEmpty
      ? '$head point ${_digits(parts[1])}'
      : head;
  return neg ? 'minus $out' : out;
}

/// Rewrites numbers and symbols in [text] as English words.
String normalizeEnglish(String text) {
  var t = text;

  // Times: 3:42, 3:05 pm, 14:00.
  t = t.replaceAllMapped(
    RegExp(r'\b(\d{1,2}):(\d{2})(?::\d{2})?\s*([AaPp])\.?\s?[Mm]\.?(?![a-z])|\b(\d{1,2}):(\d{2})\b'),
    (m) {
      final h = int.parse(m.group(1) ?? m.group(4)!);
      final min = int.parse(m.group(2) ?? m.group(5)!);
      final ampm = m.group(3);
      if (h > 24 || min > 59) return m.group(0)!;
      final hw = numberToWords(h);
      final mw = min == 0
          ? (ampm == null ? 'hundred' : '')
          : min < 10
          ? 'oh ${numberToWords(min)}'
          : numberToWords(min);
      final suffix = ampm == null ? '' : ' ${ampm.toUpperCase()}M';
      return '$hw${mw.isEmpty ? '' : ' $mw'}$suffix';
    },
  );

  // Currency: $12.50, £3, €1,200.
  t = t.replaceAllMapped(
    RegExp(r'([$£€₹¥])\s?(\d[\d,]*)(?:\.(\d{1,2}))?\b(?:\s?([kKmMbB])\b)?'),
    (m) {
      final (one, many, subOne, subMany) = _currency[m.group(1)]!;
      final whole = _int(m.group(2)!) ?? 0;
      final scale = switch (m.group(4)?.toLowerCase()) {
        'k' => ' thousand',
        'm' => ' million',
        'b' => ' billion',
        _ => '',
      };
      if (scale.isNotEmpty) {
        final num = m.group(3) == null
            ? numberToWords(whole)
            : decimalWords('$whole.${m.group(3)}');
        return '$num$scale $many';
      }
      final cents = m.group(3) == null
          ? 0
          : int.parse(m.group(3)!.padRight(2, '0'));
      final buf = StringBuffer('${numberToWords(whole)} ${whole == 1 ? one : many}');
      if (cents > 0 && subOne.isNotEmpty) {
        buf.write(' and ${numberToWords(cents)} ${cents == 1 ? subOne : subMany}');
      }
      return buf.toString();
    },
  );

  // Version strings: v2.0.1, 1.2.3 → "two point oh point one".
  t = t.replaceAllMapped(
    RegExp(r'\b[vV]?(\d+(?:\.\d+){2,})\b|\b[vV](\d+(?:\.\d+)?)\b'),
    (m) {
      final v = m.group(1) ?? m.group(2)!;
      final words = v
          .split('.')
          .map((p) => p == '0' ? 'oh' : numberToWords(int.parse(p)))
          .join(' point ');
      return m.group(0)!.toLowerCase().startsWith('v') ? 'version $words' : words;
    },
  );

  // Percent.
  t = t.replaceAllMapped(
    RegExp(r'(-?\d[\d,]*(?:\.\d+)?)\s?%'),
    (m) => '${decimalWords(m.group(1)!.replaceAll(',', ''))} percent',
  );

  // Ordinals: 1st, 22nd, 3rd, 4th.
  t = t.replaceAllMapped(
    RegExp(r'\b(\d+)(st|nd|rd|th)\b', caseSensitive: false),
    (m) => ordinalWords(int.parse(m.group(1)!)),
  );

  // ISO dates: 2026-11-15 → "November fifteenth, twenty twenty-six".
  t = t.replaceAllMapped(RegExp(r'\b(\d{4})-(\d{2})-(\d{2})\b'), (m) {
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!), d = int.parse(m.group(3)!);
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return m.group(0)!;
    final yw = y >= 1900 && y <= 2099 ? yearWords(y) : numberToWords(y);
    return '${_months[mo - 1]} ${ordinalWords(d)}, $yw';
  });

  // Number ranges: 3-5, 10–20 → "three to five".
  t = t.replaceAllMapped(
    RegExp(r'\b(\d+)\s?[-–]\s?(\d+)\b(?!\.\d)'),
    (m) => '${m.group(1)} to ${m.group(2)}',
  );

  // Units after a number: 365 MB, 24ms, 21°C.
  t = t.replaceAllMapped(
    RegExp(r'(\d[\d,]*(?:\.\d+)?)\s?(°[CcFf]?|[A-Za-z]{1,4})\b'),
    (m) {
      final unit = _units[m.group(2)!.toLowerCase()];
      if (unit == null) return m.group(0)!;
      // Avoid "5 h" style false matches with ordinary words ("I have 2 g")
      // only for single-letter units without a space.
      final raw = m.group(1)!.replaceAll(',', '');
      final isOne = raw == '1';
      return '$raw ${isOne ? unit.$1 : unit.$2}';
    },
  );

  // Years and plain numbers.
  t = t.replaceAllMapped(
    RegExp(r'(?<![\w.])(-?)(\d{1,3}(?:,\d{3})+|\d+)(\.\d+)?(?![\w])'),
    (m) {
      final neg = m.group(1) == '-';
      final digits = m.group(2)!;
      final frac = m.group(3);
      if (frac != null) return decimalWords('${neg ? '-' : ''}$digits$frac');
      final plain = digits.replaceAll(',', '');
      // Long digit strings (IDs, phone numbers) are read digit by digit.
      if (plain.length > 15 || (plain.length > 1 && plain.startsWith('0'))) {
        return _digits(plain);
      }
      final v = int.parse(plain);
      if (!neg && !digits.contains(',') && v >= 1900 && v <= 2099) {
        return yearWords(v);
      }
      return (neg ? 'minus ' : '') + numberToWords(v);
    },
  );

  // Symbols.
  t = t
      .replaceAll('&', ' and ')
      .replaceAll(RegExp(r'\s\+\s'), ' plus ')
      .replaceAll(RegExp(r'\s=\s'), ' equals ')
      .replaceAll('→', ' to ')
      .replaceAll('->', ' to ')
      .replaceAll('≈', ' about ')
      .replaceAll(RegExp(r'(?<=\w)/(?=\w)'), ' or ')
      .replaceAll(RegExp(r'\s@\s'), ' at ')
      .replaceAll('#', ' number ')
      .replaceAll(RegExp(r'[×✕]'), ' by ');
  return t;
}
