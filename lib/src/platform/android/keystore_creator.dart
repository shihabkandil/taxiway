import 'dart:io';
import 'dart:math';

import '../../core/io/process_runner.dart';
import '../../core/io/redactor.dart';

/// A keystore could not be created, and said why.
class KeystoreFailure implements Exception {
  const KeystoreFailure(this.message, {this.fixHint});

  final String message;
  final String? fixHint;

  @override
  String toString() => message;
}

/// Creates an Android upload keystore with `keytool`.
///
/// The password never reaches a command line. `keytool` reads it from the
/// console, and a piped stdin satisfies that — twice, because it asks for a
/// confirmation. Verified against the JDK on this machine.
///
/// Modern `keytool` writes **PKCS12**, where the key and the store share one
/// password. taxiway therefore uses one password for both rather than
/// generating two and writing a `key.properties` that only appears to have
/// separate ones.
class KeystoreCreator {
  const KeystoreCreator({required this.runner, required this.redactor});

  final ProcessRunner runner;
  final Redactor redactor;

  /// Roughly twenty-seven years. The upload key has to outlive the app, and a
  /// keystore that expires is not something you find out about until a release
  /// is rejected.
  static const int defaultValidityDays = 10000;

  /// Creates a keystore at [path], and proves it can be opened afterwards.
  ///
  /// Throws [KeystoreFailure] rather than returning a status: a keystore that
  /// was not created is the failure this exists to make visible.
  Future<void> create({
    required String path,
    required String alias,
    required String password,
    required String commonName,
    int validityDays = defaultValidityDays,
  }) async {
    final file = File(path);
    if (file.existsSync()) {
      // Never overwritten, not even with a flag on this method. An upload key
      // is the only proof that an update comes from the same publisher; losing
      // one means a support round-trip with Google at best.
      throw KeystoreFailure(
        'A keystore already exists at $path.',
        fixHint:
            'Keep it — an app already on Play cannot be updated without it. '
            'To use a different one, point taxiway.yaml at it instead.',
      );
    }
    file.parent.createSync(recursive: true);

    redactor.register(password);

    final result = await runner.run(
      'keytool',
      <String>[
        '-genkeypair',
        '-keystore',
        path,
        '-alias',
        alias,
        '-keyalg',
        'RSA',
        '-keysize',
        '2048',
        '-validity',
        '$validityDays',
        '-dname',
        'CN=$commonName',
      ],
      // The password, then its confirmation. Not `-storepass`, which would put
      // it in `ps` for as long as the key generation takes.
      stdin: '$password\n$password\n',
    );
    if (result.notFound) {
      throw const KeystoreFailure(
        '`keytool` is not available.',
        fixHint: 'It ships with the JDK. `taxiway doctor` checks for one.',
      );
    }

    // A zero exit code is not evidence: given a password and a confirmation
    // that differ, `keytool` writes no file and still exits 0.
    if (!file.existsSync()) {
      throw KeystoreFailure(
        'keytool wrote no keystore at $path.',
        fixHint: result.output.trim().isEmpty ? null : result.output.trim(),
      );
    }

    if (!await canOpen(path: path, password: password)) {
      throw KeystoreFailure(
        'The keystore at $path cannot be opened with the password it was '
        'made with.',
        fixHint: 'That is a taxiway bug. Delete the file and please report it.',
      );
    }
  }

  /// Whether [password] opens the keystore at [path].
  ///
  /// The one honest check available: `keytool -list` exits non-zero on a wrong
  /// password. It reveals nothing — a listing names aliases, not secrets.
  Future<bool> canOpen({required String path, required String password}) async {
    final result = await runner.run('keytool', <String>[
      '-list',
      '-keystore',
      path,
    ], stdin: '$password\n');
    return result.ok;
  }

  /// A password worth having, when nobody wants to invent one.
  ///
  /// Generated rather than prompted by default: a keystore password is typed
  /// once and then only ever read by a machine, so a memorable one buys
  /// nothing and costs entropy.
  static String generatePassword({int length = 32}) {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return String.fromCharCodes(<int>[
      for (var i = 0; i < length; i++)
        alphabet.codeUnitAt(random.nextInt(alphabet.length)),
    ]);
  }
}
