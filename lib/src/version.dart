/// The current shipway version.
///
/// Kept in sync with `pubspec.yaml` by `tool/check_version.dart`.
const String packageVersion = '0.1.0-dev';

/// Where the package lives, for a machine that has to install it.
///
/// Kept beside the version because the two are used together: a generated
/// workflow installs shipway from here at the tag matching [packageVersion].
/// Must agree with `repository:` in `pubspec.yaml`, which a test asserts.
const String packageRepository = 'https://github.com/shihabkandil/shipway';

/// The git tag a runner should install, or null when the running version is a
/// pre-release with no tag behind it.
///
/// Naming a tag that does not resolve is worse than not pinning: the failure
/// arrives on the runner, at install time, in somebody else's repository.
String? get packageGitRef =>
    packageVersion.contains('-') ? null : 'v$packageVersion';
