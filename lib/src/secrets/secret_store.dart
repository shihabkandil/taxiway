import '../core/env/host_platform.dart';
import '../core/io/process_runner.dart';
import '../core/io/redactor.dart';
import 'secret_resolver.dart';

/// A store refused to hold a value, and said why.
class SecretStoreFailure implements Exception {
  const SecretStoreFailure(this.message, {this.fixHint});

  final String message;

  /// The single next action that would resolve this.
  final String? fixHint;

  @override
  String toString() => message;
}

/// Writes secrets into the login keychain.
///
/// Deliberately a separate type from [SecretResolver]. That one's guarantee is
/// structural — it is never handed a value, so it cannot leak one — and adding
/// a write would end it. This is the one place in shipway that holds a
/// credential, and everything it holds is registered with the [Redactor] before
/// it goes anywhere near a subprocess.
///
/// The value never reaches a command line. `security add-generic-password -w`
/// with no argument reads the password from stdin — twice, as a confirmation —
/// which keeps it out of `ps` on a shared machine. Verified against the real
/// tool on macOS 15.
///
/// Nothing here reads a stored value back, not even to check its own work.
/// Verification asks whether the item exists and whether `security` announced
/// a refusal, which is enough to catch the one failure that looks like success
/// — and means a value only ever travels one way through this type.
class SecretStore {
  SecretStore({
    required this.runner,
    required this.redactor,
    this.service = SecretResolver.defaultKeychainService,
    HostPlatform? host,
  }) : host = host ?? HostPlatform.current;

  final ProcessRunner runner;
  final Redactor redactor;

  /// The generic-password service every shipway item is filed under, so the
  /// whole set can be found — and removed — as a group.
  final String service;

  final HostPlatform host;

  /// Stores [value] under [name], replacing any value already there.
  ///
  /// Throws [SecretStoreFailure] rather than returning a status: a store that
  /// quietly did not store is the failure this whole method exists to prevent.
  Future<void> set(String name, String value) async {
    if (!host.hasSecurityKeychain) {
      throw SecretStoreFailure(
        'There is no login keychain on ${host.label}.',
        fixHint:
            'Put the value in .env instead, which shipway reads on every '
            'platform, and keep that file out of git.',
      );
    }
    if (value.isEmpty) {
      throw const SecretStoreFailure('An empty value is not worth storing.');
    }
    if (value.contains('\n')) {
      // `security` reads exactly one line for the password and one for the
      // confirmation, so a multi-line value silently becomes its first two
      // lines compared against each other.
      throw const SecretStoreFailure(
        'The login keychain cannot hold a multi-line value.',
        fixHint:
            'Store it encoded — `shipway secrets set <NAME> --from-file '
            '<path> --base64` — or, if a lane needs it raw, set it as a CI '
            'repository secret, where multi-line values are fine.',
      );
    }

    redactor.register(value);

    final result = await runner.run(
      'security',
      <String>[
        'add-generic-password',
        // Without this, an existing item is a failure rather than an update.
        '-U',
        '-s',
        service,
        '-a',
        name,
        '-w',
      ],
      // Written twice: the second read is the confirmation prompt.
      stdin: '$value\n$value\n',
    );
    if (result.notFound) {
      throw const SecretStoreFailure(
        '`security` is not available, so nothing was stored.',
        fixHint: 'It ships with macOS; check your PATH.',
      );
    }

    // A zero exit code is not evidence anything was written: given a value and
    // a confirmation that differ, `security` prints this, stores nothing, and
    // still exits 0. Verified against macOS 15.
    final refused = result.output.contains(mismatchSignature);
    if (refused || !result.ok || !await has(name)) {
      throw SecretStoreFailure(
        'The keychain did not accept $name, and nothing was stored.',
        fixHint: refused
            ? 'That is a shipway bug — the value and its confirmation were '
                  'sent identically. Please report it.'
            : 'Check that the login keychain is unlocked.',
      );
    }
  }

  /// What `security` prints when the value and its confirmation differ.
  ///
  /// Matched rather than inferred from the exit code, which is 0 either way.
  static const String mismatchSignature = "passwords don't match";

  /// Removes [name]. True when something was there to remove.
  Future<bool> delete(String name) async {
    if (!host.hasSecurityKeychain) return false;
    final result = await runner.run('security', <String>[
      'delete-generic-password',
      '-s',
      service,
      '-a',
      name,
    ]);
    return result.ok;
  }

  /// Whether [name] is already stored, without reading what it is.
  Future<bool> has(String name) async {
    if (!host.hasSecurityKeychain) return false;
    final result = await runner.run('security', <String>[
      'find-generic-password',
      '-s',
      service,
      '-a',
      name,
    ]);
    return result.ok;
  }
}
