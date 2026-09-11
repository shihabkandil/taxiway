import 'pipeline.dart';
import 'run_manifest.dart';

/// Runs one step and reports how it went.
///
/// A function rather than a dependency so this layer never reaches the CLI:
/// `build` and `release` are shipway's own commands, and the CLI is what knows
/// how to invoke them.
typedef StepInvoker = Future<int> Function(PipelineStep step);

/// What the runner has to say while it works.
abstract class PipelineReporter {
  void stageStarting(PipelineStage stage, int index, int total);
  void stepStarting(PipelineStep step);
  void stepFinished(StepRecord record);
  void stepSkipped(PipelineStep step, String why);
}

class PipelineOutcome {
  const PipelineOutcome({required this.manifest, required this.exitCode});

  final RunManifest manifest;

  /// The first failing step's code, or 0.
  final int exitCode;

  bool get succeeded => exitCode == 0;
}

/// Executes a [Pipeline].
///
/// Sequential by default; a parallel stage runs its steps together and waits
/// for all of them. A failure stops the pipeline — there is no
/// continue-on-error, because a pipeline that carries on past a failure is a
/// pipeline whose result means nothing.
class PipelineRunner {
  const PipelineRunner({
    required this.invoke,
    required this.reporter,
    this.completed = const <String>{},
  });

  final StepInvoker invoke;
  final PipelineReporter reporter;

  /// Step keys an earlier run finished, from the manifest. Skipped on resume.
  final Set<String> completed;

  Future<PipelineOutcome> run(Pipeline pipeline, {DateTime? now}) async {
    final manifest = RunManifest(
      pipeline: pipeline.name,
      startedAt: now ?? DateTime.now(),
    );

    var failure = 0;

    for (var index = 0; index < pipeline.stages.length; index++) {
      final stage = pipeline.stages[index];
      reporter.stageStarting(stage, index, pipeline.stages.length);

      final records = failure == 0
          ? await _runStage(stage)
          : <StepRecord>[
              // Everything after a failure is reported rather than silently
              // absent: "what did not run" is part of what happened.
              for (final step in stage.steps)
                StepRecord(
                  key: step.key,
                  label: step.label,
                  status: StepStatus.notRun,
                ),
            ];

      for (final record in records) {
        manifest.record(record);
        if (record.status == StepStatus.failed && failure == 0) {
          failure = record.exitCode ?? 1;
        }
      }
    }

    return PipelineOutcome(manifest: manifest, exitCode: failure);
  }

  Future<List<StepRecord>> _runStage(PipelineStage stage) async {
    if (!stage.isParallel) {
      final records = <StepRecord>[];
      for (final step in stage.steps) {
        final record = await _runStep(step);
        records.add(record);
        // Within a sequential stage, stop at the first failure for the same
        // reason the pipeline does.
        if (record.status == StepStatus.failed) break;
      }
      // Anything the break skipped is still reported.
      for (final step in stage.steps.skip(records.length)) {
        records.add(
          StepRecord(
            key: step.key,
            label: step.label,
            status: StepStatus.notRun,
          ),
        );
      }
      return records;
    }

    // A failure lets the others finish rather than cancelling them. Killing a
    // half-finished upload is worse than waiting for it, and a cancelled build
    // leaves a partial artifact the next run may pick up.
    return Future.wait<StepRecord>(stage.steps.map(_runStep));
  }

  Future<StepRecord> _runStep(PipelineStep step) async {
    if (completed.contains(step.key)) {
      reporter.stepSkipped(step, 'already done in the last run');
      return StepRecord(
        key: step.key,
        label: step.label,
        status: StepStatus.skipped,
      );
    }

    reporter.stepStarting(step);
    final started = DateTime.now();

    int code;
    try {
      code = await invoke(step);
    } on Object catch (error) {
      // A step that threw is a failed step, not a crashed pipeline: the
      // manifest still has to be written, or `--resume` has nothing to read.
      code = 70;
      reporter.stepSkipped(step, 'threw: $error');
    }

    final record = StepRecord(
      key: step.key,
      label: step.label,
      status: code == 0 ? StepStatus.succeeded : StepStatus.failed,
      exitCode: code,
      duration: DateTime.now().difference(started),
    );
    reporter.stepFinished(record);
    return record;
  }
}
