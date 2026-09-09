import 'dart:io';

import 'package:path/path.dart' as p;

import '../model/android_model.dart';

/// Where Gradle files live in a Flutter project.
///
/// Pure path knowledge, shared by the readers, the writers and `doctor`. It
/// lives in `core` because all three need it and none of them owns it.
abstract final class GradleLayout {
  /// The app module, which is where flavors are declared.
  static const String appModule = 'android/app';

  static const String wrapperProperties =
      'android/gradle/wrapper/gradle-wrapper.properties';

  /// Locates the app build file, preferring Kotlin when both somehow exist.
  static ({GradleDsl dsl, String path})? locateBuildFile(String root) {
    for (final dsl in <GradleDsl>[GradleDsl.kotlin, GradleDsl.groovy]) {
      final relative = p.posix.join(appModule, dsl.buildFileName);
      if (File(p.join(root, relative)).existsSync()) {
        return (dsl: dsl, path: relative);
      }
    }
    return null;
  }

  /// The dialect this project uses, defaulting to Kotlin for a project that has
  /// no Android module yet — which is what `flutter create` now writes.
  static GradleDsl dslFor(String root) =>
      locateBuildFile(root)?.dsl ?? GradleDsl.kotlin;
}
