import 'package:taxiway/src/pipeline/pipeline.dart';
import 'package:taxiway/src/pipeline/pipeline_runner.dart';
import 'package:taxiway/src/pipeline/run_manifest.dart';
import 'package:test/test.dart';

/// Records what it was asked to do, and answers with whatever was arranged.
class _Invoker {
  _Invoker({
    this.codes = const <String, int>{},
    this.delays = const <String, int>{},
  });

  final Map<String, int> codes;
  final Map<String, int> delays;
  final List<String> started = <String>[];
  final List<String> finished = <String>[];

  Future<int> call(PipelineStep step) async {
    started.add(step.key);
    final delay = delays[step.key];
    if (delay != null) {
      await Future<void>.delayed(Duration(milliseconds: delay));
    }
    finished.add(step.key);
    return codes[step.key] ?? 0;
  }
}

class _SilentReporter implements PipelineReporter {
  final List<String> skipped = <String>[];

  @override
  void stageStarting(PipelineStage stage, int index, int total) {}

  @override
  void stepStarting(PipelineStep step) {}

  @override
  void stepFinished(StepRecord record) {}

  @override
  void stepSkipped(PipelineStep step, String why) => skipped.add(step.key);
}

const analyze = PipelineAnalyze();
const test_ = PipelineTest();
const iosRelease = PipelineRelease(
  platform: 'ios',
  flavor: 'prod',
  target: 'testflight',
);
const androidRelease = PipelineRelease(
  platform: 'android',
  flavor: 'prod',
  target: 'play',
);

Pipeline sequential() => Pipeline(
  name: 'beta',
  stages: <PipelineStage>[
    PipelineStage.of(analyze),
    PipelineStage.of(test_),
    PipelineStage.of(iosRelease),
  ],
);

Pipeline withParallel() => Pipeline(
  name: 'beta',
  stages: <PipelineStage>[
    PipelineStage.of(analyze),
    PipelineStage(<PipelineStep>[iosRelease, androidRelease], parallel: true),
  ],
);

void main() {
  late _SilentReporter reporter;

  setUp(() => reporter = _SilentReporter());

  Future<PipelineOutcome> run(
    Pipeline pipeline,
    _Invoker invoker, {
    Set<String> completed = const <String>{},
  }) => PipelineRunner(
    invoke: invoker.call,
    reporter: reporter,
    completed: completed,
  ).run(pipeline);

  group('the happy path', () {
    test('runs every step in order', () async {
      final invoker = _Invoker();
      final outcome = await run(sequential(), invoker);

      expect(outcome.succeeded, isTrue);
      expect(outcome.exitCode, 0);
      expect(invoker.started, <String>[analyze.key, test_.key, iosRelease.key]);
    });

    test('the manifest records every step', () async {
      final outcome = await run(sequential(), _Invoker());
      expect(outcome.manifest.steps, hasLength(3));
      expect(
        outcome.manifest.steps.every((s) => s.status == StepStatus.succeeded),
        isTrue,
      );
      expect(outcome.manifest.steps.first.duration, isNotNull);
    });
  });

  group('failure', () {
    test('stops the pipeline', () async {
      // A pipeline that carries on past a failure is one whose result means
      // nothing.
      final invoker = _Invoker(codes: <String, int>{test_.key: 2});
      final outcome = await run(sequential(), invoker);

      expect(outcome.exitCode, 2);
      expect(invoker.started, isNot(contains(iosRelease.key)));
    });

    test('what did not run is recorded, not silently absent', () async {
      final outcome = await run(
        sequential(),
        _Invoker(codes: <String, int>{test_.key: 2}),
      );

      final notRun = outcome.manifest.steps.where(
        (s) => s.status == StepStatus.notRun,
      );
      expect(notRun.map((s) => s.key), <String>[iosRelease.key]);
    });

    test('the exit code is the first failure, not the last', () async {
      // So a caller can tell a bad config from a bad machine using the codes
      // taxiway already defines.
      final outcome = await run(
        Pipeline(
          name: 'p',
          stages: <PipelineStage>[
            PipelineStage(<PipelineStep>[
              iosRelease,
              androidRelease,
            ], parallel: true),
          ],
        ),
        _Invoker(
          codes: <String, int>{iosRelease.key: 2, androidRelease.key: 70},
        ),
      );
      expect(outcome.exitCode, 2);
    });

    test(
      'a step that throws is a failed step, not a crashed pipeline',
      () async {
        // The manifest still has to be written, or --resume has nothing to read.
        final outcome = await PipelineRunner(
          invoke: (step) async => throw StateError('boom'),
          reporter: reporter,
        ).run(sequential());

        expect(outcome.succeeded, isFalse);
        expect(outcome.manifest.firstFailure, isNotNull);
      },
    );
  });

  group('parallel stages', () {
    test('start together', () async {
      final invoker = _Invoker(
        delays: <String, int>{iosRelease.key: 60, androidRelease.key: 10},
      );
      await run(withParallel(), invoker);

      // The slower one starts before the faster one finishes, which would be
      // impossible if the stage ran in sequence.
      expect(invoker.started, <String>[
        analyze.key,
        iosRelease.key,
        androidRelease.key,
      ]);
      expect(invoker.finished.last, iosRelease.key);
    });

    test('a failure lets the others finish', () async {
      // Killing a half-finished upload is worse than waiting for it, and a
      // cancelled build leaves a partial artifact the next run may pick up.
      final invoker = _Invoker(
        codes: <String, int>{iosRelease.key: 1},
        delays: <String, int>{androidRelease.key: 30},
      );
      final outcome = await run(withParallel(), invoker);

      expect(invoker.finished, contains(androidRelease.key));
      expect(outcome.succeeded, isFalse);
    });
  });

  group('resume', () {
    test('skips what an earlier run finished', () async {
      final invoker = _Invoker();
      final outcome = await run(
        sequential(),
        invoker,
        completed: <String>{analyze.key, test_.key},
      );

      expect(invoker.started, <String>[iosRelease.key]);
      expect(reporter.skipped, <String>[analyze.key, test_.key]);
      expect(outcome.succeeded, isTrue);
    });

    test('a skipped step is recorded as skipped, not succeeded', () async {
      // They are different facts, and a manifest that conflated them would
      // make the next resume skip something that never ran.
      final outcome = await run(
        sequential(),
        _Invoker(),
        completed: <String>{analyze.key},
      );

      final analyzeRecord = outcome.manifest.steps.firstWhere(
        (s) => s.key == analyze.key,
      );
      expect(analyzeRecord.status, StepStatus.skipped);
      expect(outcome.manifest.completed, isNot(contains(analyze.key)));
    });
  });
}
