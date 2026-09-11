import 'run_progress.dart';

/// One Slack message, in the shape both a webhook and `chat.postMessage`
/// accept.
class SlackPayload {
  const SlackPayload({required this.text, this.attachment});

  /// The headline: the rendered template. It is also what a phone shows in
  /// the notification, so it has to stand on its own.
  final String text;

  /// The coloured bar with the steps, or null for a bare reply.
  final Map<String, Object?>? attachment;

  Map<String, Object?> toJson() => <String, Object?>{
    'text': text,
    if (attachment != null) 'attachments': <Object?>[attachment],
  };
}

/// Where a run stands, which decides the colour of the bar.
enum RunTone {
  running('#1D9BD1'),
  success('#2EB67D'),
  failure('#E01E5A');

  const RunTone(this.color);

  final String color;
}

/// Builds the message a run is reported with.
///
/// A legacy attachment rather than Block Kit: it is the one shape that gives a
/// coloured status bar, and both a webhook and the Web API still accept it.
/// Red and green at a glance is most of what a release channel is for.
abstract final class SlackMessage {
  static SlackPayload of({
    required String headline,
    required RunTone tone,
    required List<ProgressStep> steps,
    required String footer,
    String? runUrl,
  }) {
    final lines = <String>[
      for (final step in steps) _line(step),
      if (runUrl != null && runUrl.isNotEmpty) '<$runUrl|Open the CI run>',
    ];
    return SlackPayload(
      text: headline,
      attachment: <String, Object?>{
        'color': tone.color,
        'text': lines.join('\n'),
        'footer': footer,
        'mrkdwn_in': const <String>['text'],
        // Shown by clients that cannot render attachments, and read aloud by
        // screen readers in place of the bar.
        'fallback': headline,
      },
    );
  }

  static String _line(ProgressStep step) {
    final label = escape(step.label);
    final took = step.duration == null ? '' : formatDuration(step.duration!);
    return switch (step.state) {
      StepState.succeeded => '✓ $label ($took)',
      StepState.failed =>
        '✗ *$label* (failed${took.isEmpty ? '' : ' after $took'}'
            '${step.exitCode == null ? '' : ', exit ${step.exitCode}'})',
      StepState.running => '▸ $label (running)',
      StepState.pending => '· $label',
      StepState.skipped => '– $label (done in an earlier run)',
      StepState.notRun => '· $label (not run)',
    };
  }

  /// Slack's three control characters.
  ///
  /// Applied to everything that did not come from the person who wrote the
  /// template — a branch called `fix/<thing>` would otherwise vanish, and one
  /// containing `<!channel>` would ping a whole workspace.
  static String escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// `38s`, `4m 12s`, `1h 3m`.
  static String formatDuration(Duration duration) {
    final seconds = duration.inSeconds;
    if (seconds < 60) return '${seconds}s';
    final minutes = duration.inMinutes;
    if (minutes < 60) return '${minutes}m ${seconds % 60}s';
    return '${duration.inHours}h ${minutes % 60}m';
  }
}
