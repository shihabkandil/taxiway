import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// What became of one step.
enum StepStatus {
  succeeded,
  failed,

  /// Skipped by `--resume` because an earlier run had already done it.
  skipped,

  /// Reached, but the pipeline stopped before it ran.
  notRun;

  bool get isSuccess => this == StepStatus.succeeded;
}

class StepRecord {
  const StepRecord({
    required this.key,
    required this.label,
    required this.status,
    this.exitCode,
    this.duration,
  });

  final String key;
  final String label;
  final StepStatus status;
  final int? exitCode;
  final Duration? duration;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'key': key,
    'label': label,
    'status': status.name,
    if (exitCode != null) 'exitCode': exitCode,
    if (duration != null) 'ms': duration!.inMilliseconds,
  };

  static StepRecord fromJson(Map<dynamic, dynamic> json) => StepRecord(
    key: json['key'].toString(),
    label: json['label']?.toString() ?? json['key'].toString(),
    status: StepStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => StepStatus.notRun,
    ),
    exitCode: json['exitCode'] as int?,
    duration: json['ms'] == null
        ? null
        : Duration(milliseconds: json['ms'] as int),
  );
}

/// The record a run leaves behind.
///
/// Two jobs: it is what `--resume` reads to know which steps are already done,
/// and it is what answers "what actually happened" once the terminal is gone.
/// Both matter more than they sound — a release that half-succeeded is exactly
/// the situation where nobody can remember the order things ran in.
///
/// No secret is ever written here. The steps record what they were, not what
/// they were given.
class RunManifest {
  RunManifest({
    required this.pipeline,
    required this.startedAt,
    List<StepRecord>? steps,
  }) : steps = steps ?? <StepRecord>[];

  final String pipeline;
  final DateTime startedAt;
  final List<StepRecord> steps;

  static const String directory = '.shipway/runs';

  /// One file per pipeline, overwritten each run.
  ///
  /// Not one per run: `--resume` means "the last attempt at this pipeline",
  /// and a directory that grows forever is something a developer eventually
  /// deletes by hand, taking the answer with it.
  static String pathFor(String root, String pipeline) =>
      p.join(root, directory, '$pipeline.json');

  bool get succeeded => steps.every((s) => s.status != StepStatus.failed);

  /// The step that stopped the last run, if any.
  StepRecord? get firstFailure {
    for (final step in steps) {
      if (step.status == StepStatus.failed) return step;
    }
    return null;
  }

  /// Keys that completed, so a resume can skip them.
  Set<String> get completed => <String>{
    for (final step in steps)
      if (step.status.isSuccess) step.key,
  };

  void record(StepRecord step) {
    steps.removeWhere((s) => s.key == step.key);
    steps.add(step);
  }

  Future<void> save(String root) async {
    final file = File(pathFor(root, pipeline));
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'pipeline': pipeline,
        'startedAt': startedAt.toIso8601String(),
        'steps': steps.map((s) => s.toJson()).toList(),
      }),
    );
  }

  /// Reads the last run of [pipeline], or null when there is none.
  ///
  /// A manifest that cannot be parsed is treated as absent rather than fatal:
  /// it is a record of a past run, and refusing to start because an old one is
  /// malformed would be the file holding the project hostage.
  static Future<RunManifest?> load(String root, String pipeline) async {
    final file = File(pathFor(root, pipeline));
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return RunManifest(
        pipeline: decoded['pipeline']?.toString() ?? pipeline,
        startedAt:
            DateTime.tryParse(decoded['startedAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        steps: <StepRecord>[
          for (final step
              in (decoded['steps'] as List<dynamic>? ?? <dynamic>[]))
            if (step is Map) StepRecord.fromJson(step),
        ],
      );
    } on FormatException {
      return null;
    }
  }
}
