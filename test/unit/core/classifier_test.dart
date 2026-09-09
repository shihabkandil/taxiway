import 'package:taxiway/src/core/errors/classifier.dart';
import 'package:test/test.dart';

void main() {
  /// Verbatim fragments of output produced by real tools during the Phase 2
  /// spike. Copied rather than paraphrased: a classifier tested against
  /// prose someone remembered writing matches nothing in the field.
  group('real output from the spike', () {
    void expectId(String output, String id) =>
        expect(ErrorClassifier.classify(output)?.id, id);

    test('gym exporting an archive built with --no-codesign', () {
      expectId(
        'error: exportArchive No Team Found in Archive\n'
            '** EXPORT FAILED **',
        'ios.export.no_team',
      );
    });

    test('an Xcode-managed profile used with manual signing', () {
      expectId(
        'error: exportArchive Provisioning profile "iOS Team Provisioning '
            'Profile: *" is Xcode managed, but signing settings require a '
            'manually managed profile.',
        'ios.export.xcode_managed_profile',
      );
    });

    test('gym archiving a Flutter app on a fresh clone', () {
      expectId(
        'xcodebuild: error: Could not resolve package dependencies:\n'
            "  the package at '/x/ios/Flutter/ephemeral/Packages/"
            "FlutterGeneratedPluginSwiftPackage' cannot be accessed "
            "(doesn't exist in file system)\n"
            'Exit status: 74',
        'ios.gym.missing_ephemeral',
      );
    });

    test('gym prompting for a scheme, which hangs rather than fails', () {
      expectId(
        '?  Ambiguous choice.  Please choose one of [1, 2, 3, Runner, dev, '
            'prod].',
        'ios.gym.scheme_prompt',
      );
    });

    test('codesign refused the key by ACL', () {
      expectId(
        '/x/App.framework/App: replacing existing signature\n'
            '/x/App.framework/App: errSecInternalComponent',
        'ios.codesign.key_acl',
      );
    });

    test('a Homebrew fastlane shadowing the bundled gems', () {
      expectId(
        'Could not find CFPropertyList-3.0.9, aws-sdk-s3-1.230.0 in locally '
            'installed gems (Bundler::GemNotFound)',
        'ruby.bundle_gem_missing',
      );
    });

    test('a gem pinned above what the Ruby floor allows', () {
      expectId(
        'So, because current Ruby version is = 3.1.1,\n'
            '  version solving has failed.',
        'ruby.version_solving_failed',
      );
    });

    test('fastlane warning about the Ruby version', () {
      expectId(
        'WARNING: Support for your Ruby version (3.1.1) is going away. '
            'fastlane will soon require Ruby 3.3.0 or newer.',
        'ruby.too_old_for_fastlane',
      );
    });

    test('a flavored build that silently lost its version numbers', () {
      // Flutter exits zero here, which is the entire problem.
      expectId(
        '[!] App Settings Validation\n'
            '    ! Version Number: Missing\n'
            '    ! Build Number: Missing\n'
            '    • Bundle Identifier: com.acme.app.dev',
        'ios.flavor.missing_version',
      );
    });
  });

  group('catalog signatures', () {
    test('a missing provisioning profile', () {
      expect(
        ErrorClassifier.classify(
          "error: No profiles for 'com.acme.app.dev' were found",
        )?.id,
        'ios.signing.no_profile',
      );
    });

    test('a wrong match passphrase', () {
      expect(
        ErrorClassifier.classify(
          'OpenSSL::Cipher::CipherError: wrong final block length',
        )?.id,
        'ios.match.wrong_password',
      );
    });

    test('a reused Play version code', () {
      expect(
        ErrorClassifier.classify(
          'Google Api Error: Version code has already been used.',
        )?.id,
        'play.version_code_used',
      );
    });

    test('a reused App Store Connect build number', () {
      expect(
        ErrorClassifier.classify(
          'The provided entity includes an attribute with a value that has '
          'already been used',
        )?.id,
        'asc.duplicate_build_number',
      );
    });

    test('a Play service account without permission', () {
      expect(
        ErrorClassifier.classify(
          'androidpublisher: Error 403: The caller does not have permission',
        )?.id,
        'play.permission_denied',
      );
    });
  });

  group('discipline', () {
    test('every id is unique', () {
      final ids = ErrorClassifier.ids;
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('every signature says what to do, not just what happened', () {
      for (final signature in ErrorClassifier.signatures) {
        expect(signature.fix.trim(), isNotEmpty, reason: signature.id);
        expect(signature.summary.trim(), isNotEmpty, reason: signature.id);
        // A "fix" that only restates the problem is not a fix.
        expect(
          signature.fix,
          isNot(equals(signature.summary)),
          reason: signature.id,
        );
      }
    });

    test('ids are namespaced so they can be grouped and filtered', () {
      for (final id in ErrorClassifier.ids) {
        expect(id, matches(RegExp(r'^[a-z]+\.[a-z_.]+$')), reason: id);
      }
    });

    test('nothing matches ordinary successful output', () {
      // The cost of a false positive is a confident, wrong explanation, which
      // is worse than no explanation at all.
      const clean = '''
Running Xcode build...
Xcode archive done.                    23.6s
✓ Built build/ios/archive/Runner.xcarchive (169.6MB)
[✓] App Settings Validation
    • Version Number: 1.0.0
    • Build Number: 1
Successfully exported and signed the ipa file
''';
      expect(ErrorClassifier.classifyAll(clean), isEmpty);
    });

    test('empty and null output classify to nothing', () {
      expect(ErrorClassifier.classify(null), isNull);
      expect(ErrorClassifier.classify(''), isNull);
      expect(ErrorClassifier.classifyAll(null), isEmpty);
    });

    test('the more specific of two overlapping signatures wins', () {
      // Both the SPM and the CocoaPods form describe gym archiving a Flutter
      // app; a log containing the exportArchive wording must not be reported
      // as the ephemeral one, and vice versa.
      expect(
        ErrorClassifier.classify(
          'error: exportArchive The data couldn\'t be read because it isn\'t '
          'in the correct format',
        )?.id,
        'ios.gym.wraps_flutter_build',
      );
    });

    test('several diagnoses surface together when a run trips several', () {
      // A stale Ruby warning must not hide the real failure underneath it.
      final all = ErrorClassifier.classifyAll(
        'WARNING: Support for your Ruby version (3.1.1) is going away.\n'
        'error: exportArchive No Team Found in Archive',
      );
      expect(
        all.map((d) => d.id),
        containsAll(<String>[
          'ios.export.no_team',
          'ruby.too_old_for_fastlane',
        ]),
      );
    });
  });
}
