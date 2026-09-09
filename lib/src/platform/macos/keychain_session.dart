import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../core/env/run_environment.dart';
import '../../core/io/process_runner.dart';
import '../../core/io/redactor.dart';
import '../../core/secrets/secret_names.dart';

/// A keychain taxiway created, and undertakes to remove.
///
/// Exists because `setup_ci` — the usual answer — does three things that are
/// wrong on a machine that keeps running:
///
/// - it creates the keychain with an **empty password**;
/// - it can make that keychain the **default**, which changes behaviour for
///   every other job on the box;
/// - it **never cleans up**, so a shared Mac accumulates keychains pointing at
///   directories that no longer exist.
///
/// taxiway therefore owns the lifecycle and hands fastlane the result.
/// `setup_ci` skips itself entirely when `MATCH_KEYCHAIN_NAME` is already set,
/// so this cooperates with fastlane rather than fighting it, and `match`'s own
/// importer still sets the partition lists on the certificates it installs.
///
/// On a workstation this does nothing at all: a developer's certificates belong
/// in their login keychain, where Xcode will show them.
class KeychainSession {
  KeychainSession._({
    required this.name,
    required this.path,
    required String password,
    required this.runner,
    required this.originalSearchList,
  }) : _password = password;

  /// Name taxiway gives the keychain it manages.
  static const String defaultName = 'taxiway.keychain-db';

  final String name;
  final String path;
  final String _password;
  final ProcessRunner runner;

  /// The search list as it was found, restored verbatim on teardown.
  final List<String> originalSearchList;

  bool _closed = false;

  /// What fastlane needs to use this keychain instead of making its own.
  ///
  /// `MATCH_KEYCHAIN_NAME` being set is what makes `setup_ci` stand down.
  /// `MATCH_READONLY` is set because a build must never mint a certificate:
  /// they are a limited, shared resource, and a runner that creates one per
  /// build exhausts the team's allowance.
  Map<String, String> get environment => <String, String>{
    'MATCH_KEYCHAIN_NAME': name,
    'MATCH_KEYCHAIN_PASSWORD': _password,
    'MATCH_READONLY': 'true',
  };

  /// Opens a session, or returns null when none is wanted.
  ///
  /// Null on a workstation and on anything that is not macOS — both are the
  /// answer "use what is already there", not a failure.
  static Future<KeychainSession?> open({
    required RunEnvironment environment,
    required ProcessRunner runner,
    required Redactor redactor,
    Map<String, String>? processEnvironment,
    String name = defaultName,
    bool isMacOS = true,
  }) async {
    if (!isMacOS || environment.mayUseLoginKeychain) return null;

    final variables = processEnvironment ?? Platform.environment;
    final password =
        variables[SecretNames.keychainPassword]?.trim().isNotEmpty ?? false
        ? variables[SecretNames.keychainPassword]!
        : _generatePassword();

    // The password is passed to `security` on a command line taxiway also
    // logs in verbose mode, so it has to be scrubbed before it is ever used.
    redactor.register(password);

    final originalSearchList = await _searchList(runner);

    // Recreate rather than reuse. A keychain left by an earlier run may have a
    // different password, may be locked, and may hold certificates that have
    // since been revoked; starting clean is cheaper than reasoning about it.
    await runner.run('security', <String>['delete-keychain', name]);
    final created = await runner.run('security', <String>[
      'create-keychain',
      '-p',
      password,
      name,
    ]);
    if (!created.ok) {
      throw KeychainFailure(
        'Could not create the keychain $name.',
        detail: created.output,
      );
    }

    final session = KeychainSession._(
      name: name,
      path: name,
      password: password,
      runner: runner,
      originalSearchList: originalSearchList,
    );

    try {
      await session._prepare();
    } on Object {
      // A half-made keychain is worse than none: it is in the search list and
      // signs nothing.
      await session.close();
      rethrow;
    }
    return session;
  }

  Future<void> _prepare() async {
    // No auto-lock. A keychain that relocks mid-build fails the signing step
    // with an error that names nothing useful.
    await runner.run('security', <String>[
      'set-keychain-settings',
      '-lut',
      '21600',
      path,
    ]);
    await runner.run('security', <String>[
      'unlock-keychain',
      '-p',
      _password,
      path,
    ]);

    // Appended to the search list, and the default deliberately left alone:
    // changing it is a change for every other process on the machine, and it
    // is what makes `setup_ci` unsafe on a shared runner.
    final appended = await runner.run('security', <String>[
      'list-keychains',
      '-d',
      'user',
      '-s',
      ...originalSearchList,
      path,
    ]);
    if (!appended.ok) {
      throw KeychainFailure(
        'Could not add $name to the keychain search list.',
        detail: appended.output,
      );
    }
  }

  /// Removes the keychain and restores the search list exactly.
  ///
  /// Safe to call more than once. Every failure is swallowed: teardown runs on
  /// the error path too, and a cleanup that throws would replace a useful error
  /// with a useless one.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    await runner.run('security', <String>[
      'list-keychains',
      '-d',
      'user',
      '-s',
      ...originalSearchList,
    ]);
    await runner.run('security', <String>['delete-keychain', path]);
  }

  /// The current user search list, quotes stripped.
  static Future<List<String>> _searchList(ProcessRunner runner) async {
    final result = await runner.run('security', <String>[
      'list-keychains',
      '-d',
      'user',
    ]);
    if (!result.ok) return const <String>[];
    return <String>[
      for (final line in result.stdout.split('\n'))
        if (line.trim().isNotEmpty) line.trim().replaceAll('"', ''),
    ];
  }

  /// A real password, because `setup_ci` uses an empty one and this keychain
  /// may sit on a machine other people can reach.
  static String _generatePassword() {
    final random = Random.secure();
    return base64Url.encode(List<int>.generate(24, (_) => random.nextInt(256)));
  }
}

class KeychainFailure implements Exception {
  const KeychainFailure(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message\n$detail';
}
