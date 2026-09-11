import 'package:shipway/src/pipeline/pipeline.dart';
import 'package:shipway/src/pipeline/pipeline_parser.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

Pipeline parse(String yaml) {
  final section = loadYaml('pipelines:\n$yaml') as YamlMap;
  final pipelines = PipelineParser.parseAll(section['pipelines']);
  return pipelines.values.single;
}

Matcher throwsPipeline(Object matcher) => throwsA(
  isA<PipelineException>().having((e) => e.toString(), 'message', matcher),
);

void main() {
  group('reading steps', () {
    test('bare names', () {
      final pipeline = parse('  beta:\n    - analyze\n    - test\n');
      expect(pipeline.name, 'beta');
      expect(pipeline.steps, <Matcher>[
        isA<PipelineAnalyze>(),
        isA<PipelineTest>(),
      ]);
    });

    test('a release derives its platform from the target', () {
      // A target belongs to exactly one platform, and making somebody write
      // both invites them to disagree.
      final pipeline = parse(
        '  ship:\n'
        '    - release: { flavor: prod, target: testflight }\n'
        '    - release: { flavor: prod, target: play }\n',
      );
      final steps = pipeline.steps.cast<PipelineRelease>();
      expect(steps[0].platform, 'ios');
      expect(steps[1].platform, 'android');
    });

    test('a build takes its platform explicitly', () {
      final step =
          parse(
                '  b:\n    - build: { platform: ios, flavor: dev }\n',
              ).steps.single
              as PipelineBuild;
      expect(step.platform, 'ios');
      expect(step.flavor, 'dev');
    });

    test('run accepts a bare command or a named one', () {
      expect(
        (parse('  r:\n    - run: flutter pub get\n').steps.single
                as PipelineRun)
            .command,
        'flutter pub get',
      );
      final named =
          parse(
                '  r:\n    - run: { command: make, name: Build docs }\n',
              ).steps.single
              as PipelineRun;
      expect(named.command, 'make');
      expect(named.label, 'Build docs');
    });

    test('test takes coverage', () {
      final step =
          parse('  t:\n    - test: { coverage: true }\n').steps.single
              as PipelineTest;
      expect(step.coverage, isTrue);
    });
  });

  group('parallel', () {
    test('groups its steps into one stage', () {
      final pipeline = parse(
        '  beta:\n'
        '    - analyze\n'
        '    - parallel:\n'
        '        - release: { flavor: prod, target: testflight }\n'
        '        - release: { flavor: prod, target: play }\n',
      );

      expect(pipeline.stages, hasLength(2));
      expect(pipeline.stages[0].isParallel, isFalse);
      expect(pipeline.stages[1].isParallel, isTrue);
      expect(pipeline.stages[1].steps, hasLength(2));
    });

    test('cannot be nested', () {
      // Nesting would make execution order something a reader has to work out.
      expect(
        () => parse(
          '  p:\n'
          '    - parallel:\n'
          '        - parallel:\n'
          '            - analyze\n',
        ),
        throwsPipeline(contains('cannot be nested')),
      );
    });

    test('needs steps', () {
      expect(
        () => parse('  p:\n    - parallel: []\n'),
        throwsPipeline(contains('has no steps')),
      );
    });
  });

  group('what it refuses, and how it says so', () {
    test('an unknown step names the ones that exist', () {
      expect(
        () => parse('  p:\n    - deploy\n'),
        throwsPipeline(allOf(contains('deploy'), contains('analyze'))),
      );
    });

    test('a step that needs options says so, with an example', () {
      expect(
        () => parse('  p:\n    - release\n'),
        throwsPipeline(allOf(contains('needs options'), contains('target'))),
      );
    });

    test('a missing option names the option and the pipeline', () {
      expect(
        () => parse('  beta:\n    - release: { target: play }\n'),
        throwsPipeline(allOf(contains('beta'), contains('flavor'))),
      );
    });

    test('an unknown release target lists the real ones', () {
      expect(
        () => parse('  p:\n    - release: { flavor: x, target: steam }\n'),
        throwsPipeline(allOf(contains('steam'), contains('testflight'))),
      );
    });

    test('an empty pipeline is not a pipeline', () {
      expect(() => parse('  p: []\n'), throwsPipeline(contains('no steps')));
    });
  });

  group('repeatability', () {
    test('is what resume turns on', () {
      expect(const PipelineAnalyze().repeatable, isTrue);
      expect(const PipelineTest().repeatable, isTrue);
      expect(
        const PipelineBuild(platform: 'ios', flavor: 'dev').repeatable,
        isTrue,
      );
      // The upload may have landed before whatever failed afterwards.
      expect(
        const PipelineRelease(
          platform: 'ios',
          flavor: 'dev',
          target: 'testflight',
        ).repeatable,
        isFalse,
      );
      // Unknown, not false: shipway has no idea what the command does.
      expect(const PipelineRun(command: 'make').repeatable, isNull);
    });
  });

  test('a step key survives steps being inserted before it', () {
    // Keys are derived from what a step does, not its position, so a manifest
    // written by one run is still readable after the pipeline is edited.
    final before = parse(
      '  p:\n    - release: { flavor: prod, target: play }\n',
    ).steps.single;
    final after = parse(
      '  p:\n    - analyze\n    - release: { flavor: prod, target: play }\n',
    ).steps.last;
    expect(after.key, before.key);
  });
}
