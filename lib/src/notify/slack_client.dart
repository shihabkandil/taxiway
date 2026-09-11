import 'dart:convert';

import '../core/io/http_poster.dart';
import 'slack_message.dart';

/// A message Slack could not take, said the way the rest of shipway says
/// things: what happened, then what to change.
class SlackException implements Exception {
  const SlackException(this.message, {this.hint});

  final String message;
  final String? hint;

  @override
  String toString() => hint == null ? message : '$message\n$hint';
}

/// A message already in a channel, so it can be edited or replied to.
class SlackThread {
  const SlackThread({required this.channel, required this.ts});

  /// Always the channel id. `chat.update` refuses a `#name`, so the id Slack
  /// returns from the first post is kept rather than the configured value.
  final String channel;
  final String ts;
}

/// Somewhere a run can be reported to.
abstract class SlackTransport {
  /// Whether a posted message can be edited afterwards.
  bool get live;

  /// Posts a new message. Returns the thread when [live], null otherwise.
  Future<SlackThread?> post(SlackPayload payload);

  /// Replaces a message posted earlier. Only called when [live].
  Future<void> update(SlackThread thread, SlackPayload payload);

  /// Replies under a message posted earlier. Only called when [live].
  ///
  /// [broadcast] also shows the reply in the channel, which is the only way to
  /// make an update notify anybody: Slack does not notify on edits, not even
  /// for a mention the edit adds.
  Future<void> reply(
    SlackThread thread,
    SlackPayload payload, {
    bool broadcast = false,
  });
}

typedef Sleep = Future<void> Function(Duration duration);

Future<void> _realSleep(Duration duration) => Future<void>.delayed(duration);

/// Rate limits are the one failure worth waiting out, and only briefly: the
/// longest Slack asks for is still shorter than a stuck release.
Future<HttpReply> _withRetry(
  Future<HttpReply> Function() send,
  Sleep sleep,
) async {
  final HttpReply first;
  try {
    first = await send();
    if (first.statusCode != 429) return first;
    final wait = first.retryAfter ?? const Duration(seconds: 1);
    await sleep(wait > _maxWait ? _maxWait : wait);
    return await send();
  } on HttpPostException catch (e) {
    throw SlackException(
      'Slack could not be reached: ${e.message}.',
      hint: 'The release itself is unaffected.',
    );
  }
}

const Duration _maxWait = Duration(seconds: 10);

/// An incoming webhook: a URL that posts to one channel.
///
/// Cannot edit, cannot reply — a webhook has no way to address a message it
/// already sent. That is the whole reason [SlackBot] exists.
class SlackWebhook implements SlackTransport {
  SlackWebhook({
    required this.url,
    required this.http,
    required this.refName,
    Sleep? sleep,
  }) : _sleep = sleep ?? _realSleep;

  final Uri url;
  final HttpPoster http;

  /// The secret's name, for hints. Never the URL: its path is the credential.
  final String refName;

  final Sleep _sleep;

  @override
  bool get live => false;

  @override
  Future<SlackThread?> post(SlackPayload payload) async {
    final reply = await _withRetry(
      () => http.postJson(url, payload.toJson()),
      _sleep,
    );
    if (reply.ok) return null;
    throw _explain(reply);
  }

  @override
  Future<void> update(SlackThread thread, SlackPayload payload) =>
      throw UnsupportedError('A webhook cannot edit a message.');

  @override
  Future<void> reply(
    SlackThread thread,
    SlackPayload payload, {
    bool broadcast = false,
  }) => throw UnsupportedError('A webhook cannot reply to a message.');

  /// A webhook answers with a bare error code in the body.
  SlackException _explain(HttpReply reply) {
    final code = reply.body.trim();
    return switch (code) {
      'no_service' || 'invalid_token' || 'no_team' => SlackException(
        'Slack does not recognise the webhook in $refName.',
        hint:
            'It was revoked, or the app that owns it was removed. Create a new '
            'incoming webhook and update $refName.',
      ),
      'channel_not_found' => SlackException(
        'The channel the webhook in $refName posts to no longer exists.',
        hint: 'Create a webhook for a channel that does, and update $refName.',
      ),
      'channel_is_archived' => SlackException(
        'The channel the webhook in $refName posts to is archived.',
        hint: 'Unarchive it, or create a webhook for another channel.',
      ),
      'action_prohibited' ||
      'posting_to_general_channel_denied' => SlackException(
        'A workspace admin has restricted posting from this webhook.',
        hint: 'Ask an admin, or use a webhook for another channel.',
      ),
      'invalid_payload' ||
      'no_text' ||
      'too_many_attachments' => SlackException(
        'Slack rejected the message ($code).',
        hint:
            'Check notify.messages for anything unusual. If they look fine, '
            'this is a shipway bug worth reporting.',
      ),
      _ when reply.statusCode == 429 => const SlackException(
        'Slack is rate limiting this webhook.',
        hint: 'Too many messages in a short time. This one was dropped.',
      ),
      _ => SlackException(
        'Slack answered HTTP ${reply.statusCode}'
        '${code.isEmpty || code.length > 80 ? '' : ' ($code)'}.',
      ),
    };
  }
}

/// A bot token: posts as an app, and can edit and reply to its own messages.
class SlackBot implements SlackTransport {
  SlackBot({
    required this.token,
    required this.channel,
    required this.http,
    required this.refName,
    Sleep? sleep,
    Uri? api,
  }) : _sleep = sleep ?? _realSleep,
       api = api ?? Uri.parse('https://slack.com/api/');

  final String token;

  /// As configured: an id, or `#name`.
  final String channel;

  final HttpPoster http;
  final String refName;
  final Uri api;
  final Sleep _sleep;

  @override
  bool get live => true;

  @override
  Future<SlackThread?> post(SlackPayload payload) async {
    final answer = await _call('chat.postMessage', <String, Object?>{
      'channel': channel,
      ...payload.toJson(),
    });
    return SlackThread(
      channel: answer['channel']?.toString() ?? channel,
      ts: answer['ts']?.toString() ?? '',
    );
  }

  @override
  Future<void> update(SlackThread thread, SlackPayload payload) =>
      _call('chat.update', <String, Object?>{
        'channel': thread.channel,
        'ts': thread.ts,
        // An update replaces the attachments wholesale; leaving the key out
        // would keep the old bar, still saying "running".
        'attachments': const <Object?>[],
        ...payload.toJson(),
      });

  @override
  Future<void> reply(
    SlackThread thread,
    SlackPayload payload, {
    bool broadcast = false,
  }) => _call('chat.postMessage', <String, Object?>{
    'channel': thread.channel,
    'thread_ts': thread.ts,
    if (broadcast) 'reply_broadcast': true,
    ...payload.toJson(),
  });

  Future<Map<String, Object?>> _call(
    String method,
    Map<String, Object?> body,
  ) async {
    final reply = await _withRetry(
      () => http.postJson(
        api.resolve(method),
        body,
        headers: <String, String>{'Authorization': 'Bearer $token'},
      ),
      _sleep,
    );
    if (reply.statusCode == 429) {
      throw const SlackException(
        'Slack is rate limiting this app.',
        hint: 'Too many messages in a short time. This one was dropped.',
      );
    }
    if (!reply.ok) {
      throw SlackException('Slack answered HTTP ${reply.statusCode}.');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(reply.body);
    } on FormatException {
      throw const SlackException('Slack answered with something unreadable.');
    }
    if (decoded is! Map) {
      throw const SlackException('Slack answered with something unreadable.');
    }
    final answer = decoded.cast<String, Object?>();
    // The Web API answers 200 either way; the verdict is in the body.
    if (answer['ok'] == true) return answer;
    throw _explain(answer['error']?.toString() ?? 'unknown_error');
  }

  SlackException _explain(String code) => switch (code) {
    'not_authed' ||
    'invalid_auth' ||
    'token_revoked' ||
    'token_expired' ||
    'account_inactive' => SlackException(
      'Slack did not accept the token in $refName ($code).',
      hint:
          'It should be the bot token of an installed app, starting xoxb-. '
          'Reinstalling an app issues a new one.',
    ),
    'channel_not_found' => SlackException(
      'Slack cannot find the channel "$channel".',
      hint:
          'Use the channel id, the C… at the end of the channel link. A '
          'private channel is invisible to the app until it is invited.',
    ),
    'not_in_channel' => SlackException(
      'The app is not a member of "$channel".',
      hint: 'Invite it: type /invite @your-app-name in that channel.',
    ),
    'missing_scope' => SlackException(
      'The token in $refName cannot post messages.',
      hint: 'Add the chat:write scope to the app, then reinstall it.',
    ),
    'is_archived' => SlackException(
      '"$channel" is archived.',
      hint: 'Unarchive it, or point notify.slack_channel somewhere else.',
    ),
    'msg_too_long' => const SlackException(
      'The message is longer than Slack allows.',
      hint: 'Shorten notify.messages.',
    ),
    'message_not_found' || 'cant_update_message' => const SlackException(
      'The status message was deleted, so it could not be updated.',
    ),
    _ => SlackException('Slack refused the message ($code).'),
  };
}
