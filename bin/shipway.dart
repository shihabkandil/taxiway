import 'dart:io';

import 'package:shipway/src/cli/shipway_command_runner.dart';

Future<void> main(List<String> args) async {
  exitCode = await ShipwayCommandRunner().run(args);
}
