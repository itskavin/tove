/// Value formats for hermes-ui `calc` inputs and outputs (chat-rendering-v2
/// §3.5): `"{} unit"`, `number:N`, `percent:N`, `currency:XXX` and
/// `duration:min`. Null values show "—".
library;

const _symbols = <String, String>{
  'USD': r'$',
  'EUR': '€',
  'GBP': '£',
  'INR': '₹',
  'JPY': '¥',
  'CNY': 'CN¥',
  'AUD': r'A$',
  'CAD': r'CA$',
  'CHF': 'CHF ',
  'SEK': 'SEK ',
  'NOK': 'NOK ',
  'DKK': 'DKK ',
  'KRW': '₩',
  'BRL': r'R$',
  'MXN': r'MX$',
  'SGD': r'S$',
  'HKD': r'HK$',
  'NZD': r'NZ$',
  'ZAR': 'R ',
  'RUB': '₽',
  'PLN': 'zł ',
  'TRY': '₺',
};

const _zeroDecimal = {'JPY', 'KRW'};

/// Formats [v] with [format] (null: a plain number).
String formatUiValue(double? v, String? format) {
  if (v == null || !v.isFinite) return '—';
  final f = format ?? '';
  if (f.startsWith('number:')) {
    return groupDigits(v, int.parse(f.substring(7)));
  }
  if (f.startsWith('percent:')) {
    return '${groupDigits(v * 100, int.parse(f.substring(8)))}%';
  }
  if (f.startsWith('currency:')) {
    final code = f.substring(9);
    final digits = _zeroDecimal.contains(code) ? 0 : 2;
    final sym = _symbols[code] ?? '$code ';
    final s = groupDigits(v.abs(), digits);
    return '${v < 0 ? '−' : ''}$sym$s';
  }
  if (f == 'duration:min') return formatMinutes(v);
  if (f.contains('{}')) return f.replaceFirst('{}', plainNumber(v));
  return plainNumber(v);
}

/// A number with up to two decimals, trailing zeros dropped, grouped.
String plainNumber(double v) {
  final r = (v * 100).roundToDouble() / 100;
  if (r == r.truncateToDouble()) return groupDigits(r, 0);
  final two = groupDigits(r, 2);
  return two.endsWith('0') ? two.substring(0, two.length - 1) : two;
}

/// [v] with [decimals] decimals and "," thousands separators; a typographic
/// minus for negatives.
String groupDigits(double v, int decimals) {
  final neg = v < 0;
  final s = v.abs().toStringAsFixed(decimals);
  final dot = s.indexOf('.');
  final whole = dot < 0 ? s : s.substring(0, dot);
  final frac = dot < 0 ? '' : s.substring(dot);
  final b = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) b.write(',');
    b.write(whole[i]);
  }
  final out = '$b$frac';
  final isZero = double.parse(s) == 0;
  return neg && !isZero ? '−$out' : out;
}

/// Minutes as "3 h 10 min", "45 min" or "2 h".
String formatMinutes(double minutes) {
  final m = minutes.round();
  final neg = m < 0;
  final a = m.abs();
  final h = a ~/ 60, r = a % 60;
  final s = h == 0
      ? '$r min'
      : r == 0
      ? '$h h'
      : '$h h $r min';
  return neg ? '−$s' : s;
}
