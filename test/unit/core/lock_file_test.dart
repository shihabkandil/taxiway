import 'dart:convert';
import 'dart:io';

import 'package:taxiway/src/core/managed/content_hash.dart';
import 'package:taxiway/src/core/managed/lock_file.dart';
import 'package:test/test.dart';

void main() {
  group('Ownership', () {
    test('only adopted and generated files are writable', () {
      expect(Ownership.unmanaged.writable, isFalse);
      expect(Ownership.adopted.writable, isTrue);
      expect(Ownership.generated.writable, isTrue);
    });

    test('an unknown ownership string falls back to unmanaged', () {
      // Forward compatibility must fail closed: a state written by a newer
      // taxiway must never be read as "safe to overwrite".
      expect(Ownership.parse('some-future-state'), Ownership.unmanaged);
    });
  });

  group('LockFile', () {
    test('treats an unheard-of file as unmanaged', () {
      final lock = LockFile.empty();
      expect(lock.ownershipOf('android/app/build.gradle.kts'),
          Ownership.unmanaged);
      expect(lock.mayWrite('android/app/build.gradle.kts'), isFalse);
    });

    test('records ownership and reports it back', () {
      final lock = LockFile.empty()
        ..record(
          LockEntry(
            path: 'android/app/build.gradle.kts',
            ownership: Ownership.adopted,
            mode: WriteMode.block,
            hash: ContentHash.of('whole'),
            blockHash: ContentHash.of('block'),
            adoptedAt: DateTime.utc(2026, 9, 8),
          ),
        );
      expect(lock.mayWrite('android/app/build.gradle.kts'), isTrue);
      expect(lock['android/app/build.gradle.kts']!.mode, WriteMode.block);
    });

    test('noteUnmanaged tracks a file without granting write access', () {
      final lock = LockFile.empty()..noteUnmanaged('ios/fastlane/Fastfile');
      expect(lock.files, contains('ios/fastlane/Fastfile'));
      expect(lock.mayWrite('ios/fastlane/Fastfile'), isFalse);
    });

    test('normalises paths so a file is tracked once', () {
      final lock = LockFile.empty()
        ..noteUnmanaged('./android/app/build.gradle.kts')
        ..noteUnmanaged(r'android\app\build.gradle.kts');
      expect(lock.files, hasLength(1));
    });

    test('detects drift against the recorded hash', () {
      final lock = LockFile.empty()
        ..record(
          LockEntry(
            path: 'f',
            ownership: Ownership.generated,
            mode: WriteMode.full,
            hash: ContentHash.of('original'),
          ),
        );
      expect(lock.hasDrifted('f', 'original'), isFalse);
      expect(lock.hasDrifted('f', 'edited by hand'), isTrue);
    });

    test('reports no drift for a file it has no hash for', () {
      final lock = LockFile.empty()..noteUnmanaged('f');
      expect(lock.hasDrifted('f', 'anything'), isFalse);
    });

    test('round-trips through JSON', () {
      final original = LockFile.empty()
        ..record(
          LockEntry(
            path: 'b',
            ownership: Ownership.generated,
            mode: WriteMode.full,
            hash: ContentHash.of('x'),
            adoptedAt: DateTime.utc(2026, 9, 8, 12),
          ),
        )
        ..noteUnmanaged('a');
      final decoded = LockFile.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.files.keys, ['a', 'b']);
      expect(decoded['b']!.hash, ContentHash.of('x'));
      expect(decoded['b']!.adoptedAt, DateTime.utc(2026, 9, 8, 12));
    });

    test('serialises files in sorted order for reviewable diffs', () {
      final lock = LockFile.empty()
        ..noteUnmanaged('z')
        ..noteUnmanaged('a')
        ..noteUnmanaged('m');
      final files = lock.toJson()['files'] as Map<String, dynamic>;
      expect(files.keys, ['a', 'm', 'z']);
    });

    test('saves to and loads from .taxiway/lock.json', () async {
      final dir = await Directory.systemTemp.createTemp('taxiway_lock');
      addTearDown(() => dir.delete(recursive: true));

      await (LockFile.empty()
            ..record(
              LockEntry(
                path: 'p',
                ownership: Ownership.adopted,
                mode: WriteMode.block,
                blockHash: ContentHash.of('body'),
              ),
            ))
          .save(dir.path);

      expect(File(LockFile.pathFor(dir.path)).existsSync(), isTrue);
      final loaded = await LockFile.load(dir.path);
      expect(loaded.ownershipOf('p'), Ownership.adopted);
      expect(loaded['p']!.blockHash, ContentHash.of('body'));
    });

    test('loads an empty lockfile for a project taxiway has never touched',
        () async {
      final dir = await Directory.systemTemp.createTemp('taxiway_lock');
      addTearDown(() => dir.delete(recursive: true));
      final loaded = await LockFile.load(dir.path);
      expect(loaded.files, isEmpty);
    });
  });

  group('ContentHash', () {
    test('is stable and algorithm-prefixed', () {
      expect(ContentHash.of('abc'), startsWith('sha256:'));
      expect(ContentHash.of('abc'), ContentHash.of('abc'));
      expect(ContentHash.of('abc'), isNot(ContentHash.of('abd')));
    });

    test('a null hash never matches', () {
      expect(ContentHash.matches(null, 'abc'), isFalse);
    });
  });
}
