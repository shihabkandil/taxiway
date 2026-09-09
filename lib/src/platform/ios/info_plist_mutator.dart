import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/io/process_runner.dart';

/// The outcome of pointing `Info.plist` at a build setting.
class PlistMutationResult {
  const PlistMutationResult({
    required this.changed,
    this.previousValue,
    this.backupPath,
    this.failureReason,
    this.failureRemedy,
    this.restored = false,
  });

  final bool changed;

  /// The literal that was there before, which the caller must preserve as the
  /// unflavored default.
  final String? previousValue;

  final String? backupPath;
  final String? failureReason;
  final String? failureRemedy;
  final bool restored;

  bool get succeeded => failureReason == null;
}

/// Points `CFBundleDisplayName` at a build setting so each flavor gets its own
/// name on the home screen.
///
/// Xcode expands `$(VAR)` references in `Info.plist` at build time, which is the
/// only mechanism that varies the display name per build configuration. Setting
/// `APP_DISPLAY_NAME` in an xcconfig alone does nothing: nothing reads it.
///
/// The dangerous part is the unflavored case. Once the plist says
/// `$(APP_DISPLAY_NAME)`, a configuration that does not define that setting
/// produces an app with an **empty** name — so the caller must define it for
/// every configuration, seeded from [PlistMutationResult.previousValue].
///
/// Edits go through `plutil`, Apple's own tool, so an XML or binary plist is
/// read and written in its own format rather than reformatted by us.
class InfoPlistMutator {
  const InfoPlistMutator({required this.runner, required this.root});

  final ProcessRunner runner;
  final String root;

  static const String plistPath = 'ios/Runner/Info.plist';
  static const String displayNameKey = 'CFBundleDisplayName';

  /// The build setting the plist is pointed at.
  static const String displayNameSetting = 'APP_DISPLAY_NAME';

  /// What the plist should contain once taxiway is done.
  static const String displayNameReference = '\$($displayNameSetting)';

  static const String backupDirectory = '.taxiway/backups';

  /// Reads the current `CFBundleDisplayName`.
  ///
  /// Returns null when the key is absent, and the reference string itself when
  /// taxiway has already been here.
  Future<String?> readDisplayName() async {
    final file = File(p.join(root, plistPath));
    if (!file.existsSync()) return null;

    final result = await runner.run('plutil', <String>[
      '-extract',
      displayNameKey,
      'raw',
      '-o',
      '-',
      file.path,
    ]);
    if (!result.ok) return null;
    final value = result.stdout.trim();
    return value.isEmpty ? null : value;
  }

  /// True when the plist already points at the build setting.
  Future<bool> isConfigured() async =>
      await readDisplayName() == displayNameReference;

  /// Rewrites `CFBundleDisplayName` to reference [displayNameSetting].
  ///
  /// Idempotent, and a no-op when the plist is already pointed at it.
  Future<PlistMutationResult> pointDisplayNameAtBuildSetting() async {
    final file = File(p.join(root, plistPath));
    if (!file.existsSync()) {
      return const PlistMutationResult(
        changed: false,
        failureReason: '$plistPath was not found.',
        failureRemedy: 'Run `flutter create --platforms=ios .` first.',
      );
    }

    final current = await readDisplayName();
    if (current == displayNameReference) {
      return PlistMutationResult(changed: false, previousValue: current);
    }

    final original = await file.readAsBytes();
    final backup = await _backup(original);

    final result = await runner.run('plutil', <String>[
      '-replace',
      displayNameKey,
      '-string',
      displayNameReference,
      file.path,
    ]);

    if (!result.ok) {
      final restored = await _restore(file, original);
      return PlistMutationResult(
        changed: false,
        previousValue: current,
        backupPath: backup,
        failureReason: result.notFound
            ? '`plutil` is not available.'
            : 'Could not update $plistPath: '
                  '${result.output.split('\n').first}',
        failureRemedy:
            'plutil ships with macOS. Check the plist is valid with '
            '`plutil -lint $plistPath`.',
        restored: restored,
      );
    }

    // Verify rather than trust the exit code: a plist that silently did not
    // take the edit would leave every flavor sharing one name.
    if (await readDisplayName() != displayNameReference) {
      final restored = await _restore(file, original);
      return PlistMutationResult(
        changed: false,
        previousValue: current,
        backupPath: backup,
        failureReason:
            '$plistPath still does not reference $displayNameSetting after '
            'the edit.',
        failureRemedy: 'The original file has been restored.',
        restored: restored,
      );
    }

    return PlistMutationResult(
      changed: true,
      previousValue: current,
      backupPath: backup,
    );
  }

  Future<String> _backup(List<int> original) async {
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final directory = Directory(p.join(root, backupDirectory, stamp));
    await directory.create(recursive: true);
    final destination = File(p.join(directory.path, 'Info.plist'));
    await destination.writeAsBytes(original, flush: true);
    return p.join(backupDirectory, stamp, 'Info.plist');
  }

  Future<bool> _restore(File plist, List<int> original) async {
    try {
      await plist.writeAsBytes(original, flush: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
