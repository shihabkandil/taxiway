import 'package:shipway/src/core/config/shipway_config.dart';
import 'package:shipway/src/core/io/http_poster.dart';
import 'package:shipway/src/notify/run_notifier.dart';
import 'package:shipway/src/notify/slack_client.dart';
import 'package:test/test.dart';

import '../../support/recording_http_poster.dart';

const List<({String key, String label})> _steps =
    <({String key, String label})>[
      (key: 'analyze', label: 'analyze'),
      (key: 'release:ios:prod:testflight', label: 'release prod → testflight'),
    ];

const Map<String, String> _facts = <String, String>{
  'project': 'acme_app',
  'name': 'beta',
  'branch': 'main',
  'commit': '1a2b3c4',
  'host': 'build-mac',
};

void main() {
  late RecordingHttpPoster http;
  late List<SlackException> warnings;

  setUp(() {
    http = RecordingHttpPoster();
    warnings = <SlackException>[];
  });

  SlackWebhook webhook() => SlackWebhook(
    url: Uri.parse('https://hooks.slack.com/services/T0/B0/secret'),
    http: http,
    refName: 'SLACK_WEBHOOK',
    sleep: (_) async {},
  );

  SlackBot bot() => SlackBot(
    token: 'xoxb-test',
    channel: '#releases',
    http: http,
    refName: 'SLACK_BOT_TOKEN',
    sleep: (_) async {},
  );

  RunNotifier notifier(
    SlackTransport transport, {
    Set<NotifyEvent> on = const <NotifyEvent>{NotifyEvent.failure},
    NotifyMessages messages = const NotifyMessages(),
    Map<String, String> facts = _facts,
  }) {
    var now = DateTime(2026, 9, 11, 10);
    return RunNotifier(
      transport: transport,
      config: NotifyConfig(on: on, messages: messages),
      facts: facts,
      warn: warnings.add,
      // Each reading is 30 seconds after the last, so durations are known.
      clock: () => now = now.add(const Duration(seconds: 30)),
    );
  }

  /// Plays a run where analyze passes and the release fails.
  Future<void> failingRun(RunNotifier n) async {
    n.begin(_steps);
    n.stepStarted('analyze');
    n.stepFinished(
      'analyze',
      succeeded: true,
      duration: const Duration(seconds: 12),
    );
    n.stepStarted(_steps.last.key);
    n.stepFinished(_steps.last.key, succeeded: false, exitCode: 69);
    await n.finish(succeeded: false);
  }

  group('through a webhook', () {
    test('the default says nothing about a run that worked', () async {
      final n = notifier(webhook())..begin(_steps);
      n.stepFinished('analyze', succeeded: true);
      n.stepFinished(_steps.last.key, succeeded: true);
      await n.finish(succeeded: true);

      expect(http.posts, isEmpty);
    });

    test('a failure is one message naming the step', () async {
      await failingRun(notifier(webhook()));

      expect(http.posts, hasLength(1));
      final body = http.posts.single.json;
      expect(
        body['text'],
        'acme_app: *beta* failed at release prod → testflight',
      );
      final attachment = (body['attachments'] as List).single as Map;
      expect(attachment['color'], '#E01E5A');
      expect(attachment['text'], contains('✓ analyze (12s)'));
      expect(attachment['text'], contains('✗ *release prod → testflight*'));
      expect(attachment['text'], contains('exit 69'));
      expect(attachment['footer'], 'acme_app · main @ 1a2b3c4 · build-mac');
    });

    test('each event asked for is its own message', () async {
      final n = notifier(
        webhook(),
        on: <NotifyEvent>{NotifyEvent.started, ...NotifyEvent.always},
      )..begin(_steps);
      await n.idle;
      await n.finish(succeeded: true);

      expect(http.posts.map((p) => p.json['text']), <String>[
        'acme_app: *beta* started',
        'acme_app: *beta* finished in 30s',
      ]);
    });

    test('custom messages replace the defaults', () async {
      final n = notifier(
        webhook(),
        on: NotifyEvent.always,
        messages: const NotifyMessages(
          success: 'Shipped {name} from {branch} ({status}, {duration})',
        ),
      )..begin(_steps);
      await n.finish(succeeded: true);

      expect(
        http.posts.single.json['text'],
        'Shipped beta from main (success, 30s)',
      );
    });

    test('values are escaped, the template is not', () async {
      // A branch is somebody else's text; the template is the author's own
      // markup, and `<!here>` in it has to reach Slack intact.
      final n = notifier(
        webhook(),
        messages: const NotifyMessages(failure: '<!here> {branch} broke'),
        facts: <String, String>{..._facts, 'branch': 'fix/<!channel>&co'},
      );
      await failingRun(n);

      expect(
        http.posts.single.json['text'],
        '<!here> fix/&lt;!channel&gt;&amp;co broke',
      );
    });

    test('a resumed run shows what an earlier run already did', () async {
      final n = notifier(webhook())..begin(_steps, done: <String>{'analyze'});
      n.stepFinished(_steps.last.key, succeeded: false, exitCode: 1);
      await n.finish(succeeded: false);

      final attachment =
          (http.posts.single.json['attachments'] as List).single as Map;
      expect(
        attachment['text'],
        contains('– analyze (done in an earlier run)'),
      );
    });

    test('steps a failure stopped are reported as not run', () async {
      final n = notifier(webhook())..begin(_steps);
      n.stepFinished('analyze', succeeded: false, exitCode: 1);
      await n.finish(succeeded: false);

      final attachment =
          (http.posts.single.json['attachments'] as List).single as Map;
      expect(
        attachment['text'],
        contains('· release prod → testflight (not run)'),
      );
    });
  });

  group('as a bot, live', () {
    test('posts once, then edits the same message as steps finish', () async {
      final n = notifier(
        bot(),
        on: <NotifyEvent>{NotifyEvent.started, NotifyEvent.success},
      )..begin(_steps);
      await n.idle;
      n.stepStarted('analyze');
      await n.idle;
      n.stepFinished('analyze', succeeded: true);
      await n.idle;
      await n.finish(succeeded: true);

      final methods = http.posts.map((p) => p.method).toList();
      expect(methods.first, 'chat.postMessage');
      expect(methods.skip(1), everyElement('chat.update'));
      // A success is an edit and nothing more: nobody needs pinging for it.
      expect(methods.where((m) => m == 'chat.postMessage'), hasLength(1));

      final last = http.posts.last.json;
      // The id Slack returned, not the configured `#name`, which
      // chat.update refuses.
      expect(last['channel'], 'C0RELEASES');
      expect(last['ts'], '1700000000.000100');
      expect(last['text'], contains('finished'));
      expect(http.posts.first.headers['Authorization'], 'Bearer xoxb-test');
    });

    test('a failure is also broadcast, because edits notify nobody', () async {
      await failingRun(
        notifier(
          bot(),
          on: <NotifyEvent>{NotifyEvent.started, NotifyEvent.failure},
        ),
      );

      final reply = http.posts.last.json;
      expect(http.posts.last.method, 'chat.postMessage');
      expect(reply['thread_ts'], '1700000000.000100');
      expect(reply['reply_broadcast'], isTrue);
      expect(reply['text'], contains('failed at release prod → testflight'));

      final edit = http.posts[http.posts.length - 2].json;
      expect(http.posts[http.posts.length - 2].method, 'chat.update');
      expect(((edit['attachments'] as List).single as Map)['color'], '#E01E5A');
    });

    test(
      'the message is finished even when that event was not asked for',
      () async {
        // Otherwise it says "running" in the channel forever.
        final n = notifier(
          bot(),
          on: <NotifyEvent>{NotifyEvent.started, NotifyEvent.failure},
        )..begin(_steps);
        await n.finish(succeeded: true);

        expect(http.posts.last.method, 'chat.update');
        expect(http.posts.last.json['text'], contains('finished'));
        expect(
          http.posts.where((p) => p.json['reply_broadcast'] == true),
          isEmpty,
        );
      },
    );

    test(
      'without started there is nothing to edit, so the end posts',
      () async {
        await failingRun(notifier(bot()));

        expect(http.posts, hasLength(1));
        expect(http.posts.single.method, 'chat.postMessage');
        expect(http.posts.single.json['thread_ts'], isNull);
      },
    );

    test('steps finishing together send one edit, not one each', () async {
      final n = notifier(bot(), on: <NotifyEvent>{NotifyEvent.started})
        ..begin(_steps);
      await n.idle;
      n
        ..stepStarted('analyze')
        ..stepStarted(_steps.last.key)
        ..stepFinished('analyze', succeeded: true);
      await n.idle;

      expect(http.posts.where((p) => p.method == 'chat.update'), hasLength(1));
    });
  });

  group('never fails a run', () {
    test('an unreachable Slack is a warning, said once', () async {
      http.replies.addAll(<Object>[
        const HttpPostException('could not reach hooks.slack.com'),
        const HttpPostException('could not reach hooks.slack.com'),
      ]);
      final n = notifier(
        webhook(),
        on: <NotifyEvent>{NotifyEvent.started, NotifyEvent.failure},
      );
      await failingRun(n);

      expect(warnings, hasLength(1));
      expect(warnings.single.message, contains('could not be reached'));
    });

    test('a revoked webhook says how to fix it', () async {
      http.replies.add(const HttpReply(statusCode: 404, body: 'no_service'));
      await failingRun(notifier(webhook()));

      expect(warnings.single.message, contains('SLACK_WEBHOOK'));
      expect(warnings.single.hint, contains('Create a new incoming webhook'));
    });

    test('a failed progress edit stops the edits but not the end', () async {
      http.replies.addAll(<Object>[
        HttpReply(
          statusCode: 200,
          body: '{"ok":true,"channel":"C1","ts":"1.0"}',
        ),
        const HttpReply(statusCode: 200, body: '{"ok":false,"error":"x"}'),
      ]);
      final n = notifier(
        bot(),
        on: <NotifyEvent>{NotifyEvent.started, NotifyEvent.failure},
      )..begin(_steps);
      await n.idle;
      n.stepFinished('analyze', succeeded: true);
      await n.idle;
      n.stepFinished(_steps.last.key, succeeded: false);
      await n.finish(succeeded: false);

      // post, the failed edit, then the final edit and the broadcast reply —
      // and no progress edit for the second step.
      expect(http.posts.map((p) => p.method), <String>[
        'chat.postMessage',
        'chat.update',
        'chat.update',
        'chat.postMessage',
      ]);
      expect(warnings, hasLength(1));
    });
  });
}
