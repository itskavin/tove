// OpenUI Lang parser: preprocessing, schema-aware materialization and
// validation, entry selection, and the streaming parser.
//
// Ported from @openuidev/lang-core (MIT, Copyright (c) Thesys Inc.):
// parser/parser.ts, parser/materialize.ts and parser/validation.ts.

import 'dart:convert' show jsonEncode;

import 'ast.dart';
import 'builtins.dart';
import 'evaluator.dart' show EvaluationContext, evaluate;
import 'syntax.dart';

// ─── Compiled library ─────────────────────────────────────────────────────

/// A library schema compiled for parsing: each component's positional
/// params, and the call registry (built-ins plus library functions and
/// actions).
class CompiledLibrary {
  CompiledLibrary({
    required this.components,
    required this.callDefs,
    this.root,
    this.functionSchemas = const {},
    this.actionSchemas = const {},
  });

  final Map<String, List<ParamDef>> components;
  final Map<String, CallDef> callDefs;
  final String? root;

  /// `schema.functions` / `schema.actions` entries (JSON Schema maps).
  final Map<String, Map<String, Object?>> functionSchemas;
  final Map<String, Map<String, Object?>> actionSchemas;

  bool hasComponent(String name) => components.containsKey(name);
}

const _actionDefNames = ['ActionExpression', 'OpenUrl', 'ToAssistant'];

Object? _inlineActionRefs(Object? node, Map<String, Object?> defs) {
  if (node is Map) {
    final ref = node[r'$ref'];
    if (ref is String) {
      return defs.containsKey(ref) ? _inlineActionRefs(defs[ref], defs) : node;
    }
    return {
      for (final e in node.entries) '${e.key}': _inlineActionRefs(e.value, defs),
    };
  }
  if (node is List) return [for (final x in node) _inlineActionRefs(x, defs)];
  return node;
}

List<ParamDef> _compileParams(Object? def, Map<String, Object?> defs) {
  if (def is! Map) return const [];
  final props = def['properties'];
  final required = (def['required'] as List?)?.cast<Object?>() ?? const [];
  if (props is! Map) return const [];
  return [
    for (final e in props.entries)
      ParamDef(
        name: '${e.key}',
        required: required.contains(e.key),
        defaultValue: schemaDefault(e.value),
        schema: defs.isEmpty ? e.value : _inlineActionRefs(e.value, defs),
      ),
  ];
}

/// Compiles a LibrarySpec JSON Schema (`library.toJSONSchema()` shape).
CompiledLibrary compileSchema(Map<String, Object?> schema, {String? root}) {
  final $defs = (schema[r'$defs'] as Map?)?.cast<String, Object?>() ?? {};
  final propsKeys = (schema['properties'] as Map?)?.keys.map((k) => '$k').toSet();
  final functions =
      (schema['functions'] as Map?)?.cast<String, Object?>() ?? const {};
  final actions = (schema['actions'] as Map?)?.cast<String, Object?>() ?? const {};
  final defs = <String, Object?>{};
  for (final name in [..._actionDefNames, ...actions.keys]) {
    final body = $defs[name];
    if (body != null && !(propsKeys?.contains(name) ?? false)) {
      defs['#/\$defs/$name'] = body;
    }
  }
  final components = <String, List<ParamDef>>{};
  for (final e in $defs.entries) {
    if (propsKeys != null
        ? !propsKeys.contains(e.key)
        : defs.containsKey('#/\$defs/${e.key}')) {
      continue;
    }
    components[e.key] = _compileParams(e.value, defs);
  }
  final callDefs = Map<String, CallDef>.of(builtinCalls);
  for (final e in functions.entries) {
    callDefs[e.key] = CallDef(
      kind: 'function',
      params: _compileParams((e.value as Map?)?['params'], defs),
    );
  }
  for (final e in actions.entries) {
    callDefs[e.key] = CallDef(
      kind: 'action',
      params: _compileParams((e.value as Map?)?['params'], defs),
    );
  }
  return CompiledLibrary(
    components: components,
    callDefs: callDefs,
    root: root,
    functionSchemas: {
      for (final e in functions.entries)
        e.key: (e.value! as Map).cast<String, Object?>(),
    },
    actionSchemas: {
      for (final e in actions.entries)
        e.key: (e.value! as Map).cast<String, Object?>(),
    },
  );
}

// ─── Validation ───────────────────────────────────────────────────────────

/// "This value is invalid" (the TS `INVALID` symbol).
class _Invalid {
  const _Invalid();
}

const Object invalidValue = _Invalid();

class MaterializeCtx {
  MaterializeCtx({
    this.syms = const {},
    this.cat,
    List<OpenUiError>? errors,
    List<String>? unres,
    this.partial = false,
    this.currentStatementId,
    this.unreached,
    this.unknownAsText = false,
  }) : errors = errors ?? [],
       unres = unres ?? [];

  final Map<String, Node> syms;
  final CompiledLibrary? cat;
  final List<OpenUiError> errors;
  final List<String> unres;
  final Set<String> visited = {};
  final bool partial;
  String? currentStatementId;
  final Set<String>? unreached;
  final Map<String, Object?> memo = {};

  /// Host hook (language.md §10): an unknown component renders its string
  /// arguments as text instead of nothing. Off for conformance.
  final bool unknownAsText;
}

Object? schemaDefault(Object? property) =>
    property is Map && property.containsKey('default')
        ? property['default']
        : undefined;

String _jsType(Object? v) => switch (v) {
  List() => 'array',
  String() => 'string',
  num() => 'number',
  bool() => 'boolean',
  null => 'object',
  _ => 'object',
};

String? _refName(Map s) {
  final r = s[r'$ref'];
  return r is String ? r.split('/').last : null;
}

bool _isComposite(Map s) =>
    s.containsKey(r'$ref') ||
    s.containsKey('anyOf') ||
    s.containsKey('oneOf') ||
    s.containsKey('allOf');

({String? type, List<Object?>? enumValues}) _scalarInfo(Map s) {
  if (s['enum'] is List) return (type: null, enumValues: (s['enum'] as List));
  if (s.containsKey('const')) return (type: null, enumValues: [s['const']]);
  return switch (s['type']) {
    'string' => (type: 'string', enumValues: null),
    'number' || 'integer' => (type: 'number', enumValues: null),
    'boolean' => (type: 'boolean', enumValues: null),
    _ => (type: null, enumValues: null),
  };
}

String? typeFromSchema(Object? p) {
  if (p is! Map) return null;
  final ref = _refName(p);
  if (ref != null) return ref;
  final leaf = _scalarInfo(p);
  if (leaf.enumValues != null) {
    return leaf.enumValues!.map(jsonEncode).join('|');
  }
  if (leaf.type != null) return leaf.type;
  return p['type'] is String ? p['type'] as String : null;
}

String buildParamsSignature(String component, List<ParamDef> params) {
  final parts = params.map((p) {
    final type = typeFromSchema(p.schema);
    final marked = p.required ? '${p.name}*' : p.name;
    return type != null ? '$marked: $type' : marked;
  });
  return '$component(${parts.join(', ')})';
}

void pushIssue(
  MaterializeCtx ctx,
  String component,
  String path,
  String code, {
  String message = '',
  String? severity,
}) {
  ctx.errors.add(
    OpenUiError(
      code: code,
      component: component,
      path: path,
      message: message.isEmpty ? _defaultMessage(code, component, path) : message,
      statementId: ctx.currentStatementId,
      severity: severity,
    ),
  );
}

String _defaultMessage(String code, String component, String path) =>
    switch (code) {
      'missing-required' => 'missing required field "$path"',
      'null-required' => 'required field "$path" cannot be null',
      'unknown-component' => 'Unknown component "$component"',
      'inline-reserved' =>
        '$component() must be declared as a top-level statement',
      'unknown-function' => 'Unknown function "@$component"',
      _ => '$code at $component$path',
    };

Object? resolveInvalidValue(bool required, Object? defaultValue) {
  if (defaultValue is! Undefined) return defaultValue;
  return required ? invalidValue : undefined;
}

bool _validateElementPosition(
  ElementNode el,
  Map s,
  String component,
  String path,
  MaterializeCtx ctx,
) {
  if (_isComposite(s)) return false;
  if (s['type'] is String || s['enum'] is List || s.containsKey('const')) {
    pushIssue(
      ctx,
      component,
      path,
      'type-mismatch',
      message: 'field "$path" expects ${s['type'] ?? 'a literal value'} but '
          'got component "${el.typeName}"',
    );
    return true;
  }
  return false;
}

List<String?> _slotRefNames(Map s) {
  final opts = (s['anyOf'] ?? s['oneOf']);
  if (opts is List) {
    return [for (final o in opts) o is Map ? _refName(o) : null];
  }
  return [_refName(s)];
}

bool _isOnlyComponentSlot(Map s, MaterializeCtx ctx) {
  final names = _slotRefNames(s);
  return names.isNotEmpty &&
      names.every((n) => n != null && (ctx.cat?.hasComponent(n) ?? false));
}

Object? _validateObject(
  Object? value,
  Map s,
  String component,
  String path,
  MaterializeCtx ctx,
) {
  if (value is! Map) {
    pushIssue(
      ctx,
      component,
      path,
      'type-mismatch',
      message: 'field "$path" expects object but got ${_jsType(value)}',
    );
    return invalidValue;
  }
  final obj = value;
  Map<String, Object?>? out;
  final props = s['properties'] is Map ? s['properties'] as Map : const {};
  final required = s['required'] is List ? s['required'] as List : const [];
  var invalid = false;
  if (!ctx.partial) {
    for (final key in required) {
      final present = obj.containsKey(key);
      if (!present || obj[key] == null) {
        final fallback = schemaDefault(props[key]);
        if (fallback is! Undefined) {
          (out ??= Map<String, Object?>.of(obj.cast()))['$key'] = fallback;
          continue;
        }
        pushIssue(
          ctx,
          component,
          '$path/$key',
          present ? 'null-required' : 'missing-required',
        );
        invalid = true;
      }
    }
  }
  for (final key in props.keys) {
    if (!obj.containsKey(key)) continue;
    final sub = props[key];
    var next = validateSchemaValue(obj[key], sub, component, '$path/$key', ctx);
    if (identical(next, invalidValue)) {
      next = resolveInvalidValue(required.contains(key), schemaDefault(sub));
      if (identical(next, invalidValue)) {
        invalid = true;
        continue;
      }
    }
    if (_same(next, obj[key])) continue;
    out ??= Map<String, Object?>.of(obj.cast());
    if (next is Undefined) {
      out.remove('$key');
    } else {
      out['$key'] = next;
    }
  }
  return invalid ? invalidValue : (out ?? obj);
}

bool _same(Object? a, Object? b) =>
    identical(a, b) ||
    (a is num && b is num && a == b) ||
    (a is String && b is String && a == b) ||
    (a is bool && b is bool && a == b);

Object? _validateArray(
  Object? value,
  Map s,
  String component,
  String path,
  MaterializeCtx ctx,
) {
  if (value is! List) {
    pushIssue(
      ctx,
      component,
      path,
      'type-mismatch',
      message: 'field "$path" expects array but got ${_jsType(value)}',
    );
    return invalidValue;
  }
  final items = s['items'];
  if (items is! Map) return value;
  List<Object?>? out;
  for (var i = 0; i < value.length; i++) {
    final next = validateSchemaValue(value[i], items, component, '$path/$i', ctx);
    if (!_same(next, value[i]) && out == null) out = value.sublist(0, i);
    if (out != null && !identical(next, invalidValue)) out.add(next);
  }
  return out ?? value;
}

bool _validateLeaf(
  Object? value,
  Map s,
  String component,
  String path,
  MaterializeCtx ctx,
) {
  final leaf = _scalarInfo(s);
  if (leaf.type == null && leaf.enumValues == null) return false;
  if (leaf.enumValues != null && ctx.partial) return false;
  final actual = switch (value) {
    String() => 'string',
    num() => 'number',
    bool() => 'boolean',
    _ => 'object',
  };
  if (leaf.enumValues != null) {
    if (actual == 'object') return false;
    if (leaf.enumValues!.any((e) => _same(e is int ? e.toDouble() : e, value) ||
        _same(e, value))) {
      return false;
    }
    pushIssue(
      ctx,
      component,
      path,
      'type-mismatch',
      message: 'field "$path" expects one of '
          '[${leaf.enumValues!.map(jsonEncode).join(', ')}] but got '
          '${value is num ? jsString(value) : jsonEncode(value)}',
    );
    return true;
  }
  if (leaf.type != actual) {
    pushIssue(
      ctx,
      component,
      path,
      'type-mismatch',
      message: 'field "$path" expects ${leaf.type} but got ${_jsType(value)}',
    );
    return true;
  }
  return false;
}

/// Validates a materialized value against a JSON Schema fragment. Returns
/// the value, a cleaned copy, [invalidValue], or [undefined] (omit).
Object? validateSchemaValue(
  Object? value,
  Object? schema,
  String component,
  String path,
  MaterializeCtx ctx,
) {
  if (schema is! Map) return value;
  if (value == null || value is Undefined) return value;
  if (value is Node) return value;
  if (value is ElementNode) {
    return _validateElementPosition(value, schema, component, path, ctx)
        ? invalidValue
        : value;
  }
  if (_isComposite(schema)) {
    if (!_isOnlyComponentSlot(schema, ctx)) return value;
    pushIssue(
      ctx,
      component,
      path,
      'type-mismatch',
      message: 'field "$path" expects ${_slotRefNames(schema).join(' | ')} '
          'but got ${value is Map ? 'plain object' : _jsType(value)}',
    );
    return invalidValue;
  }
  final type = schema['type'];
  if (type == 'object') return _validateObject(value, schema, component, path, ctx);
  if (type == 'array') return _validateArray(value, schema, component, path, ctx);
  return _validateLeaf(value, schema, component, path, ctx)
      ? invalidValue
      : value;
}

// ─── Materialize ──────────────────────────────────────────────────────────

bool containsDynamicValue(Object? v) {
  if (v == null || v is String || v is num || v is bool) return false;
  if (v is Node) return true;
  if (v is List) return v.any(containsDynamicValue);
  if (v is ElementNode) return v.hasDynamicProps;
  if (v is Map) {
    if (v['steps'] is List) return true;
    return v.values.any(containsDynamicValue);
  }
  return false;
}

ElementNode withStatementId(ElementNode el, String id) {
  if (el.statementId == null || el.statementId == id) {
    el.statementId = id;
    return el;
  }
  return el.copyWith(statementId: id);
}

R withStatement<R>(MaterializeCtx ctx, String id, R Function() fn) {
  final prev = ctx.currentStatementId;
  ctx.currentStatementId = id;
  try {
    return fn();
  } finally {
    ctx.currentStatementId = prev;
  }
}

Map<String, CallDef> _callDefs(MaterializeCtx ctx) =>
    ctx.cat?.callDefs ?? builtinCalls;

bool _isRuntimeCall(String name, MaterializeCtx ctx) =>
    _callDefs(ctx).containsKey(name) || isReservedCall(name);

Object? _resolveRef(String name, MaterializeCtx ctx, bool valueMode) {
  if (ctx.visited.contains(name) || !ctx.syms.containsKey(name)) {
    ctx.unres.add(name);
    return valueMode ? null : Ph(name);
  }
  final target = ctx.syms[name]!;
  ctx.unreached?.remove(name);
  if (target is Comp && isReservedCall(target.name)) {
    return RuntimeRef(name, target.name == 'Mutation' ? 'mutation' : 'query');
  }
  final key = '${valueMode ? 'value' : 'expr'}:$name';
  if (ctx.memo.containsKey(key)) return ctx.memo[key];
  ctx.visited.add(name);
  try {
    return withStatement(ctx, name, () {
      final before = ctx.unres.length;
      var value = valueMode
          ? materializeValue(target, ctx)
          : materializeExpr(target, ctx);
      if (valueMode && value is ElementNode) value = withStatementId(value, name);
      if (ctx.unres.length == before) ctx.memo[key] = value;
      return value;
    });
  } finally {
    ctx.visited.remove(name);
  }
}

Map<String, Node> nameArgs(List<Node> args, List<ParamDef> params) => {
  for (var i = 0; i < params.length && i < args.length; i++)
    params[i].name: args[i],
};

Map<String, Node>? _mapCallArgs(
  String name,
  List<Node> args,
  CallDef def,
  MaterializeCtx ctx,
) {
  final params = def.params;
  if (args.length > params.length) {
    pushIssue(
      ctx,
      name,
      '',
      'excess-args',
      message: '$name takes ${params.length} arg(s), got ${args.length}',
    );
  }
  final mapped = nameArgs(args, params);
  var invalid = false;
  final before = ctx.errors.length;
  for (final p in params) {
    final arg = mapped[p.name];
    final lit = arg != null ? literalValue(arg) : (v: undefined);
    if (lit == null) continue;
    if (lit.v == null || lit.v is Undefined) {
      if (!p.required || p.defaultValue is! Undefined) continue;
      pushIssue(
        ctx,
        name,
        '/${p.name}',
        arg != null ? 'null-required' : 'missing-required',
        message: 'missing required field "/${p.name}" — signature: '
            '${buildParamsSignature(name, params)}',
      );
      invalid = true;
      continue;
    }
    var next = validateSchemaValue(lit.v, p.schema, name, '/${p.name}', ctx);
    if (identical(next, invalidValue)) {
      next = resolveInvalidValue(p.required, p.defaultValue);
    }
    if (identical(next, invalidValue)) {
      invalid = true;
    } else if (next is Undefined) {
      mapped.remove(p.name);
    } else if (!_same(next, lit.v)) {
      mapped[p.name] = toLiteralAst(next);
    }
  }
  if (def.kind == 'action' && ctx.errors.length > before) invalid = true;
  return invalid ? null : mapped;
}

Node _materializeCall(
  Comp node,
  MaterializeCtx ctx,
  Node Function(Node) materializeArg,
) {
  final args = node.args.map(materializeArg).toList();
  final def = _callDefs(ctx)[node.name];
  if (def == null || def.lazy) return node.copyWith(args: args);
  final mapped = def.builtin
      ? nameArgs(args, def.params)
      : _mapCallArgs(node.name, args, def, ctx);
  if (mapped != null) return node.copyWith(args: args, mappedProps: mapped);
  return def.kind == 'action'
      ? Comp('Action', [const Arr([])])
      : const NullLit();
}

Node? _materializeLazyBuiltin(
  Comp node,
  MaterializeCtx ctx,
  Set<String> scoped,
) {
  final def = _callDefs(ctx)[node.name];
  if (def?.kind != 'function' || !def!.lazy || node.args.length < 3) {
    return null;
  }
  final varArg = node.args[1];
  final varName = switch (varArg) {
    Ref() => varArg.n,
    Str() => varArg.v,
    _ => null,
  };
  if (varName == null || varName.isEmpty) return null;
  final next = {...scoped, varName};
  return node.copyWith(
    args: [
      for (final (i, a) in node.args.indexed)
        i == 1 ? a : _materializeExprIn(a, ctx, next),
    ],
  );
}

Node _materializeExprIn(Node node, MaterializeCtx ctx, Set<String> scoped) {
  switch (node) {
    case Ref():
      return scoped.contains(node.n)
          ? node
          : _resolveRef(node.n, ctx, false)! as Node;
    case Ph():
      return node;
    case Comp():
      if (node.fn && !_isRuntimeCall(node.name, ctx)) {
        pushIssue(ctx, node.name, '', 'unknown-function');
        return const NullLit();
      }
      final lazy = _materializeLazyBuiltin(node, ctx, scoped);
      if (lazy != null) return lazy;
      if (_isRuntimeCall(node.name, ctx)) {
        return _materializeCall(
          node,
          ctx,
          (a) => _materializeExprIn(a, ctx, scoped),
        );
      }
      final args = [for (final a in node.args) _materializeExprIn(a, ctx, scoped)];
      final params = ctx.cat?.components[node.name];
      if (params != null) {
        return node.copyWith(args: args, mappedProps: nameArgs(args, params));
      }
      pushIssue(ctx, node.name, '', 'unknown-component');
      return node.copyWith(args: args);
    case Arr():
      return Arr([for (final e in node.els) _materializeExprIn(e, ctx, scoped)]);
    case Obj():
      return Obj([
        for (final (k, v) in node.entries) (k, _materializeExprIn(v, ctx, scoped)),
      ]);
    case BinOp():
      return BinOp(
        node.op,
        _materializeExprIn(node.left, ctx, scoped),
        _materializeExprIn(node.right, ctx, scoped),
      );
    case UnaryOp():
      return UnaryOp(node.op, _materializeExprIn(node.operand, ctx, scoped));
    case Ternary():
      return Ternary(
        _materializeExprIn(node.cond, ctx, scoped),
        _materializeExprIn(node.then, ctx, scoped),
        _materializeExprIn(node.otherwise, ctx, scoped),
      );
    case Member():
      return Member(_materializeExprIn(node.obj, ctx, scoped), node.field);
    case Index():
      return Index(
        _materializeExprIn(node.obj, ctx, scoped),
        _materializeExprIn(node.index, ctx, scoped),
      );
    case Assign():
      return Assign(node.target, _materializeExprIn(node.value, ctx, scoped));
    default:
      return node;
  }
}

Node materializeExpr(Node node, MaterializeCtx ctx) =>
    _materializeExprIn(node, ctx, const {});

/// The string literals inside an unknown component's args, for the
/// unknown-as-text host hook.
String _literalText(List<Node> args) {
  final out = <String>[];
  void walk(Node n) {
    switch (n) {
      case Str():
        if (n.v.trim().isNotEmpty) out.add(n.v.trim());
      case Num():
        out.add(jsNumberToString(n.v));
      case Arr():
        n.els.forEach(walk);
      case Obj():
        for (final (_, v) in n.entries) {
          walk(v);
        }
      default:
        break;
    }
  }

  args.forEach(walk);
  return out.join(' · ');
}

/// Schema-aware materialization: resolves refs, maps positional args to
/// props, validates, and keeps runtime expressions as AST.
Object? materializeValue(Node node, MaterializeCtx ctx) {
  switch (node) {
    case Ref():
      return _resolveRef(node.n, ctx, true);
    case Str():
      return node.v;
    case Num():
      return node.v;
    case Bool():
      return node.v;
    case NullLit():
    case Ph():
      return null;
    case Arr():
      final items = <Object?>[];
      for (final e in node.els) {
        if (e is Ph) continue;
        final v = materializeValue(e, ctx);
        if (v == null && (e is Comp || e is Ref)) continue;
        items.add(v);
      }
      return items;
    case Obj():
      return {
        for (final (k, v) in node.entries) k: materializeValue(v, ctx),
      };
    case Comp():
      final name = node.name;
      final args = node.args;
      if (node.fn && !_isRuntimeCall(name, ctx)) {
        pushIssue(ctx, name, '', 'unknown-function');
        return null;
      }
      if (isReservedCall(name)) {
        pushIssue(ctx, name, '', 'inline-reserved');
        return null;
      }
      if (_isRuntimeCall(name, ctx)) {
        final lazy = _materializeLazyBuiltin(node, ctx, const {});
        if (lazy != null) return lazy;
        return _materializeCall(node, ctx, (a) => materializeExpr(a, ctx));
      }
      final params = ctx.cat?.components[name];
      if (params == null) {
        pushIssue(ctx, name, '', 'unknown-component');
        if (ctx.unknownAsText) {
          final text = _literalText(args);
          if (text.isNotEmpty) {
            return ElementNode(
              typeName: unknownTextType,
              props: {'text': text, 'component': name},
              partial: ctx.partial,
              hasDynamicProps: false,
            );
          }
        }
        return null;
      }
      final props = <String, Object?>{};
      var drop = false;
      for (var i = 0; i < params.length && i < args.length; i++) {
        final p = params[i];
        final value = materializeValue(args[i], ctx);
        props[p.name] = value;
        if (p.schema == null) continue;
        var next = validateSchemaValue(value, p.schema, name, '/${p.name}', ctx);
        if (identical(next, invalidValue)) {
          next = resolveInvalidValue(p.required, p.defaultValue);
          if (identical(next, invalidValue)) {
            drop = true;
          } else if (next is Undefined) {
            props.remove(p.name);
          }
        }
        if (!identical(next, invalidValue) && next is! Undefined) {
          props[p.name] = next;
        }
      }
      if (args.length > params.length) {
        pushIssue(
          ctx,
          name,
          '',
          'excess-args',
          message: '$name takes ${params.length} arg(s), got ${args.length} '
              '(${args.length - params.length} excess dropped)',
        );
      }
      final missing = params.where(
        (p) => p.required && (!props.containsKey(p.name) || props[p.name] == null),
      );
      if (missing.isNotEmpty) {
        final still = <ParamDef>[];
        for (final p in missing) {
          if (p.defaultValue is! Undefined) {
            props[p.name] = p.defaultValue;
          } else {
            still.add(p);
          }
        }
        if (still.isNotEmpty) {
          for (final p in still) {
            pushIssue(
              ctx,
              name,
              '/${p.name}',
              props.containsKey(p.name) ? 'null-required' : 'missing-required',
              message: 'missing required field "/${p.name}" — signature: '
                  '${buildParamsSignature(name, params)}',
            );
          }
          return null;
        }
      }
      if (drop) return null;
      return ElementNode(
        typeName: name,
        props: props,
        partial: ctx.partial,
        hasDynamicProps: props.values.any(containsDynamicValue),
      );
    default:
      return isRuntimeExpr(node) ? materializeExpr(node, ctx) : node;
  }
}

/// The element type the unknown-as-text hook produces.
const String unknownTextType = r'$UnknownText';

// ─── Preprocessing ────────────────────────────────────────────────────────

final _statementStart = RegExp(r'^\s*\$?[A-Za-z_]\w*\s*=(?!=)');
final _fenceLine = RegExp(r'^[ \t]*```[ \t]*([\w.+-]*)[ \t]*(.*?)[ \t]*\r?$');
final _leadingComments = RegExp(r'^(\s*(\/\/|#)[^\n]*\n)+');

String? _openerCode(String tag, String rest) {
  if (_statementStart.hasMatch(rest)) return rest;
  if (tag.isNotEmpty && RegExp(r'^=(?!=)').hasMatch(rest)) return '$tag $rest';
  return null;
}

void _scanCode(String line, ({bool open, int depth}) s, void Function(bool, int) set) {
  var open = s.open;
  var depth = s.depth;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (open) {
      if (c == r'\') {
        i++;
      } else if (c == '"') {
        open = false;
      }
    } else if (c == '"') {
      open = true;
    } else if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if ((c == ')' || c == ']' || c == '}') && depth > 0) {
      depth--;
    }
  }
  set(open, depth);
}

bool _startsProgram(String block) =>
    _statementStart.hasMatch(block.replaceFirst(_leadingComments, ''));

/// Extracts the program from markdown code fences (language.md §1.2).
String stripFences(String input) {
  if (!input.contains('```')) return input;
  final blocks = <String>[];
  final outside = <String>[];
  List<String>? body;
  var script = false;
  var open = false;
  var depth = 0;
  void set(bool o, int d) {
    open = o;
    depth = d;
  }

  for (final line in input.split('\n')) {
    final fence = open ? null : _fenceLine.firstMatch(line);
    if (fence == null) {
      if (script) continue;
      (body ?? outside).add(line);
      if (open || depth > 0 || body != null || _statementStart.hasMatch(line)) {
        _scanCode(line, (open: open, depth: depth), set);
      }
      continue;
    }
    depth = 0;
    final tag = fence[1] ?? '';
    final rest = fence[2] ?? '';
    if (body != null) {
      if (!script) blocks.add(body.join('\n'));
      body = null;
      script = false;
      continue;
    }
    if (rest.contains('```')) continue;
    final code = _openerCode(tag, rest);
    script = tag.toLowerCase() == 'openui-js';
    body = code == null ? [] : [code];
  }
  if (body != null && !script) blocks.add(body.join('\n'));
  if (blocks.any(_startsProgram)) return blocks.join('\n');
  final unfenced = outside.any(_statementStart.hasMatch);
  return unfenced || blocks.every((b) => b.trim().isEmpty)
      ? outside.join('\n')
      : blocks.join('\n');
}

/// Strips `//` and `#` comments outside strings.
String stripComments(String input) {
  String? inStr;
  return input
      .split('\n')
      .map((line) {
        for (var i = 0; i < line.length; i++) {
          final c = line[i];
          if (inStr != null) {
            if (c == r'\' && i + 1 < line.length) {
              i++;
              continue;
            }
            if (c == inStr) inStr = null;
            continue;
          }
          if (c == '"' || c == "'") {
            inStr = c;
            continue;
          }
          if (c == '/' && i + 1 < line.length && line[i + 1] == '/') {
            return line.substring(0, i).trimRight();
          }
          if (c == '#') return line.substring(0, i).trimRight();
        }
        return line;
      })
      .join('\n');
}

String preprocess(String input) =>
    stripComments(stripFences(input.trim())).trim();

// ─── Statements → result ──────────────────────────────────────────────────

Statement classifyStatement(RawStmt raw, Node expr) {
  if (expr is Comp && expr.name == 'Query') {
    return QueryStmt(raw.id, expr.args, expr);
  }
  if (expr is Comp && expr.name == 'Mutation') {
    return MutationStmt(raw.id, expr.args, expr);
  }
  if (raw.idType == T.stateVar) return StateStmt(raw.id, expr);
  return ValueStmt(raw.id, expr);
}

List<String> _collectStateRefs(Object? node) {
  if (node is! Node) return const [];
  final refs = <String>{};
  walkAst(node, (n) {
    if (n is StateRef) refs.add(n.n);
  });
  return refs.toList();
}

List<String> _collectQueryReads(List<Node?> nodes) {
  final reads = <String>{};
  for (final n in nodes) {
    if (n == null) continue;
    walkAst(n, (c) {
      if (c is RuntimeRef && c.refType == 'query') reads.add(c.n);
    });
  }
  return reads.toList();
}

List<List<String>> _findQueryCycles(List<QueryInfo> queries) {
  final order = {for (final (i, q) in queries.indexed) q.statementId: i};
  final reads = {for (final q in queries) q.statementId: q.waitFor};
  final done = <String>{};
  final path = <String>[];
  final cycles = <List<String>>[];
  void visit(String id) {
    path.add(id);
    for (final dep in reads[id]!) {
      final at = path.indexOf(dep);
      if (at >= 0) {
        cycles.add(path.sublist(at)..sort((a, b) => order[a]!.compareTo(order[b]!)));
      } else if (reads.containsKey(dep) && !done.contains(dep)) {
        visit(dep);
      }
    }
    path.removeLast();
    done.add(id);
  }

  for (final q in queries) {
    if (!done.contains(q.statementId)) visit(q.statementId);
  }
  return cycles;
}

bool _onlyBuiltinFunctions(Node node) {
  var ok = true;
  walkAst(node, (c) {
    if (c is Comp && builtinCalls[c.name]?.kind != 'function') ok = false;
  });
  return ok;
}

Object? _stateDefault(Object? value, Map<String, Object?> declared) {
  if (value is Node) {
    return _onlyBuiltinFunctions(value)
        ? evaluate(
            value,
            EvaluationContext(
              getState: (n) => declared[n],
              resolveRef: (_) => null,
            ),
          )
        : null;
  }
  if (value is List) return [for (final v in value) _stateDefault(v, declared)];
  if (value is Map) {
    return {
      for (final e in value.entries) '${e.key}': _stateDefault(e.value, declared),
    };
  }
  return value;
}

bool _isComponentCall(Node? n) =>
    n is Comp && !n.fn && !isBuiltin(n.name) && !isReservedCall(n.name);

({String id, bool fallback})? _pickEntry(
  Map<String, Statement> stmts,
  String? rootName,
) {
  if (stmts.containsKey('root')) return (id: 'root', fallback: false);
  for (final s in stmts.values) {
    if (s is ValueStmt &&
        _isComponentCall(s.expr) &&
        (s.expr as Comp).name == rootName) {
      return (id: s.id, fallback: true);
    }
  }
  return null;
}

bool _resolvesToComponentCall(Node? node, Map<String, Node> syms) {
  final seen = <String>{};
  while (node is Ref && seen.add(node.n)) {
    node = syms[node.n];
  }
  return _isComponentCall(node);
}

bool _containsComponent(Node node) {
  var found = false;
  walkAst(node, (c) {
    if (_isComponentCall(c)) found = true;
  });
  return found;
}

class _PartialRef {
  _PartialRef(this.name, this.stmts);
  final String name;
  final Set<Statement> stmts;
}

ParseResult _buildResult(
  Map<String, Statement> stmtMap,
  bool wasIncomplete,
  int stmtCount,
  CompiledLibrary? cat, {
  bool unknownAsText = false,
  _PartialRef? partialRef,
}) {
  final rootName = cat?.root;
  final entry = _pickEntry(stmtMap, rootName);
  final syms = <String, Node>{
    for (final e in stmtMap.entries)
      e.key: switch (e.value) {
        StateStmt(:final init) => init,
        ValueStmt(:final expr) => expr,
        QueryStmt(:final expr) => expr,
        MutationStmt(:final expr) => expr,
      },
  };
  final unreached = <String>{
    for (final e in stmtMap.entries)
      if (e.key != entry?.id && e.value is ValueStmt) e.key,
  };
  final ctx = MaterializeCtx(
    syms: syms,
    cat: cat,
    partial: wasIncomplete,
    currentStatementId: entry?.id,
    unreached: unreached,
    unknownAsText: unknownAsText,
  );

  ElementNode? root;
  Node? rootExpression;
  if (entry != null) {
    final m = materializeValue(syms[entry.id]!, ctx);
    if (m is ElementNode) {
      root = withStatementId(m, entry.id);
    } else if (m is Node && _containsComponent(m)) {
      rootExpression = m;
    }
  }

  // State, queries, mutations.
  final state = <String, Object?>{};
  final queries = <QueryInfo>[];
  final mutations = <MutationInfo>[];
  for (final s in stmtMap.values) {
    switch (s) {
      case StateStmt():
        state[s.id] = _stateDefault(materializeValue(s.init, ctx), state);
      case QueryStmt():
        final args = withStatement(
          ctx,
          s.id,
          () => [for (final a in s.args) materializeExpr(a, ctx)],
        );
        Node? at(int i) => i < args.length ? args[i] : null;
        queries.add(
          QueryInfo(
            statementId: s.id,
            toolAst: at(0),
            argsAst: at(1),
            defaultsAst: at(2),
            refreshAst: at(3),
            deps: _collectStateRefs(at(1)),
            waitFor: _collectQueryReads([at(0), at(1)]),
          ),
        );
      case MutationStmt():
        final args = withStatement(
          ctx,
          s.id,
          () => [for (final a in s.args) materializeExpr(a, ctx)],
        );
        mutations.add(
          MutationInfo(
            statementId: s.id,
            toolAst: args.isNotEmpty ? args[0] : null,
            argsAst: args.length > 1 ? args[1] : null,
          ),
        );
      case ValueStmt():
        break;
    }
  }
  for (final cycle in _findQueryCycles(queries)) {
    withStatement(
      ctx,
      cycle.first,
      () => pushIssue(
        ctx,
        'Query',
        '',
        'query-cycle',
        message: 'Queries ${cycle.join(', ')} read each other\'s results',
      ),
    );
  }
  for (final s in stmtMap.values) {
    final nodes = switch (s) {
      StateStmt(:final init) => [init],
      ValueStmt(:final expr) => [expr],
      QueryStmt(:final args) => args,
      MutationStmt(:final args) => args,
    };
    for (final n in nodes) {
      for (final dep in _collectStateRefs(n)) {
        if (dep == partialRef?.name && partialRef!.stmts.contains(s)) continue;
        state.putIfAbsent(dep, () => null);
      }
    }
  }

  ctx.currentStatementId = entry?.id;
  final component = rootName ?? '';
  if (entry == null) {
    pushIssue(
      ctx,
      component,
      '',
      'no-root',
      message: component.isNotEmpty
          ? 'No root statement, and no statement calls the root component '
                '$component'
          : 'No root statement',
    );
  } else if (root == null &&
      rootExpression == null &&
      !_resolvesToComponentCall(syms[entry.id], syms)) {
    pushIssue(
      ctx,
      component,
      '',
      'no-root',
      message: 'root does not evaluate to a component',
    );
  } else if (entry.fallback) {
    pushIssue(
      ctx,
      component,
      '',
      'no-root',
      message: 'No root statement. Rendering the first statement that calls '
          'the root component $component',
      severity: root != null ? 'warning' : null,
    );
  }

  return ParseResult(
    root: root,
    rootExpression: rootExpression,
    meta: ParseMeta(
      incomplete: wasIncomplete,
      unresolved: ctx.unres,
      orphaned: entry != null ? unreached.toList() : const [],
      statementCount: stmtCount,
      errors: ctx.errors,
    ),
    stateDeclarations: state,
    queryStatements: queries,
    mutationStatements: mutations,
  );
}

/// Parses a complete program. Never throws: a parser failure returns an
/// empty result with a `parse-exception` error.
ParseResult parseProgram(
  String input,
  CompiledLibrary? cat, {
  bool unknownAsText = false,
}) {
  try {
    final trimmed = preprocess(input);
    if (trimmed.isEmpty) return ParseResult.empty();
    final closed = autoClose(trimmed);
    final stmts = split(tokenize(closed.text));
    if (stmts.isEmpty) return ParseResult.empty(closed.wasIncomplete);
    final map = <String, Statement>{};
    for (final s in stmts) {
      map[s.id] = classifyStatement(s, parseExpression(s.tokens));
    }
    return _buildResult(
      map,
      closed.wasIncomplete,
      map.length,
      cat,
      unknownAsText: unknownAsText,
    );
  } catch (e) {
    return _exception(e);
  }
}

ParseResult _exception(Object e) => ParseResult(
  root: null,
  meta: ParseMeta(
    incomplete: false,
    errors: [
      OpenUiError(code: 'parse-exception', message: 'Parser failed: $e'),
    ],
  ),
);

/// Incremental parser (language.md §4). Completed statements are parsed
/// once; the pending tail is re-parsed with implicit closing on each update.
class StreamParser {
  StreamParser(this.cat, {this.unknownAsText = false});

  final CompiledLibrary? cat;
  final bool unknownAsText;

  String _buf = '';
  String _cleaned = '';
  int _completedEnd = 0;
  final Map<String, Statement> _completed = {};
  int _completedCount = 0;

  String get text => _buf;

  void reset() {
    _buf = '';
    _cleaned = '';
    _completedEnd = 0;
    _completed.clear();
    _completedCount = 0;
  }

  ParseResult push(String chunk, {bool complete = false}) {
    _buf += chunk;
    return result(complete: complete);
  }

  /// Sets the full text; pushes only the delta when it extends the buffer.
  ParseResult set(String fullText, {bool complete = false}) {
    if (fullText.length < _buf.length || !fullText.startsWith(_buf)) reset();
    _buf = fullText;
    return result(complete: complete);
  }

  void _addStmt(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    for (final s in split(tokenize(t))) {
      _completed[s.id] = classifyStatement(s, parseExpression(s.tokens));
      _completedCount++;
    }
  }

  void _refresh() {
    final next = preprocess(_buf);
    if (!next.startsWith(_cleaned.substring(0, _completedEnd))) {
      _completedEnd = 0;
      _completed.clear();
      _completedCount = 0;
    }
    _cleaned = next;
  }

  int _scanNewCompleted() {
    var depth = 0, ternary = 0;
    String? inStr;
    var esc = false;
    var stmtStart = _completedEnd;
    final c = _cleaned;
    for (var i = _completedEnd; i < c.length; i++) {
      final ch = c[i];
      if (esc) {
        esc = false;
        continue;
      }
      if (ch == r'\' && inStr != null) {
        esc = true;
        continue;
      }
      if (inStr != null) {
        if (ch == inStr) inStr = null;
        continue;
      }
      if (ch == '"' || ch == "'") {
        inStr = ch;
        continue;
      }
      if (ch == '(' || ch == '[' || ch == '{') {
        depth++;
      } else if (ch == ')' || ch == ']' || ch == '}') {
        depth = depth > 0 ? depth - 1 : 0;
      } else if (ch == '?' && depth == 0) {
        ternary++;
      } else if (ch == ':' && depth == 0 && ternary > 0) {
        ternary--;
      } else if (ch == '\n' && depth <= 0 && ternary <= 0) {
        var peek = i + 1;
        while (peek < c.length &&
            (c[peek] == ' ' || c[peek] == '\t' || c[peek] == '\r' || c[peek] == '\n')) {
          peek++;
        }
        if (peek < c.length && (c[peek] == '?' || (c[peek] == ':' && ternary > 0))) {
          continue;
        }
        final t = c.substring(stmtStart, i).trim();
        if (t.isNotEmpty) _addStmt(t);
        stmtStart = i + 1;
        _completedEnd = i + 1;
      }
    }
    return stmtStart;
  }

  ParseResult result({bool complete = false}) {
    try {
      return _result(complete);
    } catch (e) {
      return _exception(e);
    }
  }

  ParseResult _result(bool complete) {
    _refresh();
    final pendingStart = _scanNewCompleted();
    final pending = _cleaned.substring(pendingStart).trim();
    if (pending.isEmpty) {
      if (_completedCount == 0) return ParseResult.empty();
      return _buildResult(
        _completed,
        false,
        _completedCount,
        cat,
        unknownAsText: unknownAsText,
      );
    }
    final closed = autoClose(pending);
    final stmts = split(tokenize(closed.text));
    if (stmts.isEmpty) {
      if (_completedCount == 0) return ParseResult.empty(closed.wasIncomplete);
      return _buildResult(
        _completed,
        closed.wasIncomplete,
        _completedCount,
        cat,
        unknownAsText: unknownAsText,
      );
    }
    final all = Map<String, Statement>.of(_completed);
    final pendingStmts = <Statement>{};
    for (final s in stmts) {
      if (_completed.containsKey(s.id) && closed.wasIncomplete) continue;
      final stmt = classifyStatement(s, parseExpression(s.tokens));
      all[s.id] = stmt;
      pendingStmts.add(stmt);
    }
    String? tailName;
    if (!complete) {
      final tail = RegExp(r'\$\w+$').firstMatch(_buf)?[0];
      if (tail != null &&
          pending.endsWith(tail) &&
          !RegExp('${RegExp.escape(tail)}(?!\\w)').hasMatch(
            pending.substring(0, pending.length - tail.length),
          )) {
        tailName = tail;
      }
    }
    return _buildResult(
      all,
      closed.wasIncomplete,
      _completedCount + stmts.length,
      cat,
      unknownAsText: unknownAsText,
      partialRef: tailName == null ? null : _PartialRef(tailName, pendingStmts),
    );
  }
}
