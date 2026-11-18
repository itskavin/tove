// OpenUI Lang AST and runtime value types.
//
// Ported from @openuidev/lang-core (MIT, Copyright (c) Thesys Inc.):
// packages/lang-core/src/parser/ast.ts and parser/types.ts.

/// A JavaScript `undefined`: "absent", as opposed to null.
class Undefined {
  const Undefined._();
  @override
  String toString() => 'undefined';
}

const Object undefined = Undefined._();

/// An expression node. Every node kind of the TS `ASTNode` union.
sealed class Node {
  const Node();
}

class Comp extends Node {
  Comp(this.name, this.args, {this.mappedProps, this.fn = false});
  final String name;
  final List<Node> args;
  final Map<String, Node>? mappedProps;

  /// Set on an `@Name(...)` call whose name is not a built-in or action step.
  bool fn;

  Comp copyWith({List<Node>? args, Map<String, Node>? mappedProps}) =>
      Comp(name, args ?? this.args,
          mappedProps: mappedProps ?? this.mappedProps, fn: fn);
}

class Str extends Node {
  const Str(this.v);
  final String v;
}

class Num extends Node {
  const Num(this.v);
  final double v;
}

class Bool extends Node {
  const Bool(this.v);
  final bool v;
}

class NullLit extends Node {
  const NullLit();
}

class Arr extends Node {
  const Arr(this.els);
  final List<Node> els;
}

class Obj extends Node {
  const Obj(this.entries);
  final List<(String, Node)> entries;
}

class Ref extends Node {
  const Ref(this.n);
  final String n;
}

/// A placeholder for an unresolvable reference.
class Ph extends Node {
  const Ph(this.n);
  final String n;
}

class StateRef extends Node {
  const StateRef(this.n);
  final String n;
}

class RuntimeRef extends Node {
  const RuntimeRef(this.n, this.refType);
  final String n;

  /// `query` or `mutation`.
  final String refType;
}

class BinOp extends Node {
  const BinOp(this.op, this.left, this.right);
  final String op;
  final Node left, right;
}

class UnaryOp extends Node {
  const UnaryOp(this.op, this.operand);
  final String op;
  final Node operand;
}

class Ternary extends Node {
  const Ternary(this.cond, this.then, this.otherwise);
  final Node cond, then, otherwise;
}

class Member extends Node {
  const Member(this.obj, this.field);
  final Node obj;
  final String field;
}

class Index extends Node {
  const Index(this.obj, this.index);
  final Node obj, index;
}

class Assign extends Node {
  const Assign(this.target, this.value);
  final String target;
  final Node value;
}

bool isRuntimeExpr(Node n) => switch (n) {
  StateRef() ||
  RuntimeRef() ||
  BinOp() ||
  UnaryOp() ||
  Ternary() ||
  Member() ||
  Index() ||
  Assign() => true,
  _ => false,
};

void walkAst(Node node, void Function(Node) visit) {
  visit(node);
  switch (node) {
    case Comp():
      for (final a in node.args) {
        walkAst(a, visit);
      }
      for (final a in node.mappedProps?.values ?? const <Node>[]) {
        walkAst(a, visit);
      }
    case Arr():
      for (final e in node.els) {
        walkAst(e, visit);
      }
    case Obj():
      for (final (_, v) in node.entries) {
        walkAst(v, visit);
      }
    case BinOp():
      walkAst(node.left, visit);
      walkAst(node.right, visit);
    case UnaryOp():
      walkAst(node.operand, visit);
    case Ternary():
      walkAst(node.cond, visit);
      walkAst(node.then, visit);
      walkAst(node.otherwise, visit);
    case Member():
      walkAst(node.obj, visit);
    case Index():
      walkAst(node.obj, visit);
      walkAst(node.index, visit);
    case Assign():
      walkAst(node.value, visit);
    default:
      break;
  }
}

Node toLiteralAst(Object? value) {
  if (value == null || value is Undefined) return const NullLit();
  if (value is String) return Str(value);
  if (value is num) return Num(value.toDouble());
  if (value is bool) return Bool(value);
  if (value is List) return Arr([for (final v in value) toLiteralAst(v)]);
  if (value is Map) {
    return Obj([
      for (final e in value.entries) ('${e.key}', toLiteralAst(e.value)),
    ]);
  }
  return const NullLit();
}

/// The plain value of a literal node, or null (as a Dart null record) when
/// the node is not a literal. `(v: x)` wraps a literal value.
({Object? v})? literalValue(Node node) {
  switch (node) {
    case Str():
      return (v: node.v);
    case Num():
      return (v: node.v);
    case Bool():
      return (v: node.v);
    case NullLit():
      return (v: null);
    case Arr():
      final out = <Object?>[];
      for (final e in node.els) {
        final l = literalValue(e);
        if (l == null) return null;
        out.add(l.v);
      }
      return (v: out);
    case Obj():
      final out = <String, Object?>{};
      for (final (k, e) in node.entries) {
        final l = literalValue(e);
        if (l == null) return null;
        out[k] = l.v;
      }
      return (v: out);
    default:
      return null;
  }
}

// ─── Statements ────────────────────────────────────────────────────────────

sealed class Statement {
  const Statement(this.id);
  final String id;
}

class ValueStmt extends Statement {
  const ValueStmt(super.id, this.expr);
  final Node expr;
}

class StateStmt extends Statement {
  const StateStmt(super.id, this.init);
  final Node init;
}

class QueryStmt extends Statement {
  const QueryStmt(super.id, this.args, this.expr);
  final List<Node> args;
  final Comp expr;
}

class MutationStmt extends Statement {
  const MutationStmt(super.id, this.args, this.expr);
  final List<Node> args;
  final Comp expr;
}

// ─── Runtime values ───────────────────────────────────────────────────────

/// One component instance: positional args mapped to named props.
class ElementNode {
  ElementNode({
    required this.typeName,
    required this.props,
    this.partial = false,
    this.hasDynamicProps = true,
    this.statementId,
  });

  final String typeName;
  final Map<String, Object?> props;
  final bool partial;
  final bool hasDynamicProps;
  String? statementId;

  ElementNode copyWith({Map<String, Object?>? props, String? statementId}) =>
      ElementNode(
        typeName: typeName,
        props: props ?? this.props,
        partial: partial,
        hasDynamicProps: hasDynamicProps,
        statementId: statementId ?? this.statementId,
      );
}

/// A two-way binding of a bindable prop to `$target`.
class ReactiveAssign {
  const ReactiveAssign(this.target, this.expr);
  final String target;
  final Node expr;
}

/// One step of an action plan.
sealed class ActionStep {
  const ActionStep();
}

class ToAssistantStep extends ActionStep {
  const ToAssistantStep(this.message, [this.context]);
  final String message;
  final Object? context;
}

class OpenUrlStep extends ActionStep {
  const OpenUrlStep(this.url);
  final String url;
}

class SetStep extends ActionStep {
  const SetStep(this.target, this.valueAst);
  final String target;
  final Node valueAst;
}

class ResetStep extends ActionStep {
  const ResetStep(this.targets);
  final List<String> targets;
}

class RunStep extends ActionStep {
  const RunStep(this.statementId, this.refType);
  final String statementId;
  final String refType;
}

class CustomStep extends ActionStep {
  const CustomStep(this.name, this.params);
  final String name;
  final Map<String, Object?> params;
}

/// An evaluated `Action([...])` or a single `@Step(...)`.
class ActionPlan {
  const ActionPlan(this.steps);
  final List<ActionStep> steps;
}

// ─── Errors ───────────────────────────────────────────────────────────────

class OpenUiError {
  const OpenUiError({
    required this.code,
    this.source = 'parser',
    this.component = '',
    this.path = '',
    this.message = '',
    this.statementId,
    this.severity,
  });

  final String code;
  final String source;
  final String component;
  final String path;
  final String message;
  final String? statementId;

  /// `warning` when the program still renders (the `no-root` fallback).
  final String? severity;

  bool get isWarning => severity == 'warning';

  @override
  String toString() => '$code${statementId == null ? '' : ' @$statementId'}: '
      '$message';
}

class QueryInfo {
  const QueryInfo({
    required this.statementId,
    this.toolAst,
    this.argsAst,
    this.defaultsAst,
    this.refreshAst,
    this.deps = const [],
    this.waitFor = const [],
  });
  final String statementId;
  final Node? toolAst, argsAst, defaultsAst, refreshAst;
  final List<String> deps, waitFor;
}

class MutationInfo {
  const MutationInfo({required this.statementId, this.toolAst, this.argsAst});
  final String statementId;
  final Node? toolAst, argsAst;
}

class ParseMeta {
  const ParseMeta({
    required this.incomplete,
    this.unresolved = const [],
    this.orphaned = const [],
    this.statementCount = 0,
    this.errors = const [],
  });
  final bool incomplete;
  final List<String> unresolved;
  final List<String> orphaned;
  final int statementCount;
  final List<OpenUiError> errors;
}

class ParseResult {
  const ParseResult({
    required this.root,
    required this.meta,
    this.rootExpression,
    this.stateDeclarations = const {},
    this.queryStatements = const [],
    this.mutationStatements = const [],
  });

  static ParseResult empty([bool incomplete = true]) =>
      ParseResult(root: null, meta: ParseMeta(incomplete: incomplete));

  final ElementNode? root;
  final Node? rootExpression;
  final ParseMeta meta;
  final Map<String, Object?> stateDeclarations;
  final List<QueryInfo> queryStatements;
  final List<MutationInfo> mutationStatements;
}
