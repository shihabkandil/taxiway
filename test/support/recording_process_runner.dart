import 'package:shipway/src/core/io/process_runner.dart';

/// One captured invocation.
class RecordedInvocation {
  RecordedInvocation({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    required this.environment,
    required this.streamed,
    this.stdin,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String>? environment;
  final bool streamed;

  /// What was written to the process's stdin, if anything.
  final String? stdin;

  String get commandLine => ([executable, ...arguments]).join(' ');

  @override
  String toString() => commandLine;
}

/// A [ProcessRunner] that executes nothing and remembers everything.
///
/// Assertions are about *command construction* — the argv shipway builds for
/// `gradlew`, `ruby`, `bundle exec fastlane`, `security`, `keytool` — which is
/// the part that is ours to get right. Responses are stubbed by matching on the
/// command line, so a test states only the commands it cares about.
class RecordingProcessRunner implements ProcessRunner {
  RecordingProcessRunner({this.defaultResponse});

  /// Every invocation, in order.
  final List<RecordedInvocation> invocations = <RecordedInvocation>[];

  final List<_Stub> _stubs = <_Stub>[];

  /// Returned when no stub matches. Null means "exit 0, no output", which keeps
  /// tests that only assert argv free of stub boilerplate.
  final ProcessResultLite? defaultResponse;

  /// Called before each invocation is answered.
  ///
  /// Lets a test model a side effect a real command would have had — a file
  /// written, a value changed — usually by re-stubbing what a later read
  /// returns. Without it, any code that writes and then verifies its own work
  /// is untestable against this double.
  void Function(RecordedInvocation invocation)? onRun;

  /// Stubs any command whose command line contains [contains].
  ///
  /// Later registrations win, so a test can override a fixture-wide default.
  void stub(
    String contains, {
    int exitCode = 0,
    String stdout = '',
    String stderr = '',
    List<String>? lines,
  }) {
    _stubs.insert(
      0,
      _Stub(
        contains: contains,
        exitCode: exitCode,
        stdout: stdout,
        stderr: stderr,
        lines:
            lines ?? (stdout.isEmpty ? const <String>[] : stdout.split('\n')),
      ),
    );
  }

  /// The command lines seen so far, for whole-sequence assertions.
  List<String> get commandLines =>
      invocations.map((i) => i.commandLine).toList(growable: false);

  /// True if any invocation's command line contains [needle].
  bool ran(String needle) => commandLines.any((c) => c.contains(needle));

  /// The single invocation containing [needle]; fails loudly if absent or
  /// ambiguous, because a silent "no match" makes a green test meaningless.
  RecordedInvocation invocation(String needle) {
    final matches = invocations
        .where((i) => i.commandLine.contains(needle))
        .toList();
    if (matches.isEmpty) {
      throw StateError(
        'No command matched "$needle". Ran:\n  ${commandLines.join('\n  ')}',
      );
    }
    if (matches.length > 1) {
      throw StateError(
        '"$needle" matched ${matches.length} commands:\n'
        '  ${matches.map((m) => m.commandLine).join('\n  ')}',
      );
    }
    return matches.single;
  }

  void clear() {
    invocations.clear();
    _stubs.clear();
  }

  @override
  Future<ProcessResultLite> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    String? stdin,
  }) async {
    _record(
      executable,
      arguments,
      workingDirectory,
      environment,
      false,
      stdin: stdin,
    );
    onRun?.call(invocations.last);
    final stub = _match(executable, arguments);
    return ProcessResultLite(
      executable: executable,
      arguments: arguments,
      exitCode: stub?.exitCode ?? defaultResponse?.exitCode ?? 0,
      stdout: stub?.stdout ?? defaultResponse?.stdout ?? '',
      stderr: stub?.stderr ?? defaultResponse?.stderr ?? '',
    );
  }

  @override
  Stream<String> stream(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async* {
    _record(executable, arguments, workingDirectory, environment, true);
    onRun?.call(invocations.last);
    final stub = _match(executable, arguments);
    for (final line in stub?.lines ?? const <String>[]) {
      yield line;
    }
    final exit = stub?.exitCode ?? 0;
    if (exit != 0) {
      throw ProcessExitException(([executable, ...arguments]).join(' '), exit);
    }
  }

  void _record(
    String executable,
    List<String> arguments,
    String? workingDirectory,
    Map<String, String>? environment,
    bool streamed, {
    String? stdin,
  }) {
    invocations.add(
      RecordedInvocation(
        executable: executable,
        arguments: List<String>.unmodifiable(arguments),
        workingDirectory: workingDirectory,
        environment: environment == null
            ? null
            : Map<String, String>.unmodifiable(environment),
        streamed: streamed,
        stdin: stdin,
      ),
    );
  }

  _Stub? _match(String executable, List<String> arguments) {
    final line = ([executable, ...arguments]).join(' ');
    for (final stub in _stubs) {
      if (line.contains(stub.contains)) return stub;
    }
    return null;
  }
}

class _Stub {
  _Stub({
    required this.contains,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.lines,
  });

  final String contains;
  final int exitCode;
  final String stdout;
  final String stderr;
  final List<String> lines;
}
