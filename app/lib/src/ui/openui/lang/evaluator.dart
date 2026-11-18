// OpenUI Lang evaluator: expressions, built-ins, actions and the
// element-tree evaluation used for rendering.
//
// Ported from @openuidev/lang-core (MIT, Copyright (c) Thesys Inc.):
// runtime/evaluator.ts, runtime/evaluate-tree.ts and runtime/evaluate-prop.ts.
// Nothing here executes code: actions evaluate to plain step objects that
// the host decides how to run.

import 'ast.dart';
import 'builtins.dart';
import 'parser.dart'
    show MaterializeCtx, invalidValue, nameArgs, schemaDefault, validateSchemaValue;

/// A library function as the evaluator runs it.
class RuntimeFunction {
  const RuntimeFunction({required this.params, required this.fn, this.returns});

  /// JSON Schema object of the params (property order is positional).
  final Map<String, Object?> params;
  final Map<String, Object?>? returns;
  final Object? Function(Map<String, Object?> args) fn;
}

class EvaluationContext {
  EvaluationContext({
    required this.getState,
    required this.resolveRef,
    this.functions = const {},
    this.actions = const {},
    this.reportError,
    this.budget,
  });

  final Object? Function(String name) getState;
  final Object? Function(String name) resolveRef;
  final Map<String, RuntimeFunction> functions;

  /// Custom actions: name → `{params: <JSON Schema>}`.
  final Map<String, Map<String, Object?>> actions;
  void Function(String message)? reportError;

  /// Shared work budget: evaluation stops producing values once it runs out,
  /// so a program with exponential sharing cannot hang the UI.
  final EvalBudget? budget;

  EvaluationContext withRef(Object? Function(String) resolve) =>
      EvaluationContext(
        getState: getState,
        resolveRef: resolve,
        functions: functions,
        actions: actions,
        reportError: reportError,
        budget: budget,
      );
}

class EvalBudget {
  EvalBudget(this.remaining);
  int remaining;
  bool get exhausted => remaining <= 0;
  bool spend() => --remaining >= 0;
}

/// Which props bind two-way (signature `$binding<…>`).
abstract interface class SchemaContext {
  bool isReactive(String component, String prop);
}

Object? evaluate(Node node, EvaluationContext ctx, [SchemaContext? schema]) {
  final budget = ctx.budget;
  if (budget != null && !budget.spend()) return null;
  switch (node) {
    case Str():
      return node.v;
    case Num():
      return node.v;
    case Bool():
      return node.v;
    case NullLit():
    case Ph():
      return null;
    case StateRef():
      return ctx.getState(node.n);
    case Ref():
      return ctx.resolveRef(node.n);
    case RuntimeRef():
      return ctx.resolveRef(node.n);
    case Arr():
      return [for (final e in node.els) _defined(evaluate(e, ctx))];
    case Obj():
      return {
        for (final (k, v) in node.entries) k: _defined(evaluate(v, ctx)),
      };
    case Comp():
      return _evaluateComp(node, ctx, schema);
    case BinOp():
      return _binOp(node, ctx);
    case UnaryOp():
      if (node.op == '!') return !truthy(evaluate(node.operand, ctx));
      if (node.op == '-') return -toNumber(evaluate(node.operand, ctx));
      return null;
    case Ternary():
      return truthy(evaluate(node.cond, ctx))
          ? evaluate(node.then, ctx)
          : evaluate(node.otherwise, ctx);
    case Member():
      final obj = evaluate(node.obj, ctx);
      if (obj == null || obj is Undefined) return null;
      if (obj is List) {
        if (node.field == 'length') return obj.length.toDouble();
        return [
          for (final item in obj) _defined(memberOf(item, node.field)),
        ];
      }
      if (obj is ElementNode) return null;
      return memberOf(obj, node.field);
    case Index():
      final obj = evaluate(node.obj, ctx);
      final idx = evaluate(node.index, ctx);
      if (obj == null || obj is Undefined || idx == null || idx is Undefined) {
        return null;
      }
      if (obj is List) {
        final i = toNumber(idx);
        if (i != i.truncateToDouble() || i < 0 || i >= obj.length) {
          return undefined;
        }
        return obj[i.toInt()];
      }
      return memberOf(obj, jsString(idx));
    case Assign():
      return ReactiveAssign(node.target, node.value);
  }
}

/// `undefined` inside data becomes null (JSON has no undefined).
Object? _defined(Object? v) => v is Undefined ? null : v;

Object? _binOp(BinOp node, EvaluationContext ctx) {
  if (node.op == '&&') {
    final l = evaluate(node.left, ctx);
    return truthy(l) ? evaluate(node.right, ctx) : l;
  }
  if (node.op == '||') {
    final l = evaluate(node.left, ctx);
    return truthy(l) ? l : evaluate(node.right, ctx);
  }
  final l = evaluate(node.left, ctx);
  final r = evaluate(node.right, ctx);
  switch (node.op) {
    case '+':
      if (l is String || r is String) {
        String s(Object? v) => v == null || v is Undefined ? '' : jsString(v);
        return s(l) + s(r);
      }
      return toNumber(l) + toNumber(r);
    case '-':
      return toNumber(l) - toNumber(r);
    case '*':
      return toNumber(l) * toNumber(r);
    case '/':
      return toNumber(r) == 0 ? 0.0 : toNumber(l) / toNumber(r);
    case '%':
      if (toNumber(r) == 0) return 0.0;
      return toNumber(l).remainder(toNumber(r));
    case '==':
      return looseEquals(l, r);
    case '!=':
      return !looseEquals(l, r);
    case '>':
      return toNumber(l) > toNumber(r);
    case '<':
      return toNumber(l) < toNumber(r);
    case '>=':
      return toNumber(l) >= toNumber(r);
    case '<=':
      return toNumber(l) <= toNumber(r);
  }
  return null;
}

Object? _evaluateComp(Comp node, EvaluationContext ctx, SchemaContext? schema) {
  final name = node.name;
  final def = builtinCalls[name];
  if (def != null && def.kind == 'function') {
    if (def.lazy) return _evaluateEach(node.args, ctx, schema);
    return runBuiltin(name, _evaluateArgs(node, ctx, def.params));
  }
  if (isBuiltinStep(name)) return _evaluateActionCall(node, ctx);
  final fn = ctx.functions[name];
  if (fn != null) return _callFunction(name, fn, node, ctx);
  final act = ctx.actions[name];
  if (act != null) {
    final params = (act['params'] as Map?)?.cast<String, Object?>() ?? const {};
    final args = _callArgs(node, ctx, params);
    if (_missesRequired(args, params)) return const ActionPlan([]);
    final checked = _checkValue(args, params, name, '', ctx, strict: true);
    if (identical(checked, invalidValue)) return const ActionPlan([]);
    return ActionPlan([
      CustomStep(name, (checked! as Map).cast<String, Object?>()),
    ]);
  }
  final mapped = node.mappedProps;
  if (mapped != null) {
    final props = <String, Object?>{};
    for (final e in mapped.entries) {
      final v = e.value;
      if (v is StateRef && (schema?.isReactive(name, e.key) ?? false)) {
        props[e.key] = ReactiveAssign(v.n, const StateRef(r'$value'));
      } else if (v is StateRef) {
        props[e.key] = schema != null ? ctx.getState(v.n) : v;
      } else {
        props[e.key] = evaluate(v, ctx, schema);
      }
    }
    final el = ElementNode(typeName: name, props: props);
    if (schema != null) {
      for (final e in props.entries.toList()) {
        final v = e.value;
        if (v is ElementNode) {
          props[e.key] = _evaluateElementInline(v, ctx, schema);
        } else if (v is List) {
          props[e.key] = [
            for (final item in v)
              item is ElementNode ? _evaluateElementInline(item, ctx, schema) : item,
          ];
        }
      }
    }
    return el;
  }
  return null;
}

ElementNode _evaluateElementInline(
  ElementNode el,
  EvaluationContext ctx,
  SchemaContext schema,
) {
  if (!el.hasDynamicProps) return el;
  return el.copyWith(
    props: {
      for (final e in el.props.entries)
        e.key: _evaluatePropCore(
          e.value,
          ctx,
          schema,
          schema.isReactive(el.typeName, e.key),
          (child) => _evaluateElementInline(child, ctx, schema),
        ),
    },
  );
}

Map<String, Object?> _evaluateArgs(
  Comp node,
  EvaluationContext ctx,
  List<ParamDef> params,
) {
  final named = node.mappedProps ?? nameArgs(node.args, params);
  return {for (final e in named.entries) e.key: _defined(evaluate(e.value, ctx))};
}

Map<String, Object?> _callArgs(
  Comp node,
  EvaluationContext ctx,
  Map<String, Object?> params,
) {
  final names = ((params['properties'] as Map?)?.keys ?? const [])
      .map((k) => ParamDef(name: '$k'))
      .toList();
  final required = (params['required'] as List?) ?? const [];
  final args = _evaluateArgs(node, ctx, names);
  args.removeWhere((k, v) => v == null && !required.contains(k));
  return args;
}

Object? _checkValue(
  Object? value,
  Object? schema,
  String name,
  String path,
  EvaluationContext ctx, {
  bool strict = false,
}) {
  final m = MaterializeCtx();
  final checked = validateSchemaValue(value, schema, name, path, m);
  for (final e in m.errors) {
    ctx.reportError?.call('@$name: ${e.message}');
  }
  return strict && m.errors.isNotEmpty ? invalidValue : checked;
}

bool _missesRequired(Map<String, Object?> args, Map<String, Object?> params) {
  final required = (params['required'] as List?) ?? const [];
  final props = (params['properties'] as Map?) ?? const {};
  return required.any(
    (k) => args[k] == null && schemaDefault(props[k]) is Undefined,
  );
}

Object? _callFunction(
  String name,
  RuntimeFunction def,
  Comp node,
  EvaluationContext ctx,
) {
  final raw = _callArgs(node, ctx, def.params);
  if (_missesRequired(raw, def.params)) return null;
  final args = _checkValue(raw, def.params, name, '', ctx);
  if (identical(args, invalidValue)) return null;
  Object? result;
  try {
    result = def.fn((args! as Map).cast<String, Object?>());
  } catch (e) {
    ctx.reportError?.call('@$name threw: $e');
    return null;
  }
  if (def.returns == null) return result;
  final checked = _checkValue(result, def.returns, name, '/returns', ctx);
  return identical(checked, invalidValue) || checked is Undefined ? null : checked;
}

ActionPlan _flattenPlans(List values) => ActionPlan([
  for (final v in values)
    if (v is ActionPlan) ...v.steps else if (v is ActionStep) v,
]);

ActionPlan _evaluateActionCall(Comp node, EvaluationContext ctx) {
  final name = node.name;
  final args = node.args;
  if (name == 'Action') {
    final list = args.isNotEmpty ? evaluate(args.first, ctx) : const [];
    return _flattenPlans(list is List ? list : const []);
  }
  switch (name) {
    case 'ToAssistant':
      final a = _evaluateArgs(node, ctx, builtinCalls[name]!.params);
      final msg = a['message'];
      return ActionPlan([
        ToAssistantStep(msg == null ? '' : jsString(msg), a['context']),
      ]);
    case 'OpenUrl':
      final a = _evaluateArgs(node, ctx, builtinCalls[name]!.params);
      final url = a['url'];
      return ActionPlan([OpenUrlStep(url == null ? '' : jsString(url))]);
    case 'Run':
      final ref = args.isNotEmpty ? args.first : null;
      return ActionPlan([
        if (ref is RuntimeRef) RunStep(ref.n, ref.refType),
      ]);
    case 'Set':
      if (args.length < 2 || args.first is! StateRef) {
        return const ActionPlan([]);
      }
      return ActionPlan([SetStep((args.first as StateRef).n, args[1])]);
    case 'Reset':
      final targets = [for (final a in args) if (a is StateRef) a.n];
      return ActionPlan([if (targets.isNotEmpty) ResetStep(targets)]);
  }
  return const ActionPlan([]);
}

/// Replaces `Ref(varName)` with the loop item, so deferred action steps
/// capture their own element.
Node _substitute(Node node, String varName, Object? value) {
  Node sub(Node n) => _substitute(n, varName, value);
  switch (node) {
    case Ref():
      return node.n == varName ? toLiteralAst(value) : node;
    case Member():
      final obj = sub(node.obj);
      if (obj is Obj) {
        for (final (k, v) in obj.entries) {
          if (k == node.field) return v;
        }
      }
      return Member(obj, node.field);
    case Index():
      return Index(sub(node.obj), sub(node.index));
    case BinOp():
      return BinOp(node.op, sub(node.left), sub(node.right));
    case UnaryOp():
      return UnaryOp(node.op, sub(node.operand));
    case Ternary():
      return Ternary(sub(node.cond), sub(node.then), sub(node.otherwise));
    case Arr():
      return Arr([for (final e in node.els) sub(e)]);
    case Obj():
      return Obj([for (final (k, v) in node.entries) (k, sub(v))]);
    case Comp():
      return node.copyWith(
        args: [for (final a in node.args) sub(a)],
        mappedProps: node.mappedProps?.map((k, v) => MapEntry(k, sub(v))),
      );
    case Assign():
      return Assign(node.target, sub(node.value));
    default:
      return node;
  }
}

/// Max items one `@Each` produces.
const int maxEachItems = 200;

Object? _evaluateEach(List<Node> args, EvaluationContext ctx, SchemaContext? schema) {
  if (args.length < 3) return <Object?>[];
  final arr = evaluate(args[0], ctx);
  if (arr is! List) return <Object?>[];
  final v = args[1];
  final varName = switch (v) {
    Ref() => v.n,
    Str() => v.v,
    _ => null,
  };
  if (varName == null || varName.isEmpty) return <Object?>[];
  final template = args[2];
  return [
    for (final item in arr.take(maxEachItems))
      () {
        final child = ctx.withRef(
          (n) => n == varName ? item : ctx.resolveRef(n),
        );
        final r = evaluate(_substitute(template, varName, item), child, schema);
        if (schema != null && r is ElementNode) {
          return _evaluateElementInline(r, child, schema);
        }
        return _defined(r);
      }(),
  ];
}

// ─── Tree evaluation (evaluate-tree.ts / evaluate-prop.ts) ────────────────

Object? _evaluatePropCore(
  Object? value,
  EvaluationContext ctx,
  SchemaContext schema,
  bool reactive,
  ElementNode Function(ElementNode) recurseElement,
) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is ReactiveAssign) {
    return reactive ? value : ctx.getState(value.target);
  }
  if (value is Node) {
    if (value is StateRef && reactive) {
      return ReactiveAssign(value.n, const StateRef(r'$value'));
    }
    final result = evaluate(value, ctx, schema);
    if (result is ElementNode) return recurseElement(result);
    if (result is List) {
      return [
        for (final item in result)
          item is ElementNode ? recurseElement(item) : item,
      ];
    }
    if (result is ReactiveAssign && !reactive) {
      return ctx.getState(result.target);
    }
    return _defined(result);
  }
  if (value is List) {
    return [
      for (final v in value)
        _evaluatePropCore(v, ctx, schema, reactive, recurseElement),
    ];
  }
  if (value is ElementNode) return recurseElement(value);
  if (value is ActionPlan) return value;
  if (value is Map) {
    if (!value.values.any((v) => v != null && v is! String && v is! num && v is! bool)) {
      return value;
    }
    return {
      for (final e in value.entries)
        '${e.key}': _evaluatePropCore(e.value, ctx, schema, reactive, recurseElement),
    };
  }
  return value;
}

/// Evaluates every prop of [el]; a prop whose evaluation throws keeps its
/// raw value and reports `runtime-error`.
ElementNode evaluateElementProps(
  ElementNode el,
  EvaluationContext ctx,
  SchemaContext schema, [
  List<OpenUiError>? errors,
]) {
  if (!el.hasDynamicProps) return el;
  final out = <String, Object?>{};
  for (final e in el.props.entries) {
    try {
      out[e.key] = _evaluatePropCore(
        e.value,
        ctx,
        schema,
        schema.isReactive(el.typeName, e.key),
        (child) => evaluateElementProps(child, ctx, schema, errors),
      );
    } catch (err) {
      out[e.key] = null;
      errors?.add(
        OpenUiError(
          code: 'runtime-error',
          source: 'runtime',
          component: el.typeName,
          statementId: el.statementId,
          message: 'Evaluating prop "${e.key}" on ${el.typeName} failed: $err',
        ),
      );
    }
  }
  return el.copyWith(props: out);
}

/// Evaluates the entry, or the component a runtime entry picks; null if none.
ElementNode? evaluateRoot(
  ParseResult result,
  EvaluationContext ctx,
  SchemaContext schema, [
  List<OpenUiError>? errors,
]) {
  if (result.root != null) {
    return evaluateElementProps(result.root!, ctx, schema, errors);
  }
  final expr = result.rootExpression;
  if (expr == null) return null;
  final value = evaluate(expr, ctx, schema);
  if (value is ElementNode) return evaluateElementProps(value, ctx, schema, errors);
  errors?.add(
    const OpenUiError(
      code: 'no-root',
      source: 'runtime',
      statementId: 'root',
      message: 'root does not evaluate to a component',
    ),
  );
  return null;
}
