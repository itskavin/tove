/// LaTeX maths in replies, shown as readable text.
///
/// Models often write `\[ x = \frac{-b \pm \sqrt{b^2-4ac}}{2a} \]` even when
/// asked not to. Markdown would eat the backslashes and show
/// `[ x = frac{-b pm sqrt{b^2-4ac}}{2a} ]`. Tove has no maths typesetter, so
/// display and inline maths (`\[…\]`, `\(…\)`, `$$…$$`) become plain Unicode
/// text: `x = (−b ± √(b²−4ac))/(2a)`. Single `$` is left alone (prices).
library;

final _segment = RegExp(
  r'\\\[([\s\S]+?)\\\]|\\\(([\s\S]+?)\\\)|\$\$([\s\S]+?)\$\$',
);

const _symbols = {
  'implies': '⇒',
  'Rightarrow': '⇒',
  'rightarrow': '→',
  'to': '→',
  'Leftrightarrow': '⇔',
  'iff': '⇔',
  'leftarrow': '←',
  'times': '×',
  'cdot': '·',
  'div': '÷',
  'pm': '±',
  'mp': '∓',
  'le': '≤',
  'leq': '≤',
  'ge': '≥',
  'geq': '≥',
  'neq': '≠',
  'ne': '≠',
  'approx': '≈',
  'equiv': '≡',
  'infty': '∞',
  'pi': 'π',
  'theta': 'θ',
  'alpha': 'α',
  'beta': 'β',
  'gamma': 'γ',
  'delta': 'δ',
  'Delta': 'Δ',
  'lambda': 'λ',
  'mu': 'μ',
  'sigma': 'σ',
  'Sigma': 'Σ',
  'sum': 'Σ',
  'int': '∫',
  'partial': '∂',
  'in': '∈',
  'degree': '°',
  'circ': '°',
  'therefore': '∴',
  'quad': '  ',
  'qquad': '    ',
  'ldots': '…',
  'dots': '…',
  'cdots': '⋯',
  'percent': '%',
};

const _sup = {
  '0': '⁰', '1': '¹', '2': '²', '3': '³', '4': '⁴', '5': '⁵', '6': '⁶', //
  '7': '⁷', '8': '⁸', '9': '⁹', '+': '⁺', '-': '⁻', 'n': 'ⁿ', 'i': 'ⁱ',
};

const _sub = {
  '0': '₀', '1': '₁', '2': '₂', '3': '₃', '4': '₄', '5': '₅', '6': '₆', //
  '7': '₇', '8': '₈', '9': '₉', '+': '₊', '-': '₋',
};

/// [source] with each maths segment replaced by readable text. Code (fenced
/// or inline) is left as it is.
String plainMath(String source) {
  if (!source.contains(r'\[') &&
      !source.contains(r'\(') &&
      !source.contains(r'$$')) {
    return source;
  }
  if (source.trimLeft().startsWith('```') ||
      source.trimLeft().startsWith('~~~')) {
    return source;
  }
  // Keep inline code spans out of it.
  final parts = source.split('`');
  for (var i = 0; i < parts.length; i += 2) {
    parts[i] = parts[i].replaceAllMapped(_segment, (m) {
      return latexToText((m[1] ?? m[2] ?? m[3])!.trim());
    });
  }
  return parts.join('`');
}

/// One LaTeX expression as plain text.
String latexToText(String s) {
  var t = s;
  // Groups that only style: \text{…}, \mathrm{…}, \left( \right).
  t = t.replaceAllMapped(
    RegExp(
      r'\\(?:text|mathrm|mathbf|mathit|operatorname|textbf)\s*\{([^{}]*)\}',
    ),
    (m) => m[1]!,
  );
  t = t.replaceAll(RegExp(r'\\(?:left|right|big|Big|bigg|Bigg)\s*'), '');
  t = t.replaceAll(RegExp(r'\\[,;:! ]'), ' ');
  // \frac and \sqrt, innermost first, a few rounds for nesting.
  for (var round = 0; round < 4; round++) {
    final before = t;
    t = t.replaceAllMapped(
      RegExp(r'\\[dt]?frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}'),
      (m) => '${_wrap(m[1]!)}/${_wrap(m[2]!)}',
    );
    t = t.replaceAllMapped(
      RegExp(r'\\[dt]?frac\s*(\d)\s*(\d)'),
      (m) => '${m[1]}/${m[2]}',
    );
    t = t.replaceAllMapped(
      RegExp(r'\\sqrt\s*\{([^{}]*)\}'),
      (m) => '√${_wrap(m[1]!)}',
    );
    if (t == before) break;
  }
  t = t.replaceAllMapped(
    RegExp(r'\\([A-Za-z]+)'),
    (m) => _symbols[m[1]!] ?? m[1]!,
  );
  t = t.replaceAllMapped(
    RegExp(r'\^\{([^{}]*)\}|\^(\w)'),
    (m) => _script(m[1] ?? m[2]!, _sup, '^'),
  );
  t = t.replaceAllMapped(
    RegExp(r'_\{([^{}]*)\}|_(\w)'),
    (m) => _script(m[1] ?? m[2]!, _sub, '_'),
  );
  t = t.replaceAll(RegExp(r'[{}]'), '');
  t = t.replaceAll('-', '−'); // inside maths a hyphen is a minus
  return t.replaceAll(RegExp(r'[ \t]{2,}(?!\S*  )'), ' ').trim();
}

String _wrap(String x) {
  final v = x.trim();
  // A number or a single symbol needs no brackets: 1/2, x/y; 2a/(b+c) does.
  return RegExp(r'^(\d+(\.\d+)?|\w)$').hasMatch(v) ? v : '($v)';
}

String _script(String v, Map<String, String> table, String mark) {
  final chars = v.split('');
  if (chars.every(table.containsKey)) return chars.map((c) => table[c]).join();
  return v.length == 1 ? '$mark$v' : '$mark($v)';
}
