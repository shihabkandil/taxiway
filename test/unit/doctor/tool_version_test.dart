import 'package:taxiway/src/doctor/tool_version.dart';
import 'package:test/test.dart';

/// Every string below is real output captured from a working machine on
/// 2026-09-08. Invented output would not have caught the two cases that
/// actually break naive parsers: fastlane's install path and `gem list`'s
/// warning preamble.
void main() {
  group('ToolVersion.tryParse', () {
    test('parses two- and three-component versions', () {
      expect(ToolVersion.tryParse('3.35.0'), const ToolVersion(3, 35, 0));
      expect(ToolVersion.tryParse('26.6'), const ToolVersion(26, 6, 0));
      expect(ToolVersion.tryParse('  1.17.0  '), const ToolVersion(1, 17, 0));
    });

    test('returns null when there is no version', () {
      expect(ToolVersion.tryParse('not a version'), isNull);
      expect(ToolVersion.tryParse(''), isNull);
      expect(ToolVersion.tryParse('7'), isNull);
    });
  });

  group('ToolVersion.extract on real tool output', () {
    test('flutter, past the repository URL', () {
      const output = '''
Flutter 3.47.2 • channel stable • https://github.com/flutter/flutter.git
Framework • revision d3b14c8769 (13 days ago) • 2026-08-26 16:07:51 -0700
Engine • hash 1cf1c4773fb941c4c74a7f8bb144a8837596c0f4 (revision a804b26164)
Tools • Dart 3.13.2 • DevTools 2.60.0''';
      expect(
        ToolVersion.extract(output, preferLine: 'Flutter'),
        const ToolVersion(3, 47, 2),
      );
    });

    test('dart, past the build timestamp', () {
      const output =
          'Dart SDK version: 3.13.2 (stable) (Tue Aug 25 01:01:12 2026 -0700) '
          'on "macos_arm64"';
      expect(ToolVersion.extract(output), const ToolVersion(3, 13, 2));
    });

    test('xcode, ignoring the build number line', () {
      const output = 'Xcode 26.6\nBuild version 17F113';
      expect(
        ToolVersion.extract(output, preferLine: 'Xcode'),
        const ToolVersion(26, 6, 0),
      );
    });

    test('cocoapods bare version', () {
      expect(ToolVersion.extract('1.17.0'), const ToolVersion(1, 17, 0));
    });

    test('ruby, past the patchlevel and platform', () {
      const output =
          'ruby 3.1.1p18 (2022-02-18 revision 53f5fc4236) [arm64-darwin23]';
      expect(ToolVersion.extract(output), const ToolVersion(3, 1, 1));
    });

    test('bundler', () {
      expect(
        ToolVersion.extract('Bundler version 2.6.3'),
        const ToolVersion(2, 6, 3),
      );
    });

    test('fastlane, past its own install path', () {
      // The path holds 3.4.0 and 2.238.0; only the last line is the answer.
      const output = '''
fastlane installation at path:
/Users/someone/.local/share/fastlane/3.4.0/gems/fastlane-2.238.0/bin/fastlane
-----------------------------
fastlane 2.238.0''';
      expect(
        ToolVersion.extract(output, preferLine: 'fastlane'),
        const ToolVersion(2, 238, 0),
      );
    });

    test('gem list, past the unresolved-specs warning', () {
      // Without preferLine this yields 0.2.0 from the warning preamble.
      const output = '''
WARN: Unresolved or ambiguous specs during Gem::Specification.reset:
      tsort (>= 0)
      Available/installed versions of this gem:
      - 0.2.0
      - 0.1.0
      stringio (>= 0)
      Available/installed versions of this gem:
      - 3.2.0
      - 3.0.1
WARN: Clearing out unresolved specs. Try 'gem cleanup <gem>'
Please report a bug if this causes problems.
xcodeproj (1.28.1, 1.27.0, 1.23.0)''';
      expect(
        ToolVersion.extract(output, preferLine: 'xcodeproj', highest: true),
        const ToolVersion(1, 28, 1),
      );
      expect(
        ToolVersion.extract(output),
        const ToolVersion(0, 2, 0),
        reason: 'demonstrates why preferLine is required here',
      );
    });

    test('java, which reports to stderr and quotes its version', () {
      const output = '''
java version "18.0.2.1" 2022-08-18
Java(TM) SE Runtime Environment (build 18.0.2.1+1-1)
Java HotSpot(TM) 64-Bit Server VM (build 18.0.2.1+1-1, mixed mode, sharing)''';
      expect(
        ToolVersion.extract(output, preferLine: 'version'),
        const ToolVersion(18, 0, 2),
      );
    });

    test('openjdk 17 and 21 banners', () {
      expect(
        ToolVersion.extract(
          'openjdk version "17.0.9" 2023-10-17',
          preferLine: 'version',
        ),
        const ToolVersion(17, 0, 9),
      );
      expect(
        ToolVersion.extract(
          'openjdk version "21.0.4" 2024-07-16',
          preferLine: 'version',
        ),
        const ToolVersion(21, 0, 4),
      );
    });

    test('firebase CLI bare version', () {
      expect(ToolVersion.extract('15.28.1'), const ToolVersion(15, 28, 1));
    });

    test('returns null for a not-found message', () {
      expect(ToolVersion.extract('command not found: flutterfire'), isNull);
    });
  });

  group('ordering', () {
    test('compares component by component', () {
      expect(const ToolVersion(3, 1, 1) >= const ToolVersion(3, 0, 0), isTrue);
      expect(const ToolVersion(3, 1, 1) >= const ToolVersion(3, 3, 0), isFalse);
      expect(
        const ToolVersion(2, 238, 0) > const ToolVersion(2, 220, 0),
        isTrue,
      );
      expect(const ToolVersion(1, 9, 0) < const ToolVersion(1, 10, 0), isTrue);
      expect(const ToolVersion(26, 6) >= const ToolVersion(26, 0), isTrue);
    });

    test('equality and hashing agree', () {
      expect(const ToolVersion(1, 2, 3), const ToolVersion(1, 2, 3));
      // Built at runtime so the analyzer does not fold it into one literal;
      // the point is that hashCode agrees with ==, not that a set literal
      // deduplicates.
      final set = <ToolVersion>{}
        ..add(const ToolVersion(1, 2, 3))
        ..add(ToolVersion.tryParse('1.2.3')!);
      expect(set, hasLength(1));
    });

    test('renders as major.minor.patch', () {
      expect(const ToolVersion(26, 6).toString(), '26.6.0');
    });
  });
}
