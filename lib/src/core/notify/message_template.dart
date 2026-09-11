import '../config/shipway_config.dart';

/// `{placeholder}` substitution for notification text.
///
/// Deliberately not a template language. No conditionals, no loops, no
/// filters: a message is one line somebody reads in a channel, and the moment
/// it needs logic it belongs in a `run:` step instead.
abstract final class MessageTemplate {
  /// Every placeholder, with what it holds. Printed by the loader when a
  /// template names one that does not exist.
  static const Map<String, String> placeholders = <String, String>{
    'project': 'project.name from shipway.yaml',
    'name': 'the pipeline name, or "release <flavor> → <target>"',
    'status': 'started, success or failure',
    'duration': 'how long the run took, e.g. 4m 12s; empty when starting',
    'failed_step': 'the step that failed; empty unless it failed',
    'flavor': 'the flavor released; empty for a pipeline',
    'target': 'where it went: testflight, appstore, play, firebase',
    'platform': 'ios or android; empty for a pipeline',
    'version': 'the version name from pubspec.yaml',
    'branch': 'the git branch',
    'commit': 'the short commit hash',
    'host': 'the machine it ran on',
    'user': 'who ran it',
    'run_url': 'a link to the CI run, when there is one',
  };

  /// What each event says when the config does not say otherwise.
  static String defaultFor(NotifyEvent event) => switch (event) {
    NotifyEvent.started => '{project}: *{name}* started',
    NotifyEvent.success => '{project}: *{name}* finished in {duration}',
    NotifyEvent.failure => '{project}: *{name}* failed at {failed_step}',
  };

  static final RegExp _placeholder = RegExp(r'\{([a-z_]+)\}');

  /// Placeholders in [template] that do not exist.
  ///
  /// Checked when the config loads rather than when a message is sent, so
  /// `{falied_step}` fails in the second it takes to run a command rather than
  /// arriving in a channel, verbatim, after the release it was meant to report.
  static List<String> unknownIn(String template) => <String>[
    for (final match in _placeholder.allMatches(template))
      if (!placeholders.containsKey(match.group(1))) match.group(1)!,
  ];

  /// [template] with each placeholder replaced by its value in [values].
  ///
  /// A known placeholder with no value becomes empty. [escape] is applied to
  /// values only, never to the template: the template is the author's own
  /// markup, and a branch name is not.
  static String render(
    String template,
    Map<String, String> values, {
    String Function(String value)? escape,
  }) => template.replaceAllMapped(_placeholder, (match) {
    final name = match.group(1)!;
    if (!placeholders.containsKey(name)) return match.group(0)!;
    final value = values[name] ?? '';
    return escape == null ? value : escape(value);
  });
}
