import 'dart:convert';

/// Replaces known secret values with [mask] in anything on its way to a user.
///
/// Registered *before* a process runs, so a credential echoed by a subprocess
/// never reaches the terminal, a log file, or a captured [ProcessResultLite].
/// Registration is deliberately generous: a value is stored alongside the
/// encodings it is likely to be re-emitted in, because the leak is rarely the
/// literal string we handed out.
class Redactor {
  Redactor({this.mask = '***'});

  /// The replacement written in place of a secret.
  final String mask;

  /// Values to scrub, longest first so overlapping secrets redact maximally.
  final List<String> _values = <String>[];

  /// Values shorter than this are ignored. A three-character "secret" matches
  /// so much ordinary output that redacting it would hide the log instead of
  /// the credential.
  static const int minLength = 4;

  /// A PEM body line short enough to be a coincidence is not worth matching.
  static const int minPemFragment = 12;

  /// Longest registered value; the stream transformer holds back this much
  /// text so a secret split across two chunks is still caught.
  int get longest => _values.isEmpty ? 0 : _values.first.length;

  bool get isEmpty => _values.isEmpty;

  /// Registers [secret] and the forms it is likely to reappear in: raw, base64,
  /// URL-encoded, and — for PEM-shaped input — the body and each body line.
  void register(String? secret) {
    if (secret == null) return;
    final trimmed = secret.trim();
    if (trimmed.length < minLength) return;

    _add(trimmed);
    _add(base64.encode(utf8.encode(trimmed)));
    _add(Uri.encodeComponent(trimmed));
    _registerPemForms(trimmed);
  }

  void registerAll(Iterable<String?> secrets) => secrets.forEach(register);

  /// A PEM leaks in pieces: a log may print one wrapped body line rather than
  /// the whole key, so each line is a target in its own right.
  void _registerPemForms(String value) {
    if (!value.contains('-----BEGIN')) return;
    final body = value
        .split('\n')
        .where((l) => !l.startsWith('-----'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (body.isEmpty) return;
    _add(body.join());
    for (final line in body) {
      if (line.length >= minPemFragment) _add(line);
    }
  }

  void _add(String value) {
    if (value.length < minLength || _values.contains(value)) return;
    _values
      ..add(value)
      ..sort((a, b) => b.length.compareTo(a.length));
  }

  /// Returns [input] with every registered value replaced by [mask].
  String redact(String input) {
    if (_values.isEmpty || input.isEmpty) return input;
    var out = input;
    for (final value in _values) {
      if (out.contains(value)) out = out.replaceAll(value, mask);
    }
    return out;
  }

  /// Redacts a stream of arbitrarily-chunked text.
  ///
  /// A secret straddling a chunk boundary is the bug this class would otherwise
  /// have, so emission lags by [longest] - 1 characters: enough to reassemble
  /// any registered value before deciding what is safe to release.
  Stream<String> redactStream(Stream<String> chunks) async* {
    if (_values.isEmpty) {
      yield* chunks;
      return;
    }
    final holdback = longest - 1;
    var buffer = '';
    await for (final chunk in chunks) {
      // Redact the whole buffer *before* deciding what to release: a secret
      // straddling the boundary is only visible while both halves are present.
      buffer = redact(buffer + chunk);
      if (buffer.length <= holdback) continue;
      final cut = buffer.length - holdback;
      yield buffer.substring(0, cut);
      // The retained tail is already-scanned text. Anything left in it is not a
      // complete secret, so it is safe to re-scan once the next chunk arrives.
      buffer = buffer.substring(cut);
    }
    if (buffer.isNotEmpty) yield redact(buffer);
  }
}
