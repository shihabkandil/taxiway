import 'dart:async';

import '../core/config/shipway_config.dart';
import '../core/notify/message_template.dart';
import 'run_progress.dart';
import 'slack_client.dart';
import 'slack_message.dart';

/// Tells a channel how a run is going.
///
/// With a webhook, each event in `notify.on` is its own message. With a bot
/// token the first message is edited as steps finish, so a channel shows one
/// line per release rather than a trail of them — and because Slack notifies
/// nobody about an edit, a failure is also posted as a reply sent to the
/// channel. A success stays quiet.
///
/// Nothing here can fail a run. A notification that cannot be sent becomes a
/// warning, said once, and the release carries on: finding out about a
/// release is never worth more than the release.
class RunNotifier {
  RunNotifier({
    required this.transport,
    required this.config,
    required this.facts,
    required this.warn,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final SlackTransport transport;
  final NotifyConfig config;

  /// Placeholder values known before the run starts: `project`, `name`,
  /// `branch` and the rest. The run supplies `status`, `duration` and
  /// `failed_step` itself.
  final Map<String, String> facts;

  /// Reports a message that could not be sent. Called at most once per
  /// distinct problem.
  final void Function(SlackException problem) warn;

  final DateTime Function() _clock;

  final List<ProgressStep> _steps = <ProgressStep>[];
  DateTime? _startedAt;
  DateTime? _finishedAt;
  SlackThread? _thread;

  /// Set once a progress edit fails. Later edits are cosmetic and would fail
  /// the same way, so they stop; the final message is still attempted.
  bool _progressBroken = false;

  final Set<String> _warned = <String>{};
  Future<void> _queue = Future<void>.value();
  int _pendingEdits = 0;

  /// The run has begun. [done] holds the keys a resume will skip.
  void begin(
    List<({String key, String label})> steps, {
    Set<String> done = const <String>{},
  }) {
    _startedAt = _clock();
    for (final step in steps) {
      _steps.add(
        ProgressStep(key: step.key, label: step.label)
          ..state = done.contains(step.key)
              ? StepState.skipped
              : StepState.pending,
      );
    }
    if (!config.on.contains(NotifyEvent.started)) return;
    _enqueue(() async {
      await _attempt(() async {
        _thread = await transport.post(_payload(NotifyEvent.started));
      });
    });
  }

  void stepStarted(String key) => _change(key, StepState.running);

  void stepSkipped(String key) => _change(key, StepState.skipped);

  void stepFinished(
    String key, {
    required bool succeeded,
    Duration? duration,
    int? exitCode,
  }) => _change(
    key,
    succeeded ? StepState.succeeded : StepState.failed,
    duration: duration,
    exitCode: succeeded ? null : exitCode,
  );

  /// The run is over. Completes once every message has been sent or given up
  /// on, so the process does not exit with one still in flight.
  Future<void> finish({required bool succeeded}) async {
    _finishedAt = _clock();
    for (final step in _steps) {
      if (step.state == StepState.pending || step.state == StepState.running) {
        step.state = StepState.notRun;
      }
    }

    final event = succeeded ? NotifyEvent.success : NotifyEvent.failure;
    final wanted = config.on.contains(event);

    _enqueue(() async {
      final thread = _thread;
      if (transport.live && thread != null) {
        // Edited whether or not this event was asked for: a status message
        // left saying "running" forever is worse than no message.
        final edited = await _attempt(
          () => transport.update(thread, _payload(event)),
        );
        if (!wanted) return;
        if (!edited) {
          await _attempt(() => transport.post(_payload(event)));
        } else if (!succeeded) {
          await _attempt(
            () => transport.reply(
              thread,
              SlackPayload(text: _headline(event)),
              broadcast: true,
            ),
          );
        }
        return;
      }
      if (wanted) await _attempt(() => transport.post(_payload(event)));
    });
    await _queue;
  }

  /// Completes when every message queued so far has been sent or given up on.
  Future<void> get idle => _queue;

  void _change(
    String key,
    StepState state, {
    Duration? duration,
    int? exitCode,
  }) {
    for (final step in _steps) {
      if (step.key != key) continue;
      step.state = state;
      if (duration != null) step.duration = duration;
      if (exitCode != null) step.exitCode = exitCode;
    }
    if (!transport.live || _progressBroken) return;

    // Coalesced: when several steps finish together only the newest edit is
    // sent, since each renders the whole list anyway.
    _pendingEdits++;
    _enqueue(() async {
      _pendingEdits--;
      final thread = _thread;
      if (_pendingEdits > 0 || thread == null || _progressBroken) return;
      final ok = await _attempt(
        () => transport.update(thread, _payload(NotifyEvent.started)),
      );
      if (!ok) _progressBroken = true;
    });
  }

  /// Tasks run one at a time, in order, so an edit never overtakes the post
  /// it edits. Anything a task throws — a bug, not a Slack answer — is a
  /// warning like the rest: it must not break the queue, or the release.
  void _enqueue(Future<void> Function() task) {
    _queue = _queue.then((_) async {
      try {
        await task();
      } on Object catch (error) {
        _warnOnce(SlackException('Could not send the notification: $error'));
      }
    });
  }

  void _warnOnce(SlackException problem) {
    if (_warned.add(problem.message)) warn(problem);
  }

  /// Runs [send], turning a failure into a warning. True when it worked.
  Future<bool> _attempt(Future<void> Function() send) async {
    try {
      await send();
      return true;
    } on SlackException catch (problem) {
      _warnOnce(problem);
      return false;
    }
  }

  SlackPayload _payload(NotifyEvent event) => SlackMessage.of(
    headline: _headline(event),
    tone: switch (event) {
      NotifyEvent.started => RunTone.running,
      NotifyEvent.success => RunTone.success,
      NotifyEvent.failure => RunTone.failure,
    },
    steps: _steps,
    footer: _footer(),
    runUrl: facts['run_url'],
  );

  String _headline(NotifyEvent event) => MessageTemplate.render(
    config.messages.of(event) ?? MessageTemplate.defaultFor(event),
    _values(event),
    escape: SlackMessage.escape,
  );

  Map<String, String> _values(NotifyEvent event) {
    final started = _startedAt;
    final ended = _finishedAt;
    final failed = _steps.where((s) => s.state == StepState.failed);
    return <String, String>{
      ...facts,
      'status': event.name,
      'duration': started == null || ended == null
          ? ''
          : SlackMessage.formatDuration(ended.difference(started)),
      'failed_step': failed.isEmpty ? '' : failed.first.label,
    };
  }

  /// `acme_app · main @ 1a2b3c4 · build-mac-2`, leaving out what is unknown.
  String _footer() =>
      <String?>[
            facts['project'],
            switch ((facts['branch'], facts['commit'])) {
              (final String branch, final String commit)
                  when branch.isNotEmpty && commit.isNotEmpty =>
                '$branch @ $commit',
              (final String branch, _) when branch.isNotEmpty => branch,
              _ => null,
            },
            facts['host'],
          ]
          .where((part) => part != null && part.isNotEmpty)
          .map((part) => SlackMessage.escape(part!))
          .join(' · ');
}
