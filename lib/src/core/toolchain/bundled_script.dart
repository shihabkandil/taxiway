import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// Finds a script shipway ships beside its Dart code, such as
/// `tool/ruby/xcodeproj_bridge.rb`.
///
/// The package root comes from the package config, not from
/// `Platform.script`. Under `dart pub global activate` the script is a
/// precompiled snapshot in `global_packages/`, nowhere near the package
/// source, so the old `dirname(dirname(Platform.script))` guess found nothing
/// on every installed copy. The package config points at the real source
/// directory for hosted, git and path installs alike.
///
/// [packageRoot] wins when given, which is how tests pin a checkout. The
/// working directory is tried last, for running from a clone of this repo.
String? locateBundledScript(String relative, {String? packageRoot}) {
  final candidates = <String>[
    if (packageRoot != null) p.join(packageRoot, relative),
    if (shipwayPackageRoot() case final root?) p.join(root, relative),
    p.join(Directory.current.path, relative),
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return p.normalize(candidate);
  }
  return null;
}

/// The directory holding shipway's `pubspec.yaml`, or null when it cannot be
/// resolved — an AOT-compiled binary has no package config to ask.
String? shipwayPackageRoot() {
  final Uri? lib;
  try {
    lib = Isolate.resolvePackageUriSync(Uri.parse('package:shipway/'));
  } on UnsupportedError {
    return null;
  }
  if (lib == null || lib.scheme != 'file') return null;
  return p.dirname(p.normalize(lib.toFilePath()));
}
