import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:glob/glob.dart';
import 'package:l10n_health/src/config.dart';
import 'package:l10n_health/src/unicode.dart';
import 'package:path/path.dart' as p;

/// A string literal in Dart code that might be user-facing text.
class StringLiteralHit {
  StringLiteralHit({
    required this.file,
    required this.line,
    required this.column,
    required this.value,
    required this.interpolated,
  });

  final String file;
  final int line;
  final int column;

  /// Literal text, with each interpolation replaced by `{}`.
  final String value;
  final bool interpolated;
}

/// An invisible character inside a Dart file.
class DartInvisibleHit {
  DartInvisibleHit(this.file, this.hit);
  final String file;
  final InvisibleHit hit;
}

/// Everything the checks need to know about the Dart side of a project.
class DartScan {
  DartScan({
    required this.filesScanned,
    required this.strictUses,
    required this.looseUses,
    required this.literals,
    required this.invisible,
    required this.suppressions,
    required this.stringMentions,
  });

  final int filesScanned;

  /// How many times each key is read through a localizations accessor.
  /// Empty in loose mode.
  final Map<String, int> strictUses;

  /// How many times each key name is accessed as a member at all.
  final Map<String, int> looseUses;

  final List<StringLiteralHit> literals;
  final List<DartInvisibleHit> invisible;
  final SuppressionIndex suppressions;

  /// First location of every plain string literal's value, as
  /// `file:line`. A key that appears as a literal may be looked up
  /// dynamically.
  final Map<String, String> stringMentions;
}

/// Below this many files, isolate start-up costs more than it saves.
const _parallelThreshold = 400;

/// Scans the Dart sources configured in [config]. Only member names in
/// [keys] are counted as usages; everything else is skipped early.
///
/// Parsing dominates the cost, so large projects are split across one
/// isolate per core. Each worker parses and visits its files and sends back
/// plain records, never syntax trees; aliases and strict usages are then
/// resolved here, once every worker's alias candidates are known.
Future<DartScan> scanDart(
  L10nConfig config, {
  required Set<String> keys,
}) async {
  final files = _listFiles(config);
  final options = _ScanOptions.from(config, keys);

  final workers =
      files.length < _parallelThreshold
          ? 1
          : math.min(Platform.numberOfProcessors, files.length ~/ 150);
  final List<_ChunkResult> chunks;
  if (workers <= 1) {
    chunks = [_scanChunk(options, files)];
  } else {
    chunks = await Future.wait([
      for (final chunk in _balance(config.root, files, workers))
        Isolate.run(() => _scanChunk(options, chunk)),
    ]);
  }
  return _reduce(options, chunks, files.length);
}

List<String> _listFiles(L10nConfig config) {
  final matchers = [for (final g in config.exclude) _PathMatcher(g)];
  final files = <String>[];
  for (final source in config.sources) {
    final dir = Directory(p.join(config.root, source));
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final rel = p.relative(entity.path, from: config.root);
      final posix = p.posix.joinAll(p.split(rel));
      if (_isGenerated(posix)) continue;
      if (matchers.any((m) => m.matches(posix))) continue;
      files.add(rel);
    }
  }
  return files..sort();
}

/// The built-in excludes from [L10nConfig.defaultExcludes], checked with
/// string operations rather than globs: this runs once per file.
bool _isGenerated(String posix) {
  for (final suffix in const [
    '.g.dart',
    '.freezed.dart',
    '.gr.dart',
    '.gen.dart',
    '.config.dart',
    '.mocks.dart',
  ]) {
    if (posix.endsWith(suffix)) return true;
  }
  return posix.startsWith('generated/') ||
      posix.contains('/generated/') ||
      posix.contains('.dart_tool/') ||
      posix.startsWith('build/') ||
      posix.contains('/build/');
}

/// A glob, with plain `dir/**` patterns short-circuited to a prefix test.
class _PathMatcher {
  _PathMatcher(String pattern)
    : _prefix =
          RegExp(r'^[\w\-./]+/\*\*$').hasMatch(pattern)
              ? pattern.substring(0, pattern.length - 2)
              : null,
      _glob = Glob(pattern);

  final String? _prefix;
  final Glob _glob;

  bool matches(String posix) {
    final prefix = _prefix;
    return prefix != null ? posix.startsWith(prefix) : _glob.matches(posix);
  }
}

/// Splits [files] into [n] chunks of similar total size, so no worker is
/// left parsing the few huge files while the others sit idle.
List<List<String>> _balance(String root, List<String> files, int n) {
  final sized = [for (final f in files) (f, File(p.join(root, f)).lengthSync())]
    ..sort((a, b) => b.$2.compareTo(a.$2));
  final chunks = [for (var i = 0; i < n; i++) <String>[]];
  final totals = List.filled(n, 0);
  for (final (file, size) in sized) {
    var smallest = 0;
    for (var i = 1; i < n; i++) {
      if (totals[i] < totals[smallest]) smallest = i;
    }
    chunks[smallest].add(file);
    totals[smallest] += size;
  }
  return chunks;
}

/// Everything a worker needs, as plain sendable data.
class _ScanOptions {
  _ScanOptions({
    required this.root,
    required this.keys,
    required this.strict,
    required this.className,
    required this.accessors,
    required this.ignoreCalls,
    required this.ignoreNamedArgs,
    required this.ignoreClasses,
    required this.allowInvisible,
  });

  factory _ScanOptions.from(L10nConfig config, Set<String> keys) {
    final hardcoded = config.check('hardcoded_string');
    return _ScanOptions(
      root: config.root,
      keys: keys,
      strict: config.usageMode == UsageMode.strict,
      className: config.className,
      accessors: config.accessors,
      ignoreCalls: {
        ..._defaultIgnoredCalls,
        ...hardcoded.listOption('ignore_calls'),
      },
      ignoreNamedArgs: {
        ..._defaultIgnoredNamedArgs,
        ...hardcoded.listOption('ignore_named_args'),
      },
      ignoreClasses: hardcoded.listOption(
        'ignore_classes',
        _defaultIgnoredClasses,
      ),
      allowInvisible: config.allowedInvisible,
    );
  }

  final String root;
  final Set<String> keys;
  final bool strict;
  final String? className;
  final List<String> accessors;
  final Set<String> ignoreCalls;
  final Set<String> ignoreNamedArgs;
  final List<String> ignoreClasses;
  final Set<int> allowInvisible;
}

/// What can be known about an expression without seeing the whole project:
/// its last identifier (an alias, if some declaration says so) and, when it
/// starts like an accessor pattern, its normalised source.
class _Shape {
  const _Shape(this.last, this.source);
  final String? last;
  final String? source;

  bool get isUseless => last == null && source == null;
}

class _AliasCandidate {
  _AliasCandidate({
    required this.name,
    required this.file,
    required this.global,
    required this.typed,
    this.shape,
  });

  final String name;
  final String file;

  /// Getters, fields and top-level variables are visible everywhere;
  /// locals and parameters only in their own file.
  final bool global;

  /// Declared with the localizations type, so an alias unconditionally.
  final bool typed;

  /// Otherwise, an alias when this initialiser or getter body is one.
  final _Shape? shape;
}

class _Access {
  _Access(this.key, this.file, this.shape);
  final String key;
  final String file;
  final _Shape shape;
}

class _ChunkResult {
  final looseUses = <String, int>{};
  final accesses = <_Access>[];
  final aliases = <_AliasCandidate>[];
  final literals = <StringLiteralHit>[];
  final invisible = <DartInvisibleHit>[];
  final suppressions = SuppressionIndex();
  final stringMentions = <String, String>{};
}

_ChunkResult _scanChunk(_ScanOptions options, List<String> files) {
  final result = _ChunkResult();
  final shapes = _ShapeBuilder(options);
  final ignoreClasses = [for (final r in options.ignoreClasses) RegExp(r)];
  for (final rel in files) {
    final source = File(p.join(options.root, rel)).readAsStringSync();
    final unit =
        parseString(
          content: source,
          path: p.join(options.root, rel),
          throwIfDiagnostics: false,
        ).unit;
    result.suppressions.index(rel, source);
    if (options.strict) unit.accept(_AliasCollector(shapes, rel, result));
    unit.accept(
      _UsageAndLiteralVisitor(
        file: rel,
        unit: unit,
        options: options,
        shapes: shapes,
        result: result,
        ignoreClasses: ignoreClasses,
      ),
    );
    for (final hit in findInvisible(source, allow: options.allowInvisible)) {
      result.invisible.add(DartInvisibleHit(rel, hit));
    }
  }
  return result;
}

DartScan _reduce(_ScanOptions options, List<_ChunkResult> chunks, int files) {
  final resolver = _AliasResolver(options);
  final candidates = [for (final c in chunks) ...c.aliases];

  // Aliases can chain (`S get l10n => S.of(this)`, then `final t =
  // context.l10n`), so iterate until nothing new is learned.
  var changed = true;
  while (changed) {
    changed = false;
    for (final c in candidates) {
      if (resolver.isAlias(c.name, c.file)) continue;
      final shape = c.shape;
      if (c.typed || (shape != null && resolver.matches(shape, c.file))) {
        resolver.add(c);
        changed = true;
      }
    }
  }

  final strictUses = <String, int>{};
  final looseUses = <String, int>{};
  final literals = <StringLiteralHit>[];
  final invisible = <DartInvisibleHit>[];
  final suppressions = SuppressionIndex();
  final stringMentions = <String, String>{};
  for (final c in chunks) {
    for (final a in c.accesses) {
      if (resolver.matches(a.shape, a.file)) {
        strictUses[a.key] = (strictUses[a.key] ?? 0) + 1;
      }
    }
    c.looseUses.forEach((k, v) => looseUses[k] = (looseUses[k] ?? 0) + v);
    literals.addAll(c.literals);
    invisible.addAll(c.invisible);
    suppressions.merge(c.suppressions);
    c.stringMentions.forEach((k, v) => stringMentions.putIfAbsent(k, () => v));
  }
  // Chunks finish in any order; keep reports stable.
  literals.sort(
    (a, b) =>
        a.file != b.file
            ? a.file.compareTo(b.file)
            : a.line != b.line
            ? a.line.compareTo(b.line)
            : a.column.compareTo(b.column),
  );
  invisible.sort(
    (a, b) =>
        a.file != b.file
            ? a.file.compareTo(b.file)
            : a.hit.offset.compareTo(b.hit.offset),
  );

  return DartScan(
    filesScanned: files,
    strictUses: strictUses,
    looseUses: looseUses,
    literals: literals,
    invisible: invisible,
    suppressions: suppressions,
    stringMentions: stringMentions,
  );
}

String _normalize(String source) {
  var s = source.replaceAll(RegExp(r'\s+'), '');
  while (s.endsWith('!') || s.endsWith('?')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// Accessor patterns: `S.current`, `S.of(...)`, plus configured ones.
class _Patterns {
  _Patterns(_ScanOptions options) {
    final cls = options.className;
    if (cls != null) {
      final c = RegExp.escape(cls);
      regexps
        ..add(RegExp('^$c\\.current\$'))
        ..add(RegExp('^$c\\.(maybeOf|of)\\(.*\\)\$'));
      heads.add(cls);
    }
    for (final a in options.accessors) {
      final normalized = _normalize(a);
      final pattern = normalized.split('*').map(RegExp.escape).join('.*');
      regexps.add(RegExp('^$pattern\$'));
      heads.add(RegExp(r'^[A-Za-z_$][\w$]*').stringMatch(normalized) ?? '');
    }
  }

  final regexps = <RegExp>[];

  /// Leftmost identifiers of the patterns. An expression starting with
  /// anything else cannot match, so its source is never built.
  final heads = <String>{};

  bool matchesSource(String source) => regexps.any((r) => r.hasMatch(source));
}

/// Builds [_Shape]s inside a worker.
class _ShapeBuilder {
  _ShapeBuilder(this.options) : patterns = _Patterns(options);
  final _ScanOptions options;
  final _Patterns patterns;

  _Shape of(Expression target) {
    final e = _unwrap(target);
    final last = switch (e) {
      SimpleIdentifier(:final name) => name,
      PrefixedIdentifier(:final identifier) => identifier.name,
      PropertyAccess(:final propertyName) => propertyName.name,
      _ => null,
    };
    final head = _leftmost(e);
    final source =
        head != null && patterns.heads.contains(head)
            ? _normalize(target.toSource())
            : null;
    return _Shape(last, source);
  }

  static String? _leftmost(Expression e) => switch (e) {
    SimpleIdentifier(:final name) => name,
    PrefixedIdentifier(:final prefix) => prefix.name,
    PropertyAccess(:final target?) => _leftmost(target),
    MethodInvocation(:final target?) => _leftmost(target),
    MethodInvocation(:final methodName) => methodName.name,
    PostfixExpression(:final operand) => _leftmost(operand),
    ParenthesizedExpression(:final expression) => _leftmost(expression),
    _ => null,
  };

  static Expression _unwrap(Expression e) => switch (e) {
    PostfixExpression(:final operand) => _unwrap(operand),
    ParenthesizedExpression(:final expression) => _unwrap(expression),
    _ => e,
  };

  /// True when [type] names the localizations class, and not a type
  /// parameter that happens to share its name (`class Cubit<S>`).
  bool isClassType(TypeAnnotation? type) {
    final cls = options.className;
    if (cls == null || type is! NamedType || type.importPrefix != null) {
      return false;
    }
    if (type.name.lexeme != cls) return false;
    for (AstNode? n = type; n != null; n = n.parent) {
      if (_declaresTypeParameter(n, cls)) return false;
    }
    return true;
  }
}

/// True when [node] declares a type parameter named [name], directly
/// (`void f<S>()`) or through a name part (`class Cubit<S>` on analyzer 10
/// and later). Written against [AstNode.childEntities] so that it works on
/// every supported analyzer version.
bool _declaresTypeParameter(AstNode node, String name) {
  bool declares(TypeParameterList list) =>
      list.typeParameters.any((p) => p.name.lexeme == name);
  for (final child in node.childEntities) {
    if (child is TypeParameterList) {
      if (declares(child)) return true;
    } else if (child is AstNode && child is! Declaration) {
      for (final grandchild in child.childEntities) {
        if (grandchild is TypeParameterList && declares(grandchild)) {
          return true;
        }
      }
    }
  }
  return false;
}

/// The name of a named argument or record field (`label: value`), from its
/// tokens, so that it works whichever node type the analyzer uses for it.
String? _argumentName(AstNode argument) {
  final first = argument.beginToken;
  final next = first.next;
  if (!first.isIdentifier || next == null) return null;
  return next.type == TokenType.COLON ? first.lexeme : null;
}

/// Decides, once every alias is known, whether a shape is the
/// localizations object.
class _AliasResolver {
  _AliasResolver(_ScanOptions options) : patterns = _Patterns(options);
  final _Patterns patterns;
  final _global = <String>{};
  final _local = <String, Set<String>>{};

  bool isAlias(String name, String file) =>
      _global.contains(name) || (_local[file]?.contains(name) ?? false);

  void add(_AliasCandidate c) {
    if (c.global) {
      _global.add(c.name);
    } else {
      _local.putIfAbsent(c.file, () => {}).add(c.name);
    }
  }

  bool matches(_Shape shape, String file) {
    final last = shape.last;
    if (last != null && isAlias(last, file)) return true;
    final source = shape.source;
    return source != null && patterns.matchesSource(source);
  }
}

class _AliasCollector extends RecursiveAstVisitor<void> {
  _AliasCollector(this.shapes, this.file, this.result);
  final _ShapeBuilder shapes;
  final String file;
  final _ChunkResult result;

  void _candidate(
    String name, {
    required bool global,
    required bool typed,
    Expression? from,
  }) {
    final shape = from == null ? null : shapes.of(from);
    if (!typed && (shape == null || shape.isUseless)) return;
    result.aliases.add(
      _AliasCandidate(
        name: name,
        file: file,
        global: global,
        typed: typed,
        shape: shape,
      ),
    );
  }

  @override
  void visitVariableDeclarationList(VariableDeclarationList node) {
    final isLocal =
        node.parent is VariableDeclarationStatement ||
        node.parent is ForPartsWithDeclarations;
    final typed = shapes.isClassType(node.type);
    for (final v in node.variables) {
      _candidate(
        v.name.lexeme,
        global: !isLocal,
        typed: typed,
        from: v.initializer,
      );
    }
    super.visitVariableDeclarationList(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.isGetter) _getter(node.name.lexeme, node.returnType, node.body);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.isGetter) {
      _getter(node.name.lexeme, node.returnType, node.functionExpression.body);
    }
    super.visitFunctionDeclaration(node);
  }

  void _getter(String name, TypeAnnotation? returnType, FunctionBody body) {
    _candidate(
      name,
      global: true,
      typed: shapes.isClassType(returnType),
      from: body is ExpressionFunctionBody ? body.expression : null,
    );
  }

  // A parameter typed as the class: `void f(S s)`. Matched from the type
  // upwards, because the parameter node types differ between analyzer
  // versions.
  @override
  void visitNamedType(NamedType node) {
    final parameter = node.parent;
    if (parameter is FormalParameter && shapes.isClassType(node)) {
      final name = parameter.name;
      // `S f()` declares a function-typed parameter, not an S.
      if (name != null && name.next?.type != TokenType.OPEN_PAREN) {
        _candidate(name.lexeme, global: false, typed: true);
      }
    }
    super.visitNamedType(node);
  }
}

class _UsageAndLiteralVisitor extends RecursiveAstVisitor<void> {
  _UsageAndLiteralVisitor({
    required this.file,
    required this.unit,
    required this.options,
    required this.shapes,
    required this.result,
    required this.ignoreClasses,
  }) : ignoreCalls = options.ignoreCalls,
       ignoreNamedArgs = options.ignoreNamedArgs;

  final String file;
  final CompilationUnit unit;
  final _ScanOptions options;
  final _ShapeBuilder shapes;
  final _ChunkResult result;
  final Set<String> ignoreCalls;
  final Set<String> ignoreNamedArgs;
  final List<RegExp> ignoreClasses;

  void _use(String name, Expression? target) {
    if (!options.keys.contains(name)) return;
    result.looseUses[name] = (result.looseUses[name] ?? 0) + 1;
    if (!options.strict || target == null) return;
    final shape = shapes.of(target);
    if (!shape.isUseless) result.accesses.add(_Access(name, file, shape));
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    _use(node.propertyName.name, node.realTarget);
    super.visitPropertyAccess(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    _use(node.identifier.name, node.prefix);
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.realTarget;
    if (target != null) _use(node.methodName.name, target);
    super.visitMethodInvocation(node);
  }

  // Directives, annotations and the like never hold UI text; skip their
  // subtrees entirely.
  @override
  void visitImportDirective(ImportDirective node) {}
  @override
  void visitExportDirective(ExportDirective node) {}
  @override
  void visitPartDirective(PartDirective node) {}
  @override
  void visitPartOfDirective(PartOfDirective node) {}
  @override
  void visitLibraryDirective(LibraryDirective node) {}
  @override
  void visitAnnotation(Annotation node) {}
  @override
  void visitAssertStatement(AssertStatement node) {}
  @override
  void visitAssertInitializer(AssertInitializer node) {}

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    // 'Hello ' 'world' is one piece of text, not two.
    final parts = [for (final s in node.strings) _text(s)];
    if (parts.every((t) => t != null)) {
      _literal(node, parts.join(), node.strings.any(_isInterpolation));
    }
    // The parts are not visited as literals of their own, but expressions
    // interpolated into them still read keys.
    for (final part in node.strings) {
      if (part is! StringInterpolation) continue;
      for (final element in part.elements) {
        if (element is InterpolationExpression) element.expression.accept(this);
      }
    }
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    result.stringMentions.putIfAbsent(
      node.value,
      () => '$file:${unit.lineInfo.getLocation(node.offset).lineNumber}',
    );
    _literal(node, node.value, false);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    final text = _text(node);
    if (text != null) _literal(node, text, true);
    // Interpolated expressions can contain key accesses.
    super.visitStringInterpolation(node);
  }

  static bool _isInterpolation(StringLiteral s) => s is StringInterpolation;

  static String? _text(StringLiteral s) => switch (s) {
    SimpleStringLiteral(:final value) => value,
    StringInterpolation(:final elements) =>
      [
        for (final e in elements) e is InterpolationString ? e.value : '{}',
      ].join(),
    _ => null,
  };

  void _literal(StringLiteral node, String value, bool interpolated) {
    if (_inIgnoredContext(node)) return;
    final loc = unit.lineInfo.getLocation(node.offset);
    result.literals.add(
      StringLiteralHit(
        file: file,
        line: loc.lineNumber,
        column: loc.columnNumber,
        value: value,
        interpolated: interpolated,
      ),
    );
  }

  bool _inIgnoredContext(AstNode node) {
    final cls = node.thisOrAncestorOfType<ClassDeclaration>();
    if (cls != null && _matchesClass(cls.classKeyword.next!.lexeme)) {
      return true;
    }
    // toString() output is for debugging, not for users.
    final method = node.thisOrAncestorOfType<MethodDeclaration>();
    if (method != null && method.name.lexeme == 'toString') return true;

    AstNode child = node;
    AstNode? parent = node.parent;
    while (parent != null) {
      switch (parent) {
        case IndexExpression(:final index) when index == child:
          return true; // json['key']
        case MapLiteralEntry(:final key) when key == child:
          return true;
        case SwitchCase() || SwitchPatternCase() || ConstantPattern():
          return true;
        case ThrowExpression():
          return true;
        // Comparisons: `if (status == 'Abgeschlossen')` matches data, it
        // does not display it.
        case BinaryExpression(:final operator)
            when operator.lexeme == '==' || operator.lexeme == '!=':
          return true;
        case ArgumentList() || RecordLiteral()
            when _ignoredArg(_argumentName(child) ?? ''):
          return true;
        case MethodInvocation(:final methodName, :final target):
          if (_ignoredCall(methodName.name)) return true;
          final receiver = switch (target) {
            SimpleIdentifier(:final name) => name,
            PrefixedIdentifier(:final identifier) => identifier.name,
            PropertyAccess(:final propertyName) => propertyName.name,
            _ => null,
          };
          if (receiver != null && _ignoredCall(receiver)) return true;
        case InstanceCreationExpression(:final constructorName):
          if (_ignoredCall(constructorName.type.name.lexeme)) return true;
        case FunctionExpressionInvocation(:final function)
            when function is SimpleIdentifier && _ignoredCall(function.name):
          return true;
        case Statement() || ClassMember() || CompilationUnitMember():
          return false;
      }
      child = parent;
      parent = parent.parent;
    }
    return false;
  }

  /// Logging, tracing and diagnostics, whatever the project calls them:
  /// `log`, `logDebug`, `_logger.info`, `debugPrint`, `trackEvent`,
  /// `crashlytics.recordError`.
  static final _diagnosticName = RegExp(
    r'^_*(log|debug|trace|verbose|print|track|record|report|crash|'
    r'breadcrumb|analytics|sentry|telemetry)|(log|logger|logging)$',
    caseSensitive: false,
  );

  /// Exception and error types carry developer-facing messages.
  static final _diagnosticType = RegExp(r'(Exception|Error)$');

  bool _ignoredCall(String name) =>
      ignoreCalls.contains(name) ||
      _diagnosticName.hasMatch(name) ||
      _diagnosticType.hasMatch(name);

  bool _ignoredArg(String name) =>
      ignoreNamedArgs.contains(name) || _diagnosticName.hasMatch(name);

  bool _matchesClass(String name) => ignoreClasses.any((r) => r.hasMatch(name));
}

/// Calls and constructors whose string arguments are never UI text.
const _defaultIgnoredCalls = {
  'print',
  'debugPrint',
  'debugPrintStack',
  'log',
  'assert',
  'Logger',
  'RegExp',
  'Key',
  'ValueKey',
  'ObjectKey',
  'GlobalKey',
  'PageStorageKey',
  'UniqueKey',
  'Uri',
  'parse',
  'tryParse',
  'DateFormat',
  'NumberFormat',
  'jsonDecode',
  'jsonEncode',
  'Symbol',
  'MethodChannel',
  'EventChannel',
  'BasicMessageChannel',
  'Exception',
  'StateError',
  'ArgumentError',
  'UnimplementedError',
  'UnsupportedError',
  'FormatException',
  'AssertionError',
  'FlutterError',
  'Intl',
  'message',
  'getString',
  'setString',
  'getBool',
  'setBool',
  'getInt',
  'setInt',
  'read',
  'write',
  'delete',
  'containsKey',
  'logEvent',
  'replaceAll',
  'replaceFirst',
  'split',
  'contains',
  'startsWith',
  'endsWith',
  'indexOf',
  'lastIndexOf',
  'padLeft',
  'padRight',
  'join',
  'get',
  'setUserProperty',
  'setCustomKey',
  'recordError',
  'addBreadcrumb',
};

/// Classes whose strings are diagnostics, not UI: loggers and the like.
const _defaultIgnoredClasses = [r'Logger$', r'Logging', r'Log$', r'Tracker$'];

/// Named arguments that carry identifiers rather than text.
const _defaultIgnoredNamedArgs = {
  'debugLabel',
  'restorationId',
  'restorationScopeId',
  'heroTag',
  'package',
  'fontFamily',
  'semanticsIdentifier',
  'key',
  'name',
  'routeName',
  'initialRoute',
  'path',
  'locale',
};

/// Inline suppressions.
///
/// `// l10n_health: ignore` on a line, or alone on the line above, silences
/// every finding on that line; `// l10n_health: ignore hardcoded_string`
/// silences one check. `// l10n_health: ignore-file` anywhere silences the
/// whole file. Anything after the check ids is free text for the reason.
class SuppressionIndex {
  final _lines = <String, Map<int, Set<String>?>>{};
  final _files = <String>{};

  static final _pattern = RegExp(
    r'//\s*l10n_health:\s*(ignore-file|ignore)\b([ \t]+[a-z_, \t]+)?',
  );

  void index(String file, String source) {
    if (!source.contains('l10n_health:')) return;
    final lines = source.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final match = _pattern.firstMatch(lines[i]);
      if (match == null) continue;
      if (match.group(1) == 'ignore-file') {
        _files.add(file);
        continue;
      }
      final ids =
          match
              .group(2)
              ?.split(RegExp(r'[\s,]+'))
              .where((s) => s.isNotEmpty && s.contains('_'))
              .toSet();
      final checks = (ids == null || ids.isEmpty) ? null : ids;
      final codeBefore = lines[i].substring(0, match.start).trim();
      // A comment alone on its line covers the next line; a trailing
      // comment covers its own.
      final target = codeBefore.isEmpty ? i + 2 : i + 1;
      final map = _lines.putIfAbsent(file, () => {});
      if (map.containsKey(target) && map[target] == null) continue;
      map[target] = checks == null ? null : {...?map[target], ...checks};
    }
  }

  bool isSuppressed(String file, int line, String check) {
    if (_files.contains(file)) return true;
    final map = _lines[file];
    if (map == null || !map.containsKey(line)) return false;
    final checks = map[line];
    return checks == null || checks.contains(check);
  }

  /// Folds another index (from a worker) into this one.
  void merge(SuppressionIndex other) {
    _files.addAll(other._files);
    other._lines.forEach((file, lines) => _lines[file] = lines);
  }
}
