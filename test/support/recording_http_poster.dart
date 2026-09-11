import 'dart:convert';

import 'package:shipway/src/core/io/http_poster.dart';

/// One captured POST.
class RecordedPost {
  RecordedPost(this.url, this.body, this.headers);

  final Uri url;
  final Object body;
  final Map<String, String> headers;

  /// The body as the JSON a server would have received.
  Map<String, dynamic> get json =>
      jsonDecode(jsonEncode(body)) as Map<String, dynamic>;

  String get method => url.pathSegments.isEmpty ? '' : url.pathSegments.last;
}

/// An [HttpPoster] that sends nothing and remembers everything.
///
/// Answers `ok` by default — the body a webhook returns — and a Web API
/// success with a channel id and timestamp for anything under `/api/`, so a
/// test states only the replies it cares about.
class RecordingHttpPoster implements HttpPoster {
  final List<RecordedPost> posts = <RecordedPost>[];

  /// Answers in order before falling back to the defaults. An entry that is an
  /// [HttpPostException] is thrown instead.
  final List<Object> replies = <Object>[];

  @override
  Future<HttpReply> postJson(
    Uri url,
    Object body, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    posts.add(RecordedPost(url, body, headers));
    if (replies.isNotEmpty) {
      final next = replies.removeAt(0);
      if (next is HttpPostException) throw next;
      return next as HttpReply;
    }
    if (url.path.contains('/api/')) {
      return HttpReply(
        statusCode: 200,
        body: jsonEncode(<String, Object>{
          'ok': true,
          'channel': 'C0RELEASES',
          'ts': '1700000000.000100',
        }),
      );
    }
    return const HttpReply(statusCode: 200, body: 'ok');
  }
}
