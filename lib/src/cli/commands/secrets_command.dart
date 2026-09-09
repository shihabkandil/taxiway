import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../../secrets/secret_requirements.dart';
import '../../secrets/secret_resolver.dart';
import '../exit_codes.dart';
import '../run_context.dart';

/// `taxiway secrets list|check`.
///
/// Both answer the same question — what does this project need, and is it
/// here? — and neither ever prints a value. That is a property of the types
/// rather than of care: the resolver hands back a [SecretStatus] carrying a
/// source, never a secret.
///
/// `check` exists to be the first step of a CI job. It turns a twenty-minute
/// build that dies at the upload into a five-second failure naming
/// `ASC_KEY_P8_BASE64`.
class SecretsCommand extends Command<int> {
  SecretsCommand(this._contextProvider) {
    argParser
      ..addFlag('json', negatable: false, help: 'Emit the report as JSON.')
      ..addOption(
        'flavor',
        abbr: 'f',
        help: 'Resolve .env.<flavor> rather than .env.',
      );
  }

  final ContextProvider _contextProvider;

  RunContext get _context => _contextProvider();

  @override
  String get name => 'secrets';

  @override
  String get description =>
      'Show which credentials this project needs, and whether they are set.';

  @override
  String get invocation => 'taxiway secrets list|check';

  @override
  Future<int> run() async {
    final results = argResults!;
    final context = _context;
    final logger = context.logger;

    final action = results.rest.isEmpty ? 'list' : results.rest.first;
    if (action != 'list' && action != 'check') {
      logger.err('Unknown action "$action". Expected list or check.');
      return TaxiwayExit.userError;
    }

    final config = await context.requireConfig();
    final environment = context.environment;

    final requirements = SecretRequirements.of(
      config,
      environment: environment.environment,
      appId: context.appId,
    );
    if (requirements.isEmpty) {
      logger.info(
        'This config declares no credentials. Add signing or targets to '
        'taxiway.yaml and they will be listed here.',
      );
      return TaxiwayExit.success;
    }

    final resolver = SecretResolver(
      environment: environment.environment,
      projectRoot: context.projectRoot,
      runner: context.runner,
      redactor: context.redactor,
      flavor: results['flavor'] as String?,
    );
    final statuses = await resolver.statuses(requirements);

    if (results['json'] as bool) {
      logger.info(_json(statuses, resolver));
    } else {
      _report(statuses, resolver, checking: action == 'check');
    }

    final blocking = statuses.where((s) => s.blocks).toList();
    if (action == 'check' && blocking.isNotEmpty) {
      return TaxiwayExit.environmentError;
    }
    return TaxiwayExit.success;
  }

  void _report(
    List<SecretStatus> statuses,
    SecretResolver resolver, {
    required bool checking,
  }) {
    final context = _context;
    final logger = context.logger;
    final environment = context.environment;

    logger
      ..info('')
      ..info(
        darkGray.wrap(
              'Environment: ${environment.environment.flagName} '
              '(${environment.explanation}). Looking in: '
              '${resolver.chain.map(_sourceLabel).join(' → ')}.',
            ) ??
            '',
      )
      ..info('');

    for (final status in statuses) {
      final label = _label(status);
      logger.info('  $label ${status.name}');

      final detail = status.source.found
          ? '${status.requirement.wantedBy} — found in ${status.detail}'
          : status.requirement.wantedBy;
      logger.info('           ${darkGray.wrap(detail) ?? detail}');

      if (status.source == SecretSource.missingFile) {
        logger.info(
          '           ${red.wrap('names ${status.detail}, which does not exist') ?? ''}',
        );
      }
    }

    final blocking = statuses.where((s) => s.blocks).toList();
    final found = statuses.where((s) => s.source.found).length;

    logger
      ..info('')
      ..info('$found of ${statuses.length} resolved.');

    if (blocking.isEmpty) {
      if (checking) logger.info(green.wrap('Nothing is missing.') ?? '');
      return;
    }

    logger
      ..info('')
      ..err(
        '${blocking.length} required '
        '${blocking.length == 1 ? 'credential is' : 'credentials are'} '
        'missing: ${blocking.map((s) => s.name).join(', ')}',
      );

    // The remedy depends on where you are, because the chain does.
    if (environment.environment.mayPrompt) {
      logger.info(
        'Set them in your environment, or add them to '
        '${resolver.dotenvPath} (git-ignored).',
      );
    } else {
      logger.info(
        'This environment reads only '
        '${resolver.chain.map(_sourceLabel).join(' and ')}, so they must be '
        'provided there — as repository secrets, or in '
        '${resolver.dotenvPath} on the runner.',
      );
    }
  }

  String _label(SecretStatus status) => switch (status.source) {
    final SecretSource s when s.found => green.wrap('    ok') ?? 'ok',
    SecretSource.missingFile => red.wrap('no file') ?? 'no file',
    _ when status.requirement.isRequired => red.wrap('missing') ?? 'missing',
    _ => yellow.wrap('  unset') ?? 'unset',
  };

  static String _sourceLabel(SecretSource source) => switch (source) {
    SecretSource.environment => 'environment',
    SecretSource.dotenv => '.env',
    SecretSource.keychain => 'keychain',
    SecretSource.prompt => 'a prompt',
    _ => source.name,
  };

  String _json(List<SecretStatus> statuses, SecretResolver resolver) {
    final environment = _context.environment;
    return const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'environment': environment.environment.flagName,
      'environmentSource': environment.source.name,
      'chain': resolver.chain.map((s) => s.name).toList(),
      'secrets': <Map<String, dynamic>>[
        for (final status in statuses)
          <String, dynamic>{
            'name': status.name,
            'required': status.requirement.isRequired,
            'wantedBy': status.requirement.wantedBy,
            'source': status.source.name,
            'present': status.source.found,
            'blocks': status.blocks,
          },
      ],
      'blocking': statuses.where((s) => s.blocks).map((s) => s.name).toList(),
    });
  }
}
