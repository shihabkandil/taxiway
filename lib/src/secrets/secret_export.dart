import 'repository_secrets.dart';

/// What shape `shipway secrets export` emits.
enum ExportFormat {
  /// A `gh secret set` script. Each line prompts for its value.
  gh,

  /// An Actions `env:` block, for a workflow shipway did not write.
  actions,

  /// A `.env` template with empty values, to fill in locally.
  dotenv;

  static ExportFormat? parse(String value) => switch (value.trim()) {
    'gh' => ExportFormat.gh,
    'actions' => ExportFormat.actions,
    'env' || 'dotenv' => ExportFormat.dotenv,
    _ => null,
  };

  static const List<String> names = <String>['gh', 'actions', 'env'];
}

/// Renders the names a CI repository needs, and only the names.
///
/// This is the half of the loop the generated workflow cannot close: it says
/// which variables it reads, but wiring them up is otherwise an exercise in
/// reading YAML and guessing. Every format here is a checklist, never a
/// transport — no value is read, so none can be written.
abstract final class SecretExport {
  static String render(
    List<RepositorySecret> secrets, {
    required ExportFormat format,
  }) {
    if (secrets.isEmpty) {
      return '# This config needs no repository secrets yet. Add signing or '
          'targets to\n# shipway.yaml and they will appear here.\n';
    }
    return switch (format) {
      ExportFormat.gh => _gh(secrets),
      ExportFormat.actions => _actions(secrets),
      ExportFormat.dotenv => _dotenv(secrets),
    };
  }

  /// `gh secret set NAME` with no value prompts for one and never echoes it,
  /// which is why the script is safe to keep, paste and re-run.
  static String _gh(List<RepositorySecret> secrets) => <String>[
    '#!/bin/sh',
    '# Set the repository secrets this project needs, from a checkout of',
    '# the repository the workflow lives in. Add --repo <owner/name> to',
    '# each line to target a different one.',
    '#',
    '# Every line prompts for its value. Nothing is stored in this file.',
    '',
    for (final secret in secrets) ...<String>[
      '# ${secret.wantedBy}',
      'gh secret set ${secret.name}',
      '',
    ],
  ].join('\n');

  static String _actions(List<RepositorySecret> secrets) => <String>[
    '# Paste under a job. Values come from repository secrets; the names',
    '# are what shipway checks for and what the lanes read.',
    'env:',
    for (final secret in secrets) ...<String>[
      '  # ${secret.wantedBy}',
      '  ${secret.name}: \${{ secrets.${secret.name} }}',
    ],
    '',
  ].join('\n');

  static String _dotenv(List<RepositorySecret> secrets) => <String>[
    '# Fill these in and keep the file out of git — `shipway generate`',
    '# adds it to .gitignore. `shipway secrets import` moves them into',
    '# the login keychain when you would rather not leave them on disk.',
    '',
    for (final secret in secrets) ...<String>[
      '# ${secret.wantedBy}',
      '${secret.name}=',
      '',
    ],
  ].join('\n');
}
