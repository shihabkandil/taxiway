/// Something a reader could not determine, recorded rather than guessed.
///
/// A reader that silently guesses wrong is worse than one that admits
/// ignorance, because the guess lands in `shipway.yaml` and is then written
/// back to disk as if it were fact. Uncertainty is therefore part of the model,
/// not an error: import surfaces every one of these, and `--deep` may resolve
/// some of them.
class Uncertainty implements Comparable<Uncertainty> {
  const Uncertainty({
    required this.field,
    required this.reason,
    required this.remedy,
    this.source,
    this.severity = UncertaintySeverity.unresolved,
  });

  /// Dotted path of what could not be read, e.g.
  /// `android.flavors.dev.applicationId`.
  final String field;

  /// Why it could not be read, in the reader's own terms.
  final String reason;

  /// The single next action that would resolve it.
  final String remedy;

  /// File the reader was looking at, relative to the project root.
  final String? source;

  final UncertaintySeverity severity;

  /// True when `shipway import --deep` is likely to resolve this.
  bool get deepMayResolve => remedy.contains('--deep');

  @override
  int compareTo(Uncertainty other) {
    final bySeverity = other.severity.index.compareTo(severity.index);
    if (bySeverity != 0) return bySeverity;
    return field.compareTo(other.field);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'field': field,
    'reason': reason,
    'remedy': remedy,
    'severity': severity.name,
    if (source != null) 'source': source,
  };

  @override
  String toString() => '$field: $reason';
}

enum UncertaintySeverity {
  /// Worth knowing, but shipway can proceed.
  informational,

  /// A value is missing and shipway will not invent one.
  unresolved,

  /// What is on disk contradicts what the platform requires.
  ///
  /// Distinct from [unresolved] because these are the findings a user most
  /// wants at import time — they are bugs in their project, not gaps in ours.
  defect,
}

/// Collects uncertainties while a reader runs.
///
/// Mutable by design and never exposed on the finished model; readers build one
/// and hand its contents over as an immutable list.
class UncertaintyLog {
  final List<Uncertainty> _entries = <Uncertainty>[];

  void add(Uncertainty uncertainty) => _entries.add(uncertainty);

  /// Records a value that is present but not a literal — a variable, an `ext`
  /// property, a string interpolation — which the fast Gradle parser cannot
  /// resolve on its own.
  void nonLiteral({
    required String field,
    required String expression,
    String? source,
  }) => add(
    Uncertainty(
      field: field,
      reason: 'is set from `$expression`, which is not a literal value.',
      remedy:
          'Re-run with `--deep` to ask Gradle for the resolved value, '
          'or set this field manually in shipway.yaml.',
      source: source,
    ),
  );

  /// Records a project that violates a platform convention shipway relies on.
  void defect({
    required String field,
    required String reason,
    required String remedy,
    String? source,
  }) => add(
    Uncertainty(
      field: field,
      reason: reason,
      remedy: remedy,
      source: source,
      severity: UncertaintySeverity.defect,
    ),
  );

  void note({
    required String field,
    required String reason,
    required String remedy,
    String? source,
  }) => add(
    Uncertainty(
      field: field,
      reason: reason,
      remedy: remedy,
      source: source,
      severity: UncertaintySeverity.informational,
    ),
  );

  void addAll(Iterable<Uncertainty> entries) => _entries.addAll(entries);

  bool get isEmpty => _entries.isEmpty;

  int get length => _entries.length;

  /// Sorted most-severe first, then by field, so reports are stable.
  List<Uncertainty> build() =>
      List<Uncertainty>.unmodifiable(_entries.toList()..sort());
}
