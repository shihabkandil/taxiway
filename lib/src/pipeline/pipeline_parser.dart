import 'pipeline.dart';

/// A pipeline that could not be read.
class PipelineException implements Exception {
  const PipelineException(this.message, {this.hint});

  final String message;
  final String? hint;

  @override
  String toString() => hint == null ? message : '$message\n$hint';
}

/// Reads the `pipelines:` section.
///
/// Hand-written rather than generated, because the shape is a union — a step is
/// a bare string, or a single-key map, or a `parallel` block holding more of
/// them — and every way of getting it wrong deserves a message naming the
/// pipeline and the step rather than a schema error naming a type.
abstract final class PipelineParser {
  static const List<String> stepNames = <String>[
    'analyze',
    'test',
    'build',
    'release',
    'run',
    'parallel',
  ];

  /// Parses every pipeline, or throws [PipelineException].
  static Map<String, Pipeline> parseAll(Object? section) {
    if (section == null) return const <String, Pipeline>{};
    if (section is! Map) {
      throw const PipelineException(
        '`pipelines` must be a map of name to steps.',
        hint: 'pipelines:\n  beta:\n    - analyze\n    - test',
      );
    }

    final pipelines = <String, Pipeline>{};
    for (final entry in section.entries) {
      final name = entry.key.toString();
      pipelines[name] = parse(name, entry.value);
    }
    return pipelines;
  }

  static Pipeline parse(String name, Object? value) {
    if (value is! List || value.isEmpty) {
      throw PipelineException(
        'Pipeline `$name` has no steps.',
        hint: 'It should be a list: `- analyze`, `- test`, and so on.',
      );
    }

    final stages = <PipelineStage>[for (final raw in value) _stage(name, raw)];
    return Pipeline(name: name, stages: stages);
  }

  static PipelineStage _stage(String pipeline, Object? raw) {
    // A `parallel:` block is the only thing that is a stage rather than a step.
    if (raw is Map && raw.length == 1 && raw.keys.first == 'parallel') {
      final inner = raw.values.first;
      if (inner is! List || inner.isEmpty) {
        throw PipelineException(
          'In pipeline `$pipeline`, `parallel` has no steps.',
          hint: 'parallel:\n  - release: { flavor: prod, target: testflight }',
        );
      }
      final steps = <PipelineStep>[
        for (final entry in inner) _step(pipeline, entry),
      ];
      // Nesting would make execution order something a reader has to work out.
      return PipelineStage(steps, parallel: true);
    }
    return PipelineStage.of(_step(pipeline, raw));
  }

  static PipelineStep _step(String pipeline, Object? raw) {
    if (raw is String) return _bare(pipeline, raw);

    if (raw is Map && raw.length == 1) {
      final key = raw.keys.first.toString();
      final options = raw.values.first;
      return switch (key) {
        'test' => PipelineTest(
          coverage: _boolOption(pipeline, key, options, 'coverage') ?? false,
        ),
        'build' => _build(pipeline, options),
        'release' => _release(pipeline, options),
        'run' => _run(pipeline, options),
        'parallel' => throw PipelineException(
          'In pipeline `$pipeline`, `parallel` cannot be nested inside '
          '`parallel`.',
          hint: 'Flatten it: one parallel block per position.',
        ),
        _ => throw _unknownStep(pipeline, key),
      };
    }

    throw PipelineException(
      'In pipeline `$pipeline`, a step must be a name or a single-key map.',
      hint: 'Like `- analyze`, or `- release: { flavor: prod, target: play }`.',
    );
  }

  static PipelineStep _bare(String pipeline, String name) => switch (name) {
    'analyze' => const PipelineAnalyze(),
    'test' => const PipelineTest(),
    'build' || 'release' || 'run' => throw PipelineException(
      'In pipeline `$pipeline`, `$name` needs options.',
      hint: name == 'run'
          ? '- run: flutter pub get'
          : '- $name: { flavor: prod'
                '${name == 'release' ? ', target: testflight' : ', platform: ios'} }',
    ),
    _ => throw _unknownStep(pipeline, name),
  };

  static PipelineStep _build(String pipeline, Object? options) {
    final map = _requireMap(pipeline, 'build', options);
    return PipelineBuild(
      platform: _requireString(pipeline, 'build', map, 'platform'),
      flavor: _requireString(pipeline, 'build', map, 'flavor'),
      artifact: map['artifact']?.toString(),
    );
  }

  static PipelineStep _release(String pipeline, Object? options) {
    final map = _requireMap(pipeline, 'release', options);
    final target = _requireString(pipeline, 'release', map, 'target');
    // Derived rather than asked for: a target belongs to exactly one platform,
    // and making somebody write both invites them to disagree.
    final platform = switch (target) {
      'testflight' || 'appstore' => 'ios',
      'play' || 'firebase' => 'android',
      _ => throw PipelineException(
        'In pipeline `$pipeline`, `$target` is not a release target.',
        hint: 'Expected testflight, appstore, play or firebase.',
      ),
    };

    return PipelineRelease(
      platform: platform,
      flavor: _requireString(pipeline, 'release', map, 'flavor'),
      target: target,
      track: map['track']?.toString(),
      rollout: map['rollout']?.toString(),
    );
  }

  static PipelineStep _run(String pipeline, Object? options) {
    if (options is String) return PipelineRun(command: options);
    final map = _requireMap(pipeline, 'run', options);
    return PipelineRun(
      command: _requireString(pipeline, 'run', map, 'command'),
      name: map['name']?.toString(),
    );
  }

  static Map<dynamic, dynamic> _requireMap(
    String pipeline,
    String step,
    Object? options,
  ) {
    if (options is Map) return options;
    throw PipelineException(
      'In pipeline `$pipeline`, `$step` needs options.',
      hint: '- $step: { flavor: prod, ... }',
    );
  }

  static String _requireString(
    String pipeline,
    String step,
    Map<dynamic, dynamic> options,
    String key,
  ) {
    final value = options[key];
    if (value == null || value.toString().trim().isEmpty) {
      throw PipelineException(
        'In pipeline `$pipeline`, step `$step` is missing `$key`.',
        hint: 'Add it: `- $step: { $key: ... }`.',
      );
    }
    return value.toString();
  }

  static bool? _boolOption(
    String pipeline,
    String step,
    Object? options,
    String key,
  ) {
    if (options is! Map) return null;
    final value = options[key];
    if (value == null) return null;
    if (value is bool) return value;
    throw PipelineException(
      'In pipeline `$pipeline`, `$step.$key` must be true or false.',
    );
  }

  static PipelineException _unknownStep(String pipeline, String name) =>
      PipelineException(
        'In pipeline `$pipeline`, `$name` is not a step taxiway knows.',
        hint: 'Expected one of: ${stepNames.join(', ')}.',
      );
}
