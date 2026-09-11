import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipway/src/core/toolchain/bundled_script.dart';
import 'package:shipway/src/inspect/gradle_deep_reader.dart';
import 'package:shipway/src/inspect/xcodeproj_bridge.dart';
import 'package:test/test.dart';

void main() {
  test('the package root comes from the package config', () {
    // The test runner resolves `package:shipway` to this checkout, the same
    // way `pub global activate` resolves it to the copy in the pub cache.
    final root = shipwayPackageRoot();
    expect(root, isNotNull);
    expect(File(p.join(root!, 'pubspec.yaml')).existsSync(), isTrue);
    expect(p.equals(root, Directory.current.path), isTrue);
  });

  test('the scripts are found from any working directory', () async {
    final elsewhere = await Directory.systemTemp.createTemp('shipway_cwd');
    addTearDown(() => elsewhere.delete(recursive: true));
    final original = Directory.current;
    Directory.current = elsewhere;
    addTearDown(() => Directory.current = original);

    // Before, these leaned on the working directory and on
    // `dirname(dirname(Platform.script))`, which under `pub global activate`
    // is a snapshot directory holding no `tool/` at all.
    expect(XcodeprojBridge.locateScript(), endsWith('xcodeproj_bridge.rb'));
    expect(GradleDeepReader.locateScript(), endsWith('shipway_dump.gradle'));
  });
}
