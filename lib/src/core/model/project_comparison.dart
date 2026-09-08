import 'model_diff.dart';
import 'project_model.dart';

/// Compares two project models semantically.
///
/// Both directions meet here: `compare(projectFromConfig(config),
/// readFromDisk())` is what `status` reports and what `adopt` shows before it
/// takes ownership of anything.
///
/// [expected] is the model derived from `taxiway.yaml`; [actual] is what is on
/// disk. Only fields the config can express are compared — a build setting
/// taxiway has no opinion about is not drift, and reporting it as such would
/// bury the differences that matter.
ModelDiff compare(ProjectModel expected, ProjectModel actual) {
  final diff = DiffBuilder();

  _compareFlavors(diff, expected, actual);
  _compareAndroid(diff, expected, actual);
  _compareIos(diff, expected, actual);
  _compareEntrypoints(diff, expected, actual);

  return diff.build();
}

void _compareFlavors(
  DiffBuilder diff,
  ProjectModel expected,
  ProjectModel actual,
) {
  // Compared per platform rather than as one set, because a flavor present on
  // Android and missing on iOS is a different problem from one missing
  // entirely, and the user fixes them in different places.
  if (expected.android.exists && actual.android.exists) {
    diff.names(
      'android.flavors',
      expected.androidFlavors,
      actual.androidFlavors,
    );
  }
  if (expected.ios.exists && actual.ios.exists) {
    diff.names('ios.flavors', expected.iosFlavors, actual.iosFlavors);
  }
}

void _compareAndroid(
  DiffBuilder diff,
  ProjectModel expected,
  ProjectModel actual,
) {
  if (!expected.android.exists || !actual.android.exists) return;

  diff.value(
    'android.applicationId',
    expected.android.applicationId,
    actual.android.applicationId,
  );

  for (final name in expected.androidFlavors.intersection(
    actual.androidFlavors,
  )) {
    final want = expected.android.flavors[name]!;
    final have = actual.android.flavors[name]!;
    diff
      ..value(
        'android.flavors.$name.applicationIdSuffix',
        want.applicationIdSuffix,
        have.applicationIdSuffix,
      )
      ..value(
        'android.flavors.$name.versionNameSuffix',
        want.versionNameSuffix,
        have.versionNameSuffix,
      )
      ..value('android.flavors.$name.dimension', want.dimension, have.dimension)
      ..value(
        'android.flavors.$name.app_name',
        want.resValues['app_name'],
        have.resValues['app_name'],
      );
  }
}

void _compareIos(DiffBuilder diff, ProjectModel expected, ProjectModel actual) {
  if (!expected.ios.exists || !actual.ios.exists) return;

  final wantTarget = expected.ios.applicationTarget;
  final haveTarget = actual.ios.applicationTarget;
  if (wantTarget == null || haveTarget == null) return;

  for (final flavor in expected.iosFlavors.intersection(actual.iosFlavors)) {
    for (final buildType in flutterBuildTypes) {
      final name = '$buildType-$flavor';
      final want = wantTarget.buildConfigurations[name];
      final have = haveTarget.buildConfigurations[name];
      if (want == null || have == null) continue;
      diff.value(
        'ios.$name.bundleIdentifier',
        want.bundleIdentifier,
        have.bundleIdentifier,
      );
    }
  }

  // A scheme that stopped being shared is silent drift: the project still
  // builds for whoever has it locally.
  for (final name in expected.ios.schemes.keys) {
    final have = actual.ios.schemes[name];
    if (have == null) {
      diff.value('ios.schemes.$name', name, null);
      continue;
    }
    if (!have.shared) {
      diff.add(
        ModelChange(
          path: 'ios.schemes.$name.shared',
          kind: ChangeKind.different,
          expected: 'shared',
          actual: 'xcuserdata only',
          note: 'per-user schemes are git-ignored',
        ),
      );
    }
  }
}

void _compareEntrypoints(
  DiffBuilder diff,
  ProjectModel expected,
  ProjectModel actual,
) {
  for (final flavor in expected.allFlavors) {
    final want = expected.dart.entrypointFor(flavor);
    if (want == null) continue;
    final have = actual.dart.entrypointFor(flavor);
    diff.value('dart.entrypoints.$flavor', want.path, have?.path);
  }
}
