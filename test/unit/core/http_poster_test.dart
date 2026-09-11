import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shipway/src/core/io/http_poster.dart';
import 'package:test/test.dart';

/// Against a real server on localhost: the point of this class is the socket
/// handling, which a fake would only restate.
void main() {
  late HttpServer server;
  late List<({String body, String? auth, String? type})> received;
  late FutureOr<void> Function(HttpRequest request) handler;

  setUp(() async {
    received = <({String body, String? auth, String? type})>[];
    handler = (request) {
      request.response
        ..statusCode = 200
        ..write('ok');
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      received.add((
        body: await utf8.decoder.bind(request).join(),
        auth: request.headers.value('authorization'),
        type: request.headers.contentType?.mimeType,
      ));
      await handler(request);
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  test('sends JSON with the headers asked for', () async {
    final reply = await SystemHttpPoster().postJson(
      url('/hook'),
      <String, Object>{'text': 'héllo'},
      headers: <String, String>{'Authorization': 'Bearer t'},
    );

    expect(reply.ok, isTrue);
    expect(reply.body, 'ok');
    expect(received.single.type, 'application/json');
    expect(received.single.auth, 'Bearer t');
    expect(jsonDecode(received.single.body), <String, Object>{'text': 'héllo'});
  });

  test('an error status is a reply, with Retry-After read', () async {
    handler = (request) {
      request.response
        ..statusCode = 429
        ..headers.set('Retry-After', '7')
        ..write('rate_limited');
    };
    final reply = await SystemHttpPoster().postJson(url('/hook'), 1);

    expect(reply.ok, isFalse);
    expect(reply.statusCode, 429);
    expect(reply.retryAfter, const Duration(seconds: 7));
  });

  test('a server that never answers times out without the path', () async {
    handler = (_) => Future<void>.delayed(const Duration(seconds: 5));
    final poster = SystemHttpPoster(timeout: const Duration(milliseconds: 200));

    await expectLater(
      poster.postJson(url('/services/T0/B0/secret'), 1),
      throwsA(
        isA<HttpPostException>()
            .having((e) => e.message, 'message', contains('127.0.0.1'))
            .having((e) => e.message, 'message', isNot(contains('secret'))),
      ),
    );
  });

  test('nothing listening is an HttpPostException', () async {
    final port = server.port;
    await server.close(force: true);

    await expectLater(
      SystemHttpPoster().postJson(
        Uri.parse('http://127.0.0.1:$port/services/T0/B0/secret'),
        1,
      ),
      throwsA(
        isA<HttpPostException>().having(
          (e) => e.message,
          'message',
          isNot(contains('secret')),
        ),
      ),
    );
  });
}
