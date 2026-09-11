/// What a step does when it runs.
///
/// The set is deliberately small. Anything outside it is a [PipelineRun] —
/// an escape hatch is more honest than a step type per idea somebody might
/// have, and cheaper than being wrong about which ideas matter.
sealed class PipelineStep {
  const PipelineStep();

  /// One line for the plan and the summary table.
  String get label;

  /// Whether running this twice is safe.
  ///
  /// The whole of `--resume` turns on this. `null` means taxiway does not
  /// know, which is a different answer from "no" and is reported differently.
  bool? get repeatable;

  /// A stable key, so a manifest written by one run is readable by the next.
  ///
  /// Derived from what the step *does* rather than its position: inserting a
  /// step at the top of a pipeline should not invalidate the record of every
  /// step after it.
  String get key;
}

/// `flutter analyze`.
class PipelineAnalyze extends PipelineStep {
  const PipelineAnalyze();

  @override
  String get label => 'analyze';

  @override
  bool? get repeatable => true;

  @override
  String get key => 'analyze';
}

/// `flutter test`.
class PipelineTest extends PipelineStep {
  const PipelineTest({this.coverage = false});

  final bool coverage;

  @override
  String get label => 'test${coverage ? ' (coverage)' : ''}';

  @override
  bool? get repeatable => true;

  @override
  String get key => 'test';
}

/// `taxiway build <platform> --flavor <flavor>`.
class PipelineBuild extends PipelineStep {
  const PipelineBuild({
    required this.platform,
    required this.flavor,
    this.artifact,
  });

  final String platform;
  final String flavor;

  /// Android only: `appbundle` or `apk`.
  final String? artifact;

  @override
  String get label => 'build $platform ($flavor)';

  // Rebuilding overwrites the artifact, so nothing is lost by doing it again.
  @override
  bool? get repeatable => true;

  @override
  String get key => 'build:$platform:$flavor';
}

/// `taxiway release <platform> --flavor <flavor> --target <target>`.
class PipelineRelease extends PipelineStep {
  const PipelineRelease({
    required this.platform,
    required this.flavor,
    required this.target,
    this.track,
    this.rollout,
  });

  final String platform;
  final String flavor;
  final String target;
  final String? track;
  final String? rollout;

  @override
  String get label => 'release $flavor → $target';

  /// Never. The upload may have landed before whatever failed afterwards, and
  /// a second one is rejected as a duplicate build number.
  @override
  bool? get repeatable => false;

  @override
  String get key => 'release:$platform:$flavor:$target';
}

/// An arbitrary command.
class PipelineRun extends PipelineStep {
  const PipelineRun({required this.command, this.name});

  final String command;

  /// An optional friendlier name for the summary.
  final String? name;

  @override
  String get label => name ?? command;

  /// Unknown, not false: taxiway has no idea what the command does, and
  /// pretending otherwise in either direction would be a guess about somebody
  /// else's script.
  @override
  bool? get repeatable => null;

  @override
  String get key => 'run:${name ?? command}';
}

/// One position in a pipeline: either a single step, or several to run at once.
///
/// Sequential by default with an explicit parallel block, rather than inferred
/// dependencies. The order in the file is the order of execution, always —
/// a missing edge in a DAG is a race that shows up once in twenty runs.
class PipelineStage {
  const PipelineStage(this.steps, {this.parallel = false});

  /// A stage holding one step, which is what most of a pipeline is.
  PipelineStage.of(PipelineStep step)
    : steps = <PipelineStep>[step],
      parallel = false;

  final List<PipelineStep> steps;

  /// Whether these run together. Meaningless with one step.
  final bool parallel;

  bool get isParallel => parallel && steps.length > 1;
}

/// A named sequence of stages.
class Pipeline {
  const Pipeline({required this.name, required this.stages});

  final String name;
  final List<PipelineStage> stages;

  /// Every step, in execution order.
  List<PipelineStep> get steps => <PipelineStep>[
    for (final stage in stages) ...stage.steps,
  ];

  /// True when any step could upload something.
  bool get ships => steps.any((s) => s is PipelineRelease);
}
