import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../../core/config/config_patch.dart';
import '../../core/config/taxiway_config.dart';
import '../../platform/android/keystore_creator.dart';
import '../../platform/ios/match_repository.dart';
import '../../secrets/secret_store.dart';
import '../exit_codes.dart';
import '../run_context.dart';

/// `taxiway setup android-signing` — the parts of getting a project shippable
/// that are not files taxiway can simply write.
///
/// Distinct from `generate` on purpose. `generate` is idempotent and
/// derivable: run it twice and nothing changes, throw the output away and it
/// comes back. Setup is neither. It creates things that cannot be recreated —
/// an upload key is the only proof that an update comes from the same
/// publisher — so it refuses to overwrite, states what it did, and stops.
class SetupCommand extends Command<int> {
  SetupCommand(this._contextProvider) {
    argParser
      ..addOption(
        'alias',
        help: 'android-signing: the key alias.',
        defaultsTo: 'upload',
      )
      ..addOption(
        'keystore',
        help: 'android-signing: where to write the keystore.',
        valueHelp: 'path',
        defaultsTo: defaultKeystorePath,
      )
      ..addFlag(
        'password-stdin',
        negatable: false,
        help:
            'android-signing: use the password on standard input rather than '
            'generating one.',
      )
      ..addOption(
        'match-url',
        help:
            'ios-signing: the certificates repository. Defaults to the one '
            'taxiway.yaml already names.',
        valueHelp: 'url',
      )
      ..addOption(
        'branch',
        help: 'ios-signing: the branch to read.',
        defaultsTo: 'master',
      )
      ..addFlag(
        'create',
        negatable: false,
        help:
            'ios-signing: allow creating what is missing. Without it, setup '
            'only reads and reports.',
      );
  }

  final ContextProvider _contextProvider;

  RunContext get _context => _contextProvider();

  /// Beside `android/app`, so `storeFile` resolves to `../` from Gradle's
  /// point of view and the same file works on every checkout.
  static const String defaultKeystorePath = 'android/upload-keystore.jks';

  static const List<String> actions = <String>[
    'android-signing',
    'ios-signing',
  ];

  @override
  String get name => 'setup';

  @override
  String get description =>
      'Create the credentials a project needs, once, and record their names.';

  @override
  String get invocation => 'taxiway setup ${actions.join('|')}';

  @override
  Future<int> run() async {
    final results = argResults!;
    final logger = _context.logger;

    final action = results.rest.isEmpty ? null : results.rest.first;
    if (action == null || !actions.contains(action)) {
      logger.err(
        action == null
            ? 'Say what to set up: ${actions.join(', ')}.'
            : 'Unknown action "$action". Expected: ${actions.join(', ')}.',
      );
      return TaxiwayExit.userError;
    }

    final config = await _context.requireConfig();
    return action == 'ios-signing'
        ? _iosSigning(results, config)
        : _androidSigning(results, config);
  }

  /// `taxiway setup ios-signing` — adopt a certificates repository.
  ///
  /// Read-only by default, and the read is deliberately shallow: match
  /// encrypts each file in place and leaves its *name* alone, so which bundle
  /// ids are covered is answerable from the layout without a passphrase,
  /// without decrypting anything and without talking to Apple. taxiway
  /// therefore never handles a certificate — only the question of whether one
  /// exists.
  ///
  /// It adopts rather than initialises. A certificates repository is shared:
  /// reshaping one breaks signing for everyone else using it, and creating a
  /// certificate spends one of a team's limited allowance. Gaps are reported;
  /// filling them needs `--create`.
  Future<int> _iosSigning(ArgResults results, TaxiwayConfig config) async {
    final context = _context;
    final logger = context.logger;

    final appId = context.appId ?? config.defaultAppId;
    final app = config.appOrNull(appId);
    if (app == null) {
      logger.err('No app to set up. Check `apps:` in taxiway.yaml.');
      return TaxiwayExit.userError;
    }

    final url =
        (results['match-url'] as String?) ?? app.signing.ios?.matchGitUrl;
    if (url == null) {
      logger
        ..err('No certificates repository to read.')
        ..info(
          'Pass --match-url, or set signing.ios.match_git_url in '
          'taxiway.yaml. It is the git repository match keeps your '
          'certificates and profiles in.',
        );
      return TaxiwayExit.userError;
    }

    final branch = results['branch'] as String;
    final progress = logger.progress('Reading $url');

    final MatchRepositoryContents contents;
    try {
      contents = await MatchRepository.read(
        gitUrl: url,
        runner: context.runner,
        branch: branch,
      );
    } on MatchRepositoryFailure catch (failure) {
      progress.fail('Could not read the certificates repository');
      logger.err(failure.message);
      final hint = failure.fixHint;
      if (hint != null) logger.info(hint);
      return TaxiwayExit.environmentError;
    }
    progress.complete('Read $url');

    return _reportCoverage(
      results,
      app: app,
      appId: appId!,
      url: url,
      contents: contents,
    );
  }

  /// Compares what the repository holds against what the config asks for.
  int _reportCoverage(
    ArgResults results, {
    required AppConfig app,
    required String appId,
    required String url,
    required MatchRepositoryContents contents,
  }) {
    final logger = _context.logger;

    // The type taxiway's generated Matchfile syncs. A repository full of
    // development profiles does not make an App Store build signable.
    const type = 'appstore';

    final wanted = <String>[
      for (final flavor in app.flavors.entries)
        if (_bundleIdFor(app, flavor.value) != null)
          _bundleIdFor(app, flavor.value)!,
    ];
    if (wanted.isEmpty && app.ios?.bundleId != null) {
      wanted.add(app.ios!.bundleId!);
    }

    if (contents.isEmpty) {
      logger
        ..info('')
        ..warn('That repository is empty — no certificates, no profiles.')
        ..info(
          results['create'] as bool
              ? 'Run `bundle exec fastlane match appstore` from ios/ to '
                    'populate it. taxiway does not create Apple certificates '
                    'itself: match already does it well, and doing it twice '
                    'is how a team runs out of them.'
              : 'Re-run with --create for what to do about it.',
        );
      return TaxiwayExit.environmentError;
    }

    logger.info('');
    for (final profile in contents.profiles) {
      logger.info(
        '  ${darkGray.wrap(profile.type.padRight(12)) ?? profile.type} '
        '${profile.bundleId}',
      );
    }

    final missing = contents.missingFrom(wanted, type);
    logger.info('');
    if (wanted.isEmpty) {
      logger.info(
        'This config names no iOS bundle ids yet, so there is nothing to '
        'check the repository against.',
      );
    } else if (missing.isEmpty) {
      logger.info(
        green.wrap('Every bundle id this config ships has an $type profile.') ??
            '',
      );
    } else {
      logger
        ..err(
          '${missing.length} bundle '
          '${missing.length == 1 ? 'id has' : 'ids have'} no $type profile: '
          '${missing.join(', ')}',
        )
        ..info(
          results['create'] as bool
              ? 'Run `bundle exec fastlane match appstore` from ios/ — it '
                    'registers the bundle id and creates the profile. That '
                    'needs an App Store Connect key with write access.'
              : 'Re-run with --create to be told how to fill them, or add '
                    'them with match yourself.',
        );
    }

    _recordMatchInConfig(appId: appId, url: url, existing: app.signing.ios);
    logger.info('Recorded the repository in taxiway.yaml. No value is in it.');

    logger
      ..info('')
      ..info('Next:')
      ..info('  taxiway secrets check     — MATCH_PASSWORD and the rest')
      ..info('  taxiway build ios --flavor <f>');

    return missing.isEmpty ? TaxiwayExit.success : TaxiwayExit.environmentError;
  }

  /// A flavor's full bundle id, or null when the config does not say.
  static String? _bundleIdFor(AppConfig app, FlavorConfig flavor) {
    final base = app.ios?.bundleId;
    return base == null ? null : '$base${flavor.suffix}';
  }

  void _recordMatchInConfig({
    required String appId,
    required String url,
    required IosSigningConfig? existing,
  }) {
    // Only what was missing: a team that already named its storage or team id
    // keeps them.
    final values = <List<String>, Object?>{
      if (existing?.matchGitUrl == null)
        <String>['apps', appId, 'signing', 'ios', 'match_git_url']: url,
    };
    if (values.isEmpty) return;

    final file = _context.configFile;
    if (file == null) return;
    file.writeAsStringSync(ConfigPatch.setAll(file.readAsStringSync(), values));
  }

  Future<int> _androidSigning(ArgResults results, TaxiwayConfig config) async {
    final context = _context;
    final logger = context.logger;

    if (!context.host.hasSecurityKeychain) {
      logger.err(
        'The passwords have nowhere to go: there is no login keychain on '
        '${context.host.label}.',
      );
      logger.info(
        'Generate the keystore with keytool and put the passwords in .env, '
        'which taxiway reads everywhere.',
      );
      return TaxiwayExit.environmentError;
    }

    final appId = context.appId ?? config.defaultAppId;
    final app = config.appOrNull(appId);
    if (app == null) {
      logger.err('No app to set up. Check `apps:` in taxiway.yaml.');
      return TaxiwayExit.userError;
    }

    final relative = results['keystore'] as String;
    final path = p.join(context.projectRoot, relative);
    final alias = results['alias'] as String;

    // Existing refs win: a team that already named its variables keeps them,
    // and the wizard fills the gap rather than renaming what works.
    final existing = app.signing.android;
    final keystoreRef = existing?.keystoreRef ?? 'ANDROID_KEYSTORE_BASE64';
    final storePasswordRef =
        existing?.keyProperties?.storePasswordRef ?? 'ANDROID_STORE_PASSWORD';
    final keyPasswordRef =
        existing?.keyProperties?.keyPasswordRef ?? 'ANDROID_KEY_PASSWORD';

    final password = await _password(results);
    if (password == null) return TaxiwayExit.userError;

    final creator = KeystoreCreator(
      runner: context.runner,
      redactor: context.redactor,
    );
    try {
      await creator.create(
        path: path,
        alias: alias,
        password: password,
        commonName: config.project.name,
      );
    } on KeystoreFailure catch (failure) {
      logger.err(failure.message);
      final hint = failure.fixHint;
      if (hint != null) logger.info(hint);
      return TaxiwayExit.userError;
    }
    logger.info('Created $relative (alias $alias).');

    // PKCS12, which modern keytool writes, shares one password between the
    // store and the key. Storing it under both names is not duplication — it
    // is what `key.properties` and the CI workflow each read.
    final store = SecretStore(
      runner: context.runner,
      redactor: context.redactor,
      host: context.host,
    );
    try {
      await store.set(storePasswordRef, password);
      await store.set(keyPasswordRef, password);
      // So `secrets check --env ci` is answerable locally, and so the value
      // to paste into GitHub exists somewhere other than a shell history.
      await store.set(keystoreRef, base64.encode(File(path).readAsBytesSync()));
    } on SecretStoreFailure catch (failure) {
      logger.err(failure.message);
      return TaxiwayExit.environmentError;
    }
    logger.info(
      'Stored $storePasswordRef, $keyPasswordRef and $keystoreRef in the '
      'login keychain.',
    );

    _writeKeyProperties(
      relative: relative,
      alias: alias,
      password: password,
      storePasswordRef: storePasswordRef,
      keyPasswordRef: keyPasswordRef,
    );
    logger.info('Wrote android/key.properties (git-ignored).');

    _recordInConfig(
      appId: appId!,
      keystoreRef: keystoreRef,
      storePasswordRef: storePasswordRef,
      keyPasswordRef: keyPasswordRef,
      alias: alias,
    );
    logger.info('Recorded the names in taxiway.yaml. No value is in it.');

    _reportGradleWiring(logger);

    logger
      ..info('')
      ..info('Next:')
      ..info('  taxiway secrets check     — everything should resolve now')
      ..info('  taxiway secrets export    — what to set on the CI repository')
      ..info('')
      ..warn(
        'Back up $relative somewhere that is not this repository. An app on '
        'Play cannot be updated without it.',
      );
    return TaxiwayExit.success;
  }

  /// The keystore password: generated unless one is piped in.
  ///
  /// Generated by default because a keystore password is typed once and read
  /// by a machine forever after, so a memorable one buys nothing and costs
  /// entropy.
  Future<String?> _password(ArgResults results) async {
    if (!(results['password-stdin'] as bool)) {
      return KeystoreCreator.generatePassword();
    }
    final piped = (await stdin.transform(utf8.decoder).join()).trim();
    if (piped.isEmpty) {
      _context.logger.err('--password-stdin was given but nothing arrived.');
      return null;
    }
    return piped;
  }

  /// `android/key.properties`, which Gradle reads to sign a release build.
  ///
  /// `storeFile` is relative to `android/app`, which is where Gradle resolves
  /// it from — an absolute path would work on this machine and nowhere else,
  /// and a path relative to the repository root fails silently by resolving to
  /// a file that is not there.
  void _writeKeyProperties({
    required String relative,
    required String alias,
    required String password,
    required String storePasswordRef,
    required String keyPasswordRef,
  }) {
    final fromAppModule = p.relative(
      p.join(_context.projectRoot, relative),
      from: p.join(_context.projectRoot, 'android', 'app'),
    );
    final file = File(p.join(_context.projectRoot, 'android', 'key.properties'))
      ..parent.createSync(recursive: true);
    file.writeAsStringSync('''
# Written by `taxiway setup android-signing`. Git-ignored, and it holds
# passwords: it must stay that way.
#
# The same values live in the login keychain as $storePasswordRef and
# $keyPasswordRef. On CI this file is rebuilt from repository secrets, so it
# is never committed and never uploaded.
storeFile=$fromAppModule
storePassword=$password
keyPassword=$password
keyAlias=$alias
''');
  }

  void _recordInConfig({
    required String appId,
    required String keystoreRef,
    required String storePasswordRef,
    required String keyPasswordRef,
    required String alias,
  }) {
    final file = File(
      _context.configPath ?? p.join(_context.projectRoot, 'taxiway.yaml'),
    );
    final base = <String>['apps', appId, 'signing', 'android'];
    file.writeAsStringSync(
      ConfigPatch.setAll(file.readAsStringSync(), <List<String>, Object?>{
        <String>[...base, 'keystore_ref']: keystoreRef,
        <String>[...base, 'key_properties', 'store_password_ref']:
            storePasswordRef,
        <String>[...base, 'key_properties', 'key_password_ref']: keyPasswordRef,
        <String>[...base, 'key_properties', 'key_alias']: alias,
      }),
    );
  }

  /// Says the one thing this command cannot do for you.
  ///
  /// Writing `key.properties` signs nothing on its own: Gradle has to be told
  /// to read it. A project generated by recent Flutter already is, and one
  /// that is not would build a release with the debug key — which uploads,
  /// installs, and is rejected by Play.
  void _reportGradleWiring(Logger logger) {
    final module = p.join(_context.projectRoot, 'android', 'app');
    final candidates = <File>[
      File(p.join(module, 'build.gradle.kts')),
      File(p.join(module, 'build.gradle')),
    ].where((f) => f.existsSync());

    if (candidates.isEmpty) {
      logger.warn('No android/app build file found, so nothing reads it yet.');
      return;
    }
    final wired = candidates.any(
      (f) => f.readAsStringSync().contains('key.properties'),
    );
    if (wired) return;

    logger
      ..info('')
      ..warn(
        'Your Gradle build does not read key.properties, so a release build '
        'would still be signed with the debug key — which installs, uploads, '
        'and is rejected by Play.',
      )
      ..info(
        'Add a signingConfig that loads it, then point buildTypes.release at '
        'that config. taxiway does not edit this file for you: it is the one '
        'that decides how your app is signed.',
      );
  }
}
