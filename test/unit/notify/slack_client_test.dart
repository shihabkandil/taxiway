import 'package:shipway/src/core/io/http_poster.dart';
import 'package:shipway/src/notify/slack_client.dart';
import 'package:shipway/src/notify/slack_message.dart';
import 'package:test/test.dart';

import '../../support/recording_http_poster.dart';

void main() {
  late RecordingHttpPoster http;
  late List<Duration> slept;

  setUp(() {
    http = RecordingHttpPoster();
    slept = <Duration>[];
  });

  const payload = SlackPayload(text: 'hello');

  SlackWebhook webhook() => SlackWebhook(
    url: Uri.parse('https://hooks.slack.com/services/T0/B0/secret'),
    http: http,
    refName: 'SLACK_WEBHOOK',
    sleep: (d) async => slept.add(d),
  );

  SlackBot bot() => SlackBot(
    token: 'xoxb-test',
    channel: '#releases',
    http: http,
    refName: 'SLACK_BOT_TOKEN',
    sleep: (d) async => slept.add(d),
  );

  Future<SlackException> refusal(Future<Object?> Function() send) async {
    try {
      await send();
    } on SlackException catch (e) {
      return e;
    }
    fail('expected a SlackException');
  }

  group('webhook', () {
    test('posts the payload to the URL it was given', () async {
      await webhook().post(payload);
      expect(http.posts.single.url.path, '/services/T0/B0/secret');
      expect(http.posts.single.json, <String, Object>{'text': 'hello'});
    });

    test('Slack error codes become a sentence and a fix', () async {
      final cases = <String, String>{
        'no_service': 'Create a new incoming webhook',
        'channel_is_archived': 'Unarchive it',
        'action_prohibited': 'Ask an admin',
        'invalid_payload': 'shipway bug',
      };
      for (final entry in cases.entries) {
        http.replies.add(HttpReply(statusCode: 400, body: entry.key));
        final e = await refusal(() => webhook().post(payload));
        expect(e.hint, contains(entry.value), reason: entry.key);
      }
    });

    test('never repeats the URL, whose path is the credential', () async {
      http.replies.add(const HttpReply(statusCode: 404, body: 'no_service'));
      final e = await refusal(() => webhook().post(payload));
      expect(e.toString(), isNot(contains('secret')));
      expect(e.toString(), contains('SLACK_WEBHOOK'));
    });

    test('waits out one rate limit, briefly', () async {
      http.replies.addAll(<Object>[
        const HttpReply(
          statusCode: 429,
          body: 'rate_limited',
          retryAfter: Duration(seconds: 90),
        ),
        const HttpReply(statusCode: 200, body: 'ok'),
      ]);
      await webhook().post(payload);
      expect(http.posts, hasLength(2));
      // Capped: a release is not held for a minute and a half over a message.
      expect(slept, <Duration>[const Duration(seconds: 10)]);
    });

    test('gives up after the second rate limit', () async {
      http.replies.addAll(<Object>[
        const HttpReply(statusCode: 429, body: 'rate_limited'),
        const HttpReply(statusCode: 429, body: 'rate_limited'),
      ]);
      final e = await refusal(() => webhook().post(payload));
      expect(e.message, contains('rate limiting'));
      expect(http.posts, hasLength(2));
    });

    test('no network is a SlackException, not a crash', () async {
      http.replies.add(const HttpPostException('could not reach x'));
      final e = await refusal(() => webhook().post(payload));
      expect(e.message, contains('could not be reached'));
    });
  });

  group('bot', () {
    test('reads the verdict from the body, since it is always 200', () async {
      final cases = <String, String>{
        'invalid_auth': 'xoxb-',
        'channel_not_found': 'channel id',
        'not_in_channel': '/invite',
        'missing_scope': 'chat:write',
      };
      for (final entry in cases.entries) {
        http.replies.add(
          HttpReply(
            statusCode: 200,
            body: '{"ok":false,"error":"${entry.key}"}',
          ),
        );
        final e = await refusal(() => bot().post(payload));
        expect(e.hint, contains(entry.value), reason: entry.key);
      }
    });

    test(
      'an update clears the old bar when the new message has none',
      () async {
        await bot().update(
          const SlackThread(channel: 'C1', ts: '1.0'),
          payload,
        );
        final body = http.posts.single.json;
        expect(http.posts.single.method, 'chat.update');
        expect(body['attachments'], isEmpty);
        expect(body['channel'], 'C1');
      },
    );

    test('never puts the token anywhere but the header', () async {
      http.replies.add(
        const HttpReply(
          statusCode: 200,
          body: '{"ok":false,"error":"invalid_auth"}',
        ),
      );
      final e = await refusal(() => bot().post(payload));
      expect(e.toString(), isNot(contains('xoxb-test')));
      expect(http.posts.single.json.toString(), isNot(contains('xoxb-test')));
    });

    test('something that is not JSON is reported, not thrown raw', () async {
      http.replies.add(const HttpReply(statusCode: 200, body: '<html>'));
      final e = await refusal(() => bot().post(payload));
      expect(e.message, contains('unreadable'));
    });
  });
}
