import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'redactor.dart';

/// The outcome of one external command, with output already redacted.
class ProcessResultLite {
  const ProcessResultLite({
    required this.executable,
    required this.arguments,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final String executable;
  final List<String> arguments;
  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  /// True when the executable itself could not be found or run.
  ///
  /// Distinct from "ran and failed", which is the difference between "install
  /// this tool" and "this tool disagreed with you".
  bool get notFound => exitCode == exitCodeNotFound;

  /// Conventional shell code for "command not found", reused so a missing
  /// binary is an ordinary result rather than an exception every caller catches.
  static const int exitCodeNotFound = 127;

  /// stdout and stderr interleaved, for callers that just want "the output".
  /// Several tools (notably `java -version`) report to stderr.
  String get output {
    if (stdout.isEmpty) return stderr;
    if (stderr.isEmpty) return stdout;
    return '$stdout\n$stderr';
  }

  /// A copy-pasteable rendering of the command, for logs and errors.
  String get commandLine => ([executable, ...arguments]).map(_quote).join(' ');

  static String _quote(String part) => part.contains(' ') ? "'$part'" : part;

  @override
  String toString() => '$commandLine -> $exitCode';
}

/// The single door to the outside world.
///
/// Nothing in `inspect/` or `generators/` may spawn a process directly; going
/// through one interface is what lets the whole CLI be tested without Gradle,
/// Ruby, a keychain, or Apple credentials.
abstract class ProcessRunner {
  /// Runs [executable] to completion and captures its output.
  ///
  /// [stdin] is written to the process and the pipe is then closed. Used for
  /// payloads too large to pass as arguments — the Xcode bridge's configure
  /// request grows with the number of flavors.
  Future<ProcessResultLite> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    String? stdin,
  });

  /// Runs [executable], emitting output line by line as it arrives.
  ///
  /// The exit code is delivered by [ProcessExitException] when non-zero, so a
  /// caller consuming the stream cannot accidentally ignore a failure.
  Stream<String> stream(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  });
}

/// Thrown from [ProcessRunner.stream] when the command exits non-zero.
class ProcessExitException implements Exception {
  ProcessExitException(this.commandLine, this.exitCode);

  final String commandLine;
  final int exitCode;

  @override
  String toString() => '`$commandLine` exited with $exitCode';
}

/// The real implementation, on `dart:io` [Process.start].
///
/// `Process.start` rather than `Process.run` even for [run]: it is the same
/// call path as [stream], so interleaving and exit-code handling behave
/// identically whether or not the caller is watching.
class SystemProcessRunner implements ProcessRunner {
  SystemProcessRunner({required this.redactor});

  final Redactor redactor;

  @override
  Future<ProcessResultLite> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    String? stdin,
  }) async {
    final Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
    } on ProcessException catch (e) {
      return ProcessResultLite(
        executable: executable,
        arguments: arguments,
        exitCode: ProcessResultLite.exitCodeNotFound,
        stdout: '',
        stderr: redactor.redact(e.message),
      );
    }

    if (stdin != null) {
      process.stdin.write(stdin);
      unawaited(process.stdin.close());
    }

    final stdoutFuture = _collect(process.stdout);
    final stderrFuture = _collect(process.stderr);
    final exit = await process.exitCode;

    return ProcessResultLite(
      executable: executable,
      arguments: arguments,
      exitCode: exit,
      stdout: redactor.redact(await stdoutFuture).trim(),
      stderr: redactor.redact(await stderrFuture).trim(),
    );
  }

  @override
  Stream<String> stream(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async* {
    final Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
    } on ProcessException {
      throw ProcessExitException(
        ([executable, ...arguments]).join(' '),
        ProcessResultLite.exitCodeNotFound,
      );
    }

    final merged = _merge([
      process.stdout,
      process.stderr,
    ]).transform(utf8.decoder);

    // Redact before splitting into lines: a secret wrapped across a line break
    // is still a secret, and the transformer needs whole-buffer visibility.
    yield* redactor.redactStream(merged).transform(const LineSplitter());

    final exit = await process.exitCode;
    if (exit != 0) {
      throw ProcessExitException(([executable, ...arguments]).join(' '), exit);
    }
  }

  Future<String> _collect(Stream<List<int>> stream) =>
      stream.transform(utf8.decoder).join();

  /// Interleaves stdout and stderr in arrival order, so streamed output reads
  /// the way it would in a terminal rather than as two separate blocks.
  static Stream<List<int>> _merge(List<Stream<List<int>>> streams) {
    final controller = StreamController<List<int>>();
    var open = streams.length;
    for (final stream in streams) {
      stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: () {
          if (--open == 0) unawaited(controller.close());
        },
      );
    }
    return controller.stream;
  }
}
