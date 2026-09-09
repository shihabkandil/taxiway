import 'package:xml/xml.dart';

import 'generated_file.dart';

/// Writes a shared `.xcscheme` per flavor.
///
/// Derived from the project's own `Runner.xcscheme` rather than reconstructed.
/// A scheme references its target by `BlueprintIdentifier` — a `project.pbxproj`
/// UUID — and Flutter's schemes carry a `PreActions` step that runs
/// `xcode_backend.sh prepare`. A hand-built scheme missing either of those is
/// syntactically fine and does not build, so the only safe thing to write is a
/// copy of one that already works with the build configurations swapped.
///
/// Always written to `xcshareddata/xcschemes/`, never `xcuserdata`: a per-user
/// scheme is git-ignored and works only for its author.
class IosSchemeGenerator extends Generator {
  const IosSchemeGenerator();

  @override
  String get name => 'ios-schemes';

  @override
  String get description => 'A shared Xcode scheme per flavor.';

  static const String schemeDirectory =
      'ios/Runner.xcodeproj/xcshareddata/xcschemes';

  /// Every shared scheme except `Runner.xcscheme`, which is the project's own
  /// and is the template the rest are derived from.
  @override
  bool owns(String path) =>
      path.startsWith('$schemeDirectory/') &&
      path.endsWith('.xcscheme') &&
      path != '$schemeDirectory/Runner.xcscheme';

  /// A missing template means this generator could not run, not that the
  /// config stopped asking for schemes. Sweeping on that basis would delete
  /// every working scheme the moment the template became unreadable.
  @override
  bool canDetermineOwnership(ResolvedApp app) => app.iosSchemeTemplate != null;

  /// Which build configuration each scheme action should point at.
  static Map<String, String> configurationsFor(String flavor) =>
      <String, String>{
        'TestAction': 'Debug-$flavor',
        'LaunchAction': 'Debug-$flavor',
        'AnalyzeAction': 'Debug-$flavor',
        'ProfileAction': 'Profile-$flavor',
        'ArchiveAction': 'Release-$flavor',
      };

  @override
  List<GeneratedFile> render(ResolvedApp app) {
    final template = app.iosSchemeTemplate;
    if (template == null || !app.hasFlavors) return const <GeneratedFile>[];

    final files = <GeneratedFile>[];
    for (final flavor in app.flavors) {
      final scheme = rewrite(template, flavor.name);
      if (scheme == null) continue;
      files.add(
        GeneratedFile.full(
          path: '$schemeDirectory/${flavor.name}.xcscheme',
          contents: scheme,
          description: 'shared scheme for ${flavor.name}',
        ),
      );
    }
    return files;
  }

  /// Returns [template] with every action pointed at [flavor]'s
  /// configurations, or null if the template is not parseable XML.
  static String? rewrite(String template, String flavor) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(template);
    } on XmlException {
      return null;
    }

    final wanted = configurationsFor(flavor);
    for (final entry in wanted.entries) {
      for (final element in document.rootElement.findAllElements(entry.key)) {
        element.setAttribute('buildConfiguration', entry.value);
      }
    }

    // Xcode writes attributes one per line with three-space indentation; keep
    // that shape so a diff against a hand-made scheme stays readable.
    return '${document.toXmlString(pretty: false)}\n';
  }
}
