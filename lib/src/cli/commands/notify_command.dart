import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../../core/config/shipway_config.dart';
import '../../notify/run_notifier.dart';
import '../../notify/slack_client.dart';
import '../../notify/slack_message.dart';
import '../../pipeline/pipeline.dart';
import '../../pipeline/pipeline_parser.dart';
import '../exit_codes.dart';
import '../notifications.dart';
import '../run_context.dart';

/// `shipway notify test`.
///
/// Sends one sample message, so a webhook that was revoked or a template with
/// a typo shows up now rather than after the release it was meant to report.
/// The sample is built from the config's own first pipeline, so it looks like
/// the real thing — marked "(test)", because a red "failed" in a release
/// channel is alarming whether or not anybody meant it.
class NotifyCommand extends Command<int> {
  NotifyCommand(this._contextProvider) {
    argParser
      ..addOption(
        'event',
        help:
            'Which message to send. Defaults to the first event in '
            'notify.on.',
        allowed: <String>[for (final e in NotifyEvent.values) e.name],
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Print the message Slack would receive, and send nothing.',
      );
  }

  final ContextProvider _contextProvider;

  RunContext get _context => _contextProvider();

  @override
  String get name => 'notify';

  @override
  String get description => 'Send a test Slack message.';

  @override
  String get invocation =>
      'shipway notify test [--event started|success|failure]';

  @override
  Future<int> run() async {
    final results = argResults!;
    final context = _context;
    final logger = context.logger;

    final action = results.rest.isEmpty ? null : results.rest.first;
    if (action != 'test') {
      logger.err(
        action == null
            ? 'Say what to do: `shipway notify test`.'
            : 'Unknown action "$action". Did you mean `shipway notify test`?',
      );
      return ShipwayExit.userError;
    }

    final config = await context.requireConfig();
    final notify = config.notify;
    if (!notify.hasSlack) {
      logger
        ..err('This config sends no notifications.')
        ..info('Add a notify block to shipway.yaml:')
        ..info('')
        ..info('  notify:')
        ..info('    slack_webhook_ref: SLACK_WEBHOOK')
        ..info('    on: [started, failure]');
      return ShipwayExit.userError;
    }

    final requested = results['event'] as String?;
    final event = requested == null
        ? NotifyEvent.values.firstWhere(notify.on.contains)
        : NotifyEvent.values.byName(requested);

    final payload = await _sample(config, event);

    if (results['dry-run'] as bool) {
      logger
        ..info('')
        ..info(const JsonEncoder.withIndent('  ').convert(payload.toJson()))
        ..info('')
        ..info('Nothing was sent.');
      return ShipwayExit.success;
    }

    final transport = await slackTransportFor(context, notify);
    if (transport == null) return ShipwayExit.environmentError;

    try {
      await transport.post(payload);
    } on SlackException catch (problem) {
      logger.err(context.redactor.redact(problem.message));
      final hint = problem.hint;
      if (hint != null) logger.info('  $hint');
      return ShipwayExit.environmentError;
    }

    final how = transport.live
        ? 'as the bot, to ${notify.slackChannel}'
        : 'through the webhook';
    logger.info(green.wrap('Sent a test ${event.name} message $how.') ?? '');
    return ShipwayExit.success;
  }

  /// A run that got as far as [event] implies, rendered exactly as a real one
  /// would be.
  Future<SlackPayload> _sample(ShipwayConfig config, NotifyEvent event) async {
    final (:name, :steps) = _sampleRun(config);
    final recorder = _Recorder();
    final start = DateTime(2026);
    var now = start;

    final notifier = RunNotifier(
      transport: recorder,
      // Only this event, so the sample is sent whatever notify.on says.
      config: NotifyConfig(
        on: <NotifyEvent>{event},
        messages: config.notify.messages,
      ),
      facts: await runFacts(_context, config, name: '$name (test)'),
      warn: (_) {},
      clock: () => now,
    );

    notifier.begin(steps);
    if (event == NotifyEvent.started) {
      notifier.stepStarted(steps.first.key);
      await notifier.idle;
      return recorder.posted.last;
    }

    for (var i = 0; i < steps.length; i++) {
      final last = i == steps.length - 1;
      final fails = last && event == NotifyEvent.failure;
      notifier.stepFinished(
        steps[i].key,
        succeeded: !fails,
        duration: Duration(seconds: last ? 214 : 19),
        exitCode: fails ? ShipwayExit.environmentError : 0,
      );
    }
    now = start.add(const Duration(minutes: 4, seconds: 12));
    await notifier.finish(succeeded: event == NotifyEvent.success);
    return recorder.posted.last;
  }

  /// The config's first pipeline, or a typical one when it has none.
  ({String name, List<({String key, String label})> steps}) _sampleRun(
    ShipwayConfig config,
  ) {
    if (config.pipelines.isNotEmpty) {
      final first = config.pipelines.entries.first;
      try {
        final pipeline = PipelineParser.parse(first.key, first.value);
        return (
          name: pipeline.name,
          steps: <({String key, String label})>[
            for (final step in pipeline.steps)
              (key: step.key, label: step.label),
          ],
        );
      } on PipelineException {
        // A broken pipeline is `shipway run`'s to report; the sample falls
        // back rather than failing a command about Slack.
      }
    }
    final app = config.appOrNull(_context.appId);
    final flavor = app?.flavors.keys.lastOrNull ?? 'prod';
    final release = PipelineRelease(
      platform: 'ios',
      flavor: flavor,
      target: 'testflight',
    );
    return (
      name: 'beta',
      steps: <({String key, String label})>[
        (key: 'analyze', label: 'analyze'),
        (key: 'test', label: 'test'),
        (key: release.key, label: release.label),
      ],
    );
  }
}

/// Catches what the sample would have posted.
class _Recorder implements SlackTransport {
  final List<SlackPayload> posted = <SlackPayload>[];

  @override
  bool get live => false;

  @override
  Future<SlackThread?> post(SlackPayload payload) async {
    posted.add(payload);
    return null;
  }

  @override
  Future<void> update(SlackThread thread, SlackPayload payload) async {}

  @override
  Future<void> reply(
    SlackThread thread,
    SlackPayload payload, {
    bool broadcast = false,
  }) async {}
}
