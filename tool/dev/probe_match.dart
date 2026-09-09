// Ad-hoc: read a real match-shaped repository and report coverage.
import 'package:taxiway/src/core/io/process_runner.dart';
import 'package:taxiway/src/core/io/redactor.dart';
import 'package:taxiway/src/platform/ios/match_repository.dart';

Future<void> main(List<String> args) async {
  final runner = SystemProcessRunner(redactor: Redactor());
  try {
    final contents = await MatchRepository.read(
      gitUrl: args.first,
      runner: runner,
      branch: args.length > 1 ? args[1] : 'master',
    );
    print('profiles: ${contents.profiles}');
    print('certificate types: ${contents.certificateTypes}');
    print('appstore covers: ${contents.bundleIdsFor('appstore')}');
    print(
      'missing appstore for [com.acme.app, com.acme.app.staging]: '
      '${contents.missingFrom(const ['com.acme.app', 'com.acme.app.staging'], 'appstore')}',
    );
  } on MatchRepositoryFailure catch (f) {
    print('FAILED: ${f.message}');
    print('HINT:   ${f.fixHint}');
  }
}
