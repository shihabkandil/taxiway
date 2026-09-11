import 'package:shipway/src/core/io/process_runner.dart';
import 'package:shipway/src/core/io/redactor.dart';
import 'package:shipway/src/inspect/project_inspector.dart';

Future<void> main(List<String> args) async {
  final model = await ProjectInspector(
    runner: SystemProcessRunner(redactor: Redactor()),
  ).readFromDisk(args.first);

  print('android flavors : ${model.androidFlavors}');
  print('ios flavors     : ${model.iosFlavors}');
  print('android-only    : ${model.androidOnlyFlavors}');
  print('ios-only        : ${model.iosOnlyFlavors}');
  print('entrypoints     : ${model.dart.entrypoints.keys}');
  print('package/version : ${model.dart.packageName} ${model.dart.version}');
  print('fastlane        : ${model.fastlane.map((f) => f.directory).toList()}');
  print(
    'firebase files  : ${model.firebase.configFiles.map((f) => "${f.platform}:${f.sourceSet}").toList()}',
  );
  print('');
  print('--- findings (${model.uncertainties.length}) ---');
  for (final u in model.uncertainties) {
    print('[${u.severity.name}] ${u.field}');
    print('    ${u.reason}');
    print('    -> ${u.remedy}');
  }
}
