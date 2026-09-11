/// How two models differ at one place.
enum ChangeKind {
  /// Present on disk, absent from the config.
  onlyInProject,

  /// Present in the config, absent from the project.
  onlyInConfig,

  /// Present in both, with different values.
  different,
}

/// One semantic difference.
///
/// Semantic, not textual: "your `dev` flavor sets `versionNameSuffix`,
/// shipway's would not" is actionable in a way a hash mismatch never is, and it
/// is the only basis on which `adopt` can be safe.
class ModelChange {
  const ModelChange({
    required this.path,
    required this.kind,
    this.expected,
    this.actual,
    this.note,
  });

  /// Dotted path, e.g. `android.flavors.dev.applicationIdSuffix`.
  final String path;

  final ChangeKind kind;

  /// What the config says.
  final String? expected;

  /// What the project says.
  final String? actual;

  /// Extra context, where the path alone does not explain the change.
  final String? note;

  String describe() => switch (kind) {
    ChangeKind.onlyInProject =>
      '$path exists in the project but not in shipway.yaml'
          '${actual == null ? '' : ' ($actual)'}',
    ChangeKind.onlyInConfig =>
      '$path is in shipway.yaml but not in the project'
          '${expected == null ? '' : ' ($expected)'}',
    ChangeKind.different =>
      '$path: shipway.yaml says ${_show(expected)}, project has '
          '${_show(actual)}',
  };

  static String _show(String? value) =>
      value == null || value.isEmpty ? '(unset)' : '`$value`';

  @override
  String toString() => describe();
}

/// The result of comparing two [ProjectModel]s.
class ModelDiff {
  const ModelDiff(this.changes);

  final List<ModelChange> changes;

  bool get isEmpty => changes.isEmpty;

  bool get isNotEmpty => changes.isNotEmpty;

  int get length => changes.length;

  Iterable<ModelChange> ofKind(ChangeKind kind) =>
      changes.where((c) => c.kind == kind);

  /// Changes whose path starts with [prefix], for per-section rendering.
  Iterable<ModelChange> under(String prefix) =>
      changes.where((c) => c.path == prefix || c.path.startsWith('$prefix.'));

  List<Map<String, dynamic>> toJson() => changes
      .map(
        (c) => <String, dynamic>{
          'path': c.path,
          'kind': c.kind.name,
          if (c.expected != null) 'expected': c.expected,
          if (c.actual != null) 'actual': c.actual,
          if (c.note != null) 'note': c.note,
        },
      )
      .toList();
}

/// Accumulates changes while comparing.
class DiffBuilder {
  final List<ModelChange> _changes = <ModelChange>[];

  /// Compares one optional value, ignoring the case where both are absent.
  void value(String path, String? expected, String? actual, {String? note}) {
    if (expected == actual) return;
    if (expected == null) {
      _changes.add(
        ModelChange(
          path: path,
          kind: ChangeKind.onlyInProject,
          actual: actual,
          note: note,
        ),
      );
      return;
    }
    if (actual == null) {
      _changes.add(
        ModelChange(
          path: path,
          kind: ChangeKind.onlyInConfig,
          expected: expected,
          note: note,
        ),
      );
      return;
    }
    _changes.add(
      ModelChange(
        path: path,
        kind: ChangeKind.different,
        expected: expected,
        actual: actual,
        note: note,
      ),
    );
  }

  /// Compares two sets of names, reporting each side's extras.
  void names(
    String path,
    Set<String> expected,
    Set<String> actual, {
    String? note,
  }) {
    for (final missing in expected.difference(actual).toList()..sort()) {
      _changes.add(
        ModelChange(
          path: '$path.$missing',
          kind: ChangeKind.onlyInConfig,
          expected: missing,
          note: note,
        ),
      );
    }
    for (final extra in actual.difference(expected).toList()..sort()) {
      _changes.add(
        ModelChange(
          path: '$path.$extra',
          kind: ChangeKind.onlyInProject,
          actual: extra,
          note: note,
        ),
      );
    }
  }

  void add(ModelChange change) => _changes.add(change);

  ModelDiff build() => ModelDiff(
    List<ModelChange>.unmodifiable(
      _changes..sort((a, b) => a.path.compareTo(b.path)),
    ),
  );
}
