// Streaming equals parsing (language.md §4), for every fixture program fed
// one character at a time, plus a fuzz check that nothing ever throws.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/openui/lang/ast.dart';
import 'package:tove_chat/src/ui/openui/lang/parser.dart';

const _dir = 'test/openui/fixtures/1.0';

String _shape(ParseResult r) {
  Object? s(Object? v) => switch (v) {
    ElementNode() => {
      't': v.typeName,
      'p': {for (final e in v.props.entries) e.key: s(e.value)},
    },
    List() => [for (final x in v) s(x)],
    Map() => {for (final e in v.entries) '${e.key}': s(e.value)},
    Node() => v.runtimeType.toString(),
    _ => v,
  };
  return jsonEncode({
    'root': s(r.root),
    'errors': [for (final e in r.meta.errors) e.code]..sort(),
    'state': s(r.stateDeclarations),
  });
}

void main() {
  final schema = (jsonDecode(File('$_dir/library.json').readAsStringSync()) as Map)
      .cast<String, Object?>();
  final lib = compileSchema(
    (schema['schema']! as Map).cast<String, Object?>(),
    root: schema['root'] as String?,
  );
  final programs = <String, String>{};
  for (final area in Directory(_dir).listSync().whereType<Directory>()) {
    for (final c in area.listSync().whereType<Directory>()) {
      final f = File('${c.path}/input.oui');
      if (f.existsSync()) programs[c.path.split('/').last] = f.readAsStringSync();
    }
  }

  test('char-by-char streaming ends equal to a batch parse', () {
    for (final e in programs.entries) {
      final p = StreamParser(lib);
      ParseResult? last;
      for (var i = 0; i < e.value.length; i++) {
        last = p.push(e.value[i], complete: i == e.value.length - 1);
      }
      expect(
        _shape(last!),
        _shape(parseProgram(e.value, lib)),
        reason: e.key,
      );
    }
  });

  test('a fenced program streams with prose around it', () {
    const reply = 'Here is the plan:\n\n```openui\n'
        'root = Stack([t, c])\nt = Text("Hello", "heading")\n'
        'c = Card("Box", [Text("inside")])\n```\n\nAnything else?';
    final p = StreamParser(lib);
    var sawCard = false;
    for (var i = 0; i < reply.length; i++) {
      final r = p.push(reply[i], complete: i == reply.length - 1);
      final root = r.root;
      if (root != null && root.props['children'] is List) {
        sawCard |= (root.props['children'] as List)
            .whereType<ElementNode>()
            .any((n) => n.typeName == 'Card');
      }
    }
    expect(sawCard, isTrue);
    expect(_shape(p.result(complete: true)), _shape(parseProgram(reply, lib)));
  });

  test('random and truncated input never throws', () {
    final rnd = Random(7);
    const alphabet = 'abcXYZ\$@ ()[]{},:=+-*/%!?<>&|."\'\\#\n0123456789';
    final sources = [
      ...programs.values,
      for (var i = 0; i < 300; i++)
        String.fromCharCodes([
          for (var j = 0; j < rnd.nextInt(120); j++)
            alphabet.codeUnitAt(rnd.nextInt(alphabet.length)),
        ]),
    ];
    for (final src in sources) {
      for (var cut = 0; cut <= src.length; cut += 1 + src.length ~/ 9) {
        final r = parseProgram(src.substring(0, cut), lib);
        expect(
          r.meta.errors.where((e) => e.code == 'parse-exception'),
          isEmpty,
          reason: src.substring(0, cut),
        );
      }
    }
  });

  test('deep nesting and huge sharing stay bounded', () {
    final deep = 'root = Stack([${'Stack([' * 300}${'])' * 300}])';
    expect(() => parseProgram(deep, lib), returnsNormally);
    final b = StringBuffer('root = Stack([a0])\n');
    for (var i = 0; i < 40; i++) {
      b.writeln('a$i = Stack([a${i + 1}, a${i + 1}])');
    }
    b.writeln('a40 = Text("x")');
    final sw = Stopwatch()..start();
    parseProgram(b.toString(), lib);
    expect(sw.elapsedMilliseconds, lessThan(2000));
  });
}
