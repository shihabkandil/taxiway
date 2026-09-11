import 'package:shipway/src/core/config/config_exception.dart';
import 'package:shipway/src/core/config/config_loader.dart';
import 'package:shipway/src/core/config/shipway_config.dart';
import 'package:shipway/src/core/notify/message_template.dart';
import 'package:shipway/src/inspect/config_writer.dart';
import 'package:test/test.dart';

String _config(String notify) =>
    '''
version: 1
project:
  name: acme_app
apps:
  main:
    path: .
notify:
$notify
''';

ShipwayConfig _parse(String notify) => ConfigLoader.parse(_config(notify));

Matcher _refusedWith(String text) => throwsA(
  isA<ConfigException>().having((e) => e.toString(), 'message', contains(text)),
);

void main() {
  group('on', () {
    test('defaults to failure only', () {
      expect(
        _parse('  slack_webhook_ref: SLACK_WEBHOOK').notify.on,
        <NotifyEvent>{NotifyEvent.failure},
      );
    });

    test('takes a single word, as it always has', () {
      expect(
        _parse('  slack_webhook_ref: W\n  on: success').notify.on,
        <NotifyEvent>{NotifyEvent.success},
      );
      expect(
        _parse('  slack_webhook_ref: W\n  on: always').notify.on,
        NotifyEvent.always,
      );
    });

    test('takes a list, which is how started is switched on', () {
      expect(
        _parse('  slack_webhook_ref: W\n  on: [started, failure]').notify.on,
        <NotifyEvent>{NotifyEvent.started, NotifyEvent.failure},
      );
    });

    test('an unknown event names the real ones', () {
      expect(
        () => _parse('  slack_webhook_ref: W\n  on: [failed]'),
        _refusedWith('always, success, failure or started'),
      );
    });

    test('an empty list is refused rather than silently sending nothing', () {
      expect(
        () => _parse('  slack_webhook_ref: W\n  on: []'),
        _refusedWith('empty list'),
      );
    });
  });

  group('slack settings that could only fail later', () {
    test('a bot token with no channel', () {
      expect(
        () => _parse('  slack_bot_token_ref: SLACK_BOT_TOKEN'),
        _refusedWith('slack_channel'),
      );
    });

    test('a channel a webhook would ignore', () {
      expect(
        () => _parse('  slack_webhook_ref: W\n  slack_channel: C1'),
        _refusedWith('always posts to the channel it was created for'),
      );
    });

    test('messages with nowhere to go', () {
      expect(
        () => _parse('  messages:\n    failure: broke'),
        _refusedWith('nowhere to send them'),
      );
    });

    test('a bot token pasted where its name belongs', () {
      // The secret check runs first: a missing channel is the lesser problem.
      expect(
        () => _parse('  slack_bot_token_ref: xoxb-1234-abcd'),
        _refusedWith('that is the secret itself'),
      );
    });
  });

  group('messages', () {
    test('a misspelt placeholder fails at load, naming the real ones', () {
      expect(
        () => _parse(
          '  slack_webhook_ref: W\n'
          '  messages:\n'
          '    failure: "{name} failed at {falied_step}"',
        ),
        allOf(_refusedWith('{falied_step}'), _refusedWith('{failed_step}')),
      );
    });

    test('every default uses only placeholders that exist', () {
      for (final event in NotifyEvent.values) {
        expect(
          MessageTemplate.unknownIn(MessageTemplate.defaultFor(event)),
          isEmpty,
        );
      }
    });

    test('braces that are not placeholders are left alone', () {
      expect(MessageTemplate.unknownIn('see {Build 12} or {}'), isEmpty);
      expect(
        MessageTemplate.render('{Build} {name}', <String, String>{'name': 'x'}),
        '{Build} x',
      );
    });
  });

  group('written back by import', () {
    test('a full notify block survives a round trip', () {
      final original = _parse(r'''
  slack_webhook_ref: SLACK_WEBHOOK
  slack_bot_token_ref: SLACK_BOT_TOKEN
  slack_channel: "#releases"
  on: [started, failure]
  messages:
    started: "*{name}* is on its way"
    failure: "<!here> {name} failed: {failed_step}\nsee {run_url}"''');

      final written = ConfigWriter.render(
        original,
        generatedBy: 'test',
        generatedAt: DateTime(2026),
      );
      final reread = ConfigLoader.parse(written);

      expect(reread.notify.toJson(), original.notify.toJson());
      expect(written, contains('on: [started, failure]'));
    });

    test('the default on is not written out', () {
      final written = ConfigWriter.render(
        _parse('  slack_webhook_ref: SLACK_WEBHOOK'),
        generatedBy: 'test',
        generatedAt: DateTime(2026),
      );
      expect(written, isNot(contains('\n  on:')));
    });
  });
}
