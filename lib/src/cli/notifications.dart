import 'dart:io';

import 'package:pubspec_parse/pubspec_parse.dart';

import '../core/config/shipway_config.dart';
import '../notify/run_notifier.dart';
import '../notify/slack_client.dart';
import '../secrets/secret_resolver.dart';
import 'run_context.dart';

/// Opens a [RunNotifier] for this run, or returns null when nothing should be
/// sent: no Slack configured, or none of its secrets set on this machine.
///
/// The bot token wins when it resolves; otherwise the webhook. One config can
/// then serve a laptop that holds only the webhook and a runner that holds
/// both, without either being told which it is.
Future<RunNotifier?> openNotifier(
  RunContext context,
  ShipwayConfig config, {
  required String name,
  String flavor = '',
  String target = '',
  String platform = '',
  String? versionName,
}) async {
  final notify = config.notify;
  if (!notify.hasSlack) return null;

  final transport = await slackTransportFor(context, notify);
  if (transport == null) return null;

  return RunNotifier(
    transport: transport,
    config: notify,
    facts: await runFacts(
      context,
      config,
      name: name,
      flavor: flavor,
      target: target,
      platform: platform,
      versionName: versionName,
    ),
    warn: (problem) {
      context.logger.warn('Slack: ${context.redactor.redact(problem.message)}');
      final hint = problem.hint;
      if (hint != null) context.logger.info('  $hint');
    },
  );
}

/// The transport the config and this machine's secrets allow, or null with
/// the reason already logged.
Future<SlackTransport?> slackTransportFor(
  RunContext context,
  NotifyConfig notify,
) async {
  final logger = context.logger;
  final resolver = SecretResolver(
    environment: context.environment.environment,
    projectRoot: context.projectRoot,
    runner: context.runner,
    redactor: context.redactor,
    processEnvironment: context.processEnvironment,
    host: context.host,
  );

  final botRef = notify.slackBotTokenRef;
  final channel = notify.slackChannel;
  if (botRef != null && channel != null) {
    final token = await resolver.read(botRef);
    if (token != null) {
      return SlackBot(
        token: token.trim(),
        channel: channel,
        http: context.http,
        refName: botRef,
      );
    }
  }

  final hookRef = notify.slackWebhookRef;
  if (hookRef != null) {
    final value = await resolver.read(hookRef);
    if (value != null) {
      final url = Uri.tryParse(value.trim());
      if (url == null || url.scheme != 'https' || url.host.isEmpty) {
        // Worth its own message: the usual cause is a channel name or a bot
        // token pasted into the webhook variable, and "Slack answered 404"
        // would not say so.
        logger.warn(
          '$hookRef is set, but it is not an https URL, so no Slack message '
          'will be sent.',
        );
        logger.info(
          '  It should hold the incoming webhook URL, '
          'https://hooks.slack.com/services/…',
        );
        return null;
      }
      if (botRef != null) {
        logger.detail(
          '$botRef is not set here, so Slack gets one message per event '
          'through the webhook rather than a live status message.',
        );
      }
      return SlackWebhook(url: url, http: context.http, refName: hookRef);
    }
  }

  final names = <String>[?botRef, ?hookRef].join(' or ');
  logger.warn(
    'notify is configured, but $names is not set here, so no Slack message '
    'will be sent.',
  );
  logger.info('  shipway secrets list   — where each one is looked for');
  return null;
}

/// The placeholder values known before a run starts.
Future<Map<String, String>> runFacts(
  RunContext context,
  ShipwayConfig config, {
  required String name,
  String flavor = '',
  String target = '',
  String platform = '',
  String? versionName,
}) async {
  final env = context.processEnvironment;
  return <String, String>{
    'project': config.project.name,
    'name': name,
    'flavor': flavor,
    'target': target,
    'platform': platform,
    'version': versionName ?? _pubspecVersion(context, config),
    'branch': await _branch(context),
    'commit': await _git(context, <String>['rev-parse', '--short', 'HEAD']),
    'host': _host(env),
    'user': env['GITHUB_ACTOR'] ?? env['USER'] ?? env['USERNAME'] ?? '',
    'run_url': ciRunUrl(env) ?? '',
  };
}

/// The version name, without the build number: the build number is resolved
/// by the lane at upload time, so any number read here could be wrong.
String _pubspecVersion(RunContext context, ShipwayConfig config) {
  try {
    final file = File(context.resolve(config.project.pubspec));
    final version = Pubspec.parse(file.readAsStringSync()).version;
    if (version == null) return '';
    return '${version.major}.${version.minor}.${version.patch}'
        '${version.preRelease.isEmpty ? '' : '-${version.preRelease.join('.')}'}';
  } on Object {
    return '';
  }
}

/// A CI checkout is usually a detached HEAD, where git says only `HEAD`; the
/// runner knows the branch it was asked to build.
Future<String> _branch(RunContext context) async {
  final env = context.processEnvironment;
  for (final variable in const <String>[
    'GITHUB_HEAD_REF',
    'GITHUB_REF_NAME',
    'CI_COMMIT_REF_NAME',
    'BITRISE_GIT_BRANCH',
    'BUILDKITE_BRANCH',
    'CIRCLE_BRANCH',
  ]) {
    final value = env[variable];
    if (value != null && value.isNotEmpty) return value;
  }
  final branch = await _git(context, <String>[
    'rev-parse',
    '--abbrev-ref',
    'HEAD',
  ]);
  return branch == 'HEAD' ? '' : branch;
}

Future<String> _git(RunContext context, List<String> arguments) async {
  final result = await context.runner.run(
    'git',
    arguments,
    workingDirectory: context.projectRoot,
  );
  return result.ok ? result.stdout.trim() : '';
}

String _host(Map<String, String> env) {
  if (env['GITHUB_ACTIONS'] == 'true') return 'GitHub Actions';
  try {
    return Platform.localHostname;
  } on Object {
    return '';
  }
}

/// A link to the CI run, from whichever CI this is.
String? ciRunUrl(Map<String, String> env) {
  final server = env['GITHUB_SERVER_URL'];
  final repository = env['GITHUB_REPOSITORY'];
  final run = env['GITHUB_RUN_ID'];
  if (server != null && repository != null && run != null) {
    return '$server/$repository/actions/runs/$run';
  }
  for (final variable in const <String>[
    'CI_JOB_URL',
    'BITRISE_BUILD_URL',
    'BUILDKITE_BUILD_URL',
    'CIRCLE_BUILD_URL',
  ]) {
    final value = env[variable];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}
