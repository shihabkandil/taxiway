import 'dart:convert';
import 'package:shipway/src/inspect/android_inspector.dart';

Future<void> main(List<String> args) async {
  final result = await const AndroidInspector().inspect(args.first);
  print(const JsonEncoder.withIndent('  ').convert(result.android.toJson()));
  print('--- uncertainties (${result.uncertainties.length}) ---');
  for (final u in result.uncertainties) {
    print('[${u.severity.name}] ${u.field}');
    print('    ${u.reason}');
    print('    -> ${u.remedy}');
  }
}
