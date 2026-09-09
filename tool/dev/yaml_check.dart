// Ad-hoc: parse a generated workflow to prove it is valid YAML.
import 'dart:io';
import 'package:yaml/yaml.dart';

void main(List<String> args) {
  final doc = loadYaml(File(args.first).readAsStringSync()) as YamlMap;
  print('parses OK');
  for (final entry in (doc['jobs'] as YamlMap).entries) {
    final job = entry.value as YamlMap;
    print('--- ${entry.key} env:');
    (job['env'] as YamlMap?)?.forEach((k, v) => print('    $k = $v'));
    print('--- ${entry.key} steps:');
    for (final s in job['steps'] as YamlList) {
      print('    ${(s as YamlMap)['name'] ?? s['uses']}');
    }
  }
}
