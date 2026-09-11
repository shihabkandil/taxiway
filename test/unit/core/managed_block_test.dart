import 'package:shipway/src/core/managed/comment_style.dart';
import 'package:shipway/src/core/managed/managed_block.dart';
import 'package:test/test.dart';

void main() {
  group('ManagedBlock.find', () {
    test('returns null when there is no block', () {
      expect(ManagedBlock.find('android {\n}\n'), isNull);
    });

    test('locates a block and strips its indentation', () {
      final content = '''
android {
    // BEGIN shipway (managed) — do not edit. Regenerate with `shipway generate`.
    flavorDimensions += "env"
    // END shipway
}
''';
      final block = ManagedBlock.find(content)!;
      expect(block.indent, '    ');
      expect(block.body, 'flavorDimensions += "env"');
      expect(
        content.substring(block.start, block.end),
        contains('END shipway'),
      );
    });

    test('rejects a BEGIN with no END rather than guessing', () {
      expect(
        () => ManagedBlock.find('// BEGIN shipway (managed)\nstuff\n'),
        throwsA(isA<ManagedBlockException>()),
      );
    });

    test('rejects duplicate blocks', () {
      const content = '''
// BEGIN shipway (managed)
a
// END shipway
// BEGIN shipway (managed)
b
// END shipway
''';
      expect(
        () => ManagedBlock.find(content),
        throwsA(isA<ManagedBlockException>()),
      );
    });
  });

  group('ManagedBlock.upsert', () {
    test('appends a block to a file that has none', () {
      final out = ManagedBlock.upsert(
        'existing\n',
        body: '*.jks',
        style: CommentStyle.hash,
      );
      expect(out, startsWith('existing\n'));
      expect(out, contains('# BEGIN shipway (managed)'));
      expect(out, contains('*.jks'));
      expect(out, contains('# END shipway'));
    });

    test('adds a newline before the block when the file lacks one', () {
      final out = ManagedBlock.upsert(
        'no trailing newline',
        body: 'x',
        style: CommentStyle.hash,
      );
      expect(out, contains('no trailing newline\n# BEGIN'));
    });

    test('inserts at an offset when asked', () {
      const content = 'android {\n}\n';
      final out = ManagedBlock.upsert(
        content,
        body: 'inner',
        style: CommentStyle.doubleSlash,
        insertAt: 'android {\n'.length,
        indent: '    ',
      );
      expect(out, '''
android {
    // ${ManagedBlock.beginText}
    inner
    // ${ManagedBlock.endText}
}
''');
    });

    test('replaces an existing block in place, preserving its indent', () {
      final first = ManagedBlock.upsert(
        'android {\n}\n',
        body: 'old',
        style: CommentStyle.doubleSlash,
        insertAt: 'android {\n'.length,
        indent: '  ',
      );
      final second = ManagedBlock.upsert(
        first,
        body: 'new',
        style: CommentStyle.doubleSlash,
      );
      expect(second, contains('  new'));
      expect(second, isNot(contains('old')));
      expect(second, endsWith('}\n'));
    });

    test('is idempotent for unchanged content', () {
      final once = ManagedBlock.upsert(
        'head\n',
        body: 'a\nb',
        style: CommentStyle.hash,
      );
      final twice = ManagedBlock.upsert(
        once,
        body: 'a\nb',
        style: CommentStyle.hash,
      );
      expect(twice, once);
    });

    test('does not indent blank lines inside the body', () {
      final out = ManagedBlock.upsert(
        'x {\n}\n',
        body: 'a\n\nb',
        style: CommentStyle.doubleSlash,
        insertAt: 'x {\n'.length,
        indent: '  ',
      );
      expect(out, contains('  a\n\n  b\n'));
    });
  });

  group('ManagedBlock.remove', () {
    test('leaves everything outside the block untouched', () {
      const original = 'before\nafter\n';
      final withBlock = ManagedBlock.upsert(
        original,
        body: 'managed',
        style: CommentStyle.hash,
        insertAt: 'before\n'.length,
      );
      expect(ManagedBlock.remove(withBlock), original);
    });

    test('is a no-op when there is no block', () {
      expect(ManagedBlock.remove('plain\n'), 'plain\n');
    });
  });

  group('CommentStyle.forPath', () {
    test('picks the right style per file kind', () {
      expect(
        CommentStyle.forPath('android/app/build.gradle.kts'),
        CommentStyle.doubleSlash,
      );
      expect(
        CommentStyle.forPath('android/app/build.gradle'),
        CommentStyle.doubleSlash,
      );
      expect(CommentStyle.forPath('.gitignore'), CommentStyle.hash);
      expect(CommentStyle.forPath('ios/Podfile'), CommentStyle.hash);
      expect(CommentStyle.forPath('ios/fastlane/Fastfile'), CommentStyle.hash);
      expect(
        CommentStyle.forPath('ios/Flutter/dev.xcconfig'),
        CommentStyle.xcconfig,
      );
      expect(CommentStyle.forPath('a/Runner.xcscheme'), CommentStyle.xml);
    });
  });
}
