/// How a file spells a line comment.
///
/// Managed markers must be inert in the host file, so the marker text is fixed
/// but its wrapper is per-format.
enum CommentStyle {
  /// Gradle KTS/Groovy, Dart, Ruby-free config.
  doubleSlash('// ', ''),

  /// .gitignore, Ruby (Fastfile, Podfile), properties files, YAML.
  hash('# ', ''),

  /// .xcscheme, plists, any XML.
  xml('<!-- ', ' -->'),

  /// xcconfig files, which treat `//` as a comment but also as a path
  /// separator; `//` is still correct and is what Xcode itself writes.
  xcconfig('// ', '');

  const CommentStyle(this.open, this.close);

  final String open;
  final String close;

  String wrap(String text) => '$open$text$close';

  /// The style conventionally used for [path], by extension and filename.
  static CommentStyle forPath(String path) {
    final name = path.split('/').last;
    if (name == '.gitignore' || name == 'Fastfile' || name == 'Appfile') {
      return CommentStyle.hash;
    }
    if (name == 'Podfile' || name == 'Matchfile' || name == 'Gymfile') {
      return CommentStyle.hash;
    }
    if (name == 'Gemfile' || name == 'Pluginfile') return CommentStyle.hash;
    final dot = name.lastIndexOf('.');
    final ext = dot == -1 ? '' : name.substring(dot + 1);
    return switch (ext) {
      'gradle' ||
      'kts' ||
      'dart' ||
      'java' ||
      'kt' ||
      'swift' ||
      'pbxproj' => CommentStyle.doubleSlash,
      'xcconfig' => CommentStyle.xcconfig,
      'xml' || 'xcscheme' || 'plist' || 'html' => CommentStyle.xml,
      'yaml' || 'yml' || 'properties' || 'rb' || 'sh' => CommentStyle.hash,
      _ => CommentStyle.hash,
    };
  }
}
