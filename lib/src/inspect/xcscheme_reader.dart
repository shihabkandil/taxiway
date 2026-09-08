import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../core/model/ios_model.dart';

/// Reads `.xcscheme` files from both the shared and per-user locations.
///
/// Both are read on purpose. A scheme that exists only in `xcuserdata` is
/// git-ignored, so the flavor works for whoever created it and is missing for
/// everyone else on the team — a common and genuinely confusing bug that only a
/// reader looking in both places can report.
abstract final class XcschemeReader {
  static const String sharedDirectory = 'xcshareddata/xcschemes';

  /// Reads every scheme belonging to the project at [xcodeprojPath].
  ///
  /// A shared scheme wins over a user scheme of the same name, because that is
  /// what Xcode does.
  static Future<Map<String, IosScheme>> readAll(String xcodeprojPath) async {
    final schemes = <String, IosScheme>{};

    for (final scheme in await _readUserSchemes(xcodeprojPath)) {
      schemes[scheme.name] = scheme;
    }
    for (final scheme in await _readSharedSchemes(xcodeprojPath)) {
      schemes[scheme.name] = scheme;
    }
    return schemes;
  }

  static Future<List<IosScheme>> _readSharedSchemes(
    String xcodeprojPath,
  ) async {
    final dir = Directory(p.join(xcodeprojPath, sharedDirectory));
    if (!dir.existsSync()) return const <IosScheme>[];
    final schemes = <IosScheme>[];
    for (final file in _schemeFiles(dir)) {
      final scheme = await _parse(file, shared: true);
      if (scheme != null) schemes.add(scheme);
    }
    return schemes;
  }

  static Future<List<IosScheme>> _readUserSchemes(String xcodeprojPath) async {
    final userData = Directory(p.join(xcodeprojPath, 'xcuserdata'));
    if (!userData.existsSync()) return const <IosScheme>[];

    final schemes = <IosScheme>[];
    for (final owner in userData.listSync().whereType<Directory>()) {
      final dir = Directory(p.join(owner.path, 'xcschemes'));
      if (!dir.existsSync()) continue;
      for (final file in _schemeFiles(dir)) {
        final scheme = await _parse(
          file,
          shared: false,
          // `.../xcuserdata/alice.xcuserdatad/` -> `alice`.
          owner: p.basename(owner.path).replaceAll('.xcuserdatad', ''),
        );
        if (scheme != null) schemes.add(scheme);
      }
    }
    return schemes;
  }

  static Iterable<File> _schemeFiles(Directory dir) => dir
      .listSync()
      .whereType<File>()
      .where((f) => p.extension(f.path) == '.xcscheme');

  static Future<IosScheme?> _parse(
    File file, {
    required bool shared,
    String? owner,
  }) async {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(await file.readAsString());
    } on XmlException {
      // A malformed scheme is the user's problem to fix, but it must not take
      // the whole import down.
      return null;
    }

    final root = document.rootElement;
    return IosScheme(
      name: p.basenameWithoutExtension(file.path),
      shared: shared,
      owner: owner,
      buildConfiguration: _configurationOf(root, 'LaunchAction'),
      testConfiguration: _configurationOf(root, 'TestAction'),
      profileConfiguration: _configurationOf(root, 'ProfileAction'),
      archiveConfiguration: _configurationOf(root, 'ArchiveAction'),
    );
  }

  /// The `buildConfiguration` attribute of one action element.
  static String? _configurationOf(XmlElement root, String action) {
    for (final element in root.findAllElements(action)) {
      final value = element.getAttribute('buildConfiguration');
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }
}
