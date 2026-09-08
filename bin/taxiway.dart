import 'dart:io';

import 'package:taxiway/src/cli/taxiway_command_runner.dart';

Future<void> main(List<String> args) async {
  exitCode = await TaxiwayCommandRunner().run(args);
}
