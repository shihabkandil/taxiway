import 'dart:io';

import '../core/config/taxiway_config.dart';
import '../core/io/process_runner.dart';
import 'tool_version.dart';

/// Outcome of one check.
enum CheckStatus {
  /// Requirement met.
  ok,

  /// Usable, but something will bite later.
  warn,

  /// Cannot ship until this is fixed.
  fail,

  /// Not applicable to this project or machine.
  skip;

  /// Whether an overall run containing this status is still a pass.
  bool get blocks => this == CheckStatus.fail;
}

class CheckResult {
  const CheckResult({
    required this.status,
    required this.detail,
    this.version,
    this.fixHint,
    this.docsUrl,
  });

  /// Everything is fine.
  const CheckResult.ok(this.detail, {this.version})
    : status = CheckStatus.ok,
      fixHint = null,
      docsUrl = null;

  const CheckResult.warn(
    this.detail, {
    this.version,
    this.fixHint,
    this.docsUrl,
  }) : status = CheckStatus.warn;

  const CheckResult.fail(
    this.detail, {
    this.version,
    this.fixHint,
    this.docsUrl,
  }) : status = CheckStatus.fail;

  const CheckResult.skip(this.detail)
    : status = CheckStatus.skip,
      version = null,
      fixHint = null,
      docsUrl = null;

  final CheckStatus status;

  /// What was found, stated as fact.
  final String detail;

  /// The detected version, when there is one.
  final ToolVersion? version;

  /// The single next action that would resolve this.
  final String? fixHint;

  final String? docsUrl;
}

/// What a check may look at.
class DoctorContext {
  const DoctorContext({
    required this.runner,
    required this.projectRoot,
    required this.config,
    required this.now,
  });

  final ProcessRunner runner;

  /// Root of the Flutter project, which may not contain one.
  final String projectRoot;

  /// Null when doctor runs outside a configured project — `doctor` must work
  /// before `init` does, because its whole job is telling you why nothing else
  /// will.
  final TaxiwayConfig? config;

  final DateTime now;

  bool get hasProject =>
      File('$projectRoot/pubspec.yaml').existsSync() &&
      Directory('$projectRoot/android').existsSync();

  bool get hasIos => Directory('$projectRoot/ios').existsSync();
}

/// One environment check.
abstract class Check {
  /// Stable identifier, used as the JSON key and in `--only` filters.
  String get id;

  /// Human-facing name.
  String get title;

  Future<CheckResult> run(DoctorContext context);
}
