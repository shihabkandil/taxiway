import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Thrown when another run already holds the lock.
class RunLockBusy implements Exception {
  const RunLockBusy(this.detail);

  /// What the holder recorded about itself, when it could be read.
  final String detail;

  @override
  String toString() => 'Another taxiway run is using this project. $detail';
}

/// Stops two runs sharing what cannot be shared.
///
/// A keychain and a build directory are not safe to use concurrently, and a
/// persistent runner will be asked to do exactly that — two jobs on one Mac
/// mini, or somebody building by hand while CI runs. Without a lock the failure
/// is not a clean error: one run tears down the keychain the other is signing
/// with, and the symptom is a signing failure in a build that did nothing
/// wrong.
///
/// Implemented with an OS advisory lock rather than a pid file. That matters
/// for the case a build machine actually hits: a run killed by a cancelled CI
/// job, or a machine that lost power, releases the lock automatically because
/// the kernel drops it when the process dies. A pid file would leave a stale
/// lock needing a human to delete a file they have never heard of.
class RunLock {
  RunLock._(this._handle, this._file);

  final RandomAccessFile _handle;
  final File _file;
  bool _released = false;

  static const String fileName = 'run.lock';
  static const String directoryName = '.taxiway';

  static String pathFor(String root) => p.join(root, directoryName, fileName);

  /// Takes the lock, or throws [RunLockBusy].
  static Future<RunLock> acquire(String root, {DateTime? now}) async {
    final file = File(pathFor(root));
    await file.parent.create(recursive: true);

    final handle = await file.open(mode: FileMode.write);
    try {
      // Non-blocking: waiting would turn a concurrent build into a hang, and a
      // hang on a runner burns the job timeout while reporting nothing.
      await handle.lock(FileLock.exclusive);
    } on FileSystemException {
      final detail = await _describeHolder(file);
      await handle.close();
      throw RunLockBusy(detail);
    }

    // Written for a human reading the file, not for the locking itself.
    await handle.truncate(0);
    await handle.setPosition(0);
    await handle.writeString(
      jsonEncode(<String, dynamic>{
        'pid': pid,
        'since': (now ?? DateTime.now()).toIso8601String(),
      }),
    );
    await handle.flush();

    return RunLock._(handle, file);
  }

  /// Releases the lock and removes the file.
  ///
  /// Safe to call twice and safe when the file is already gone: a teardown that
  /// throws because cleanup already happened is worse than one that quietly
  /// agrees.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _handle.unlock();
    } on FileSystemException {
      // Already gone; the point was for it not to be held.
    }
    try {
      await _handle.close();
    } on FileSystemException {
      // As above.
    }
    try {
      if (_file.existsSync()) await _file.delete();
    } on FileSystemException {
      // As above.
    }
  }

  static Future<String> _describeHolder(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['pid'] != null) {
        return 'Held by pid ${decoded['pid']} since ${decoded['since']}.';
      }
    } on Object {
      // A lock we cannot describe is still a lock.
    }
    return 'Its lock file is ${pathFor(p.dirname(p.dirname(file.path)))}.';
  }
}
