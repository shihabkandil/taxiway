import 'package:taxiway/src/core/io/process_runner.dart';
import 'package:taxiway/src/core/io/redactor.dart';
import 'package:taxiway/src/inspect/ios_inspector.dart';
import 'package:taxiway/src/inspect/xcodeproj_bridge.dart';

Future<void> main(List<String> args) async {
  final runner = SystemProcessRunner(redactor: Redactor());
  final inspector = IosInspector(
    bridge: XcodeprojBridge(
      runner: runner,
      scriptPath: XcodeprojBridge.locateScript()!,
    ),
  );
  final result = await inspector.inspect(args.first);
  final ios = result.ios;
  print(
    'objectVersion: ${ios.objectVersion}  deploymentTarget: ${ios.deploymentTarget}',
  );
  print('project configs: ${ios.projectConfigurations}');
  final t = ios.applicationTarget!;
  print('app target: ${t.name}');
  for (final c in t.buildConfigurations.values) {
    print(
      '  ${c.name.padRight(22)} ${c.bundleIdentifier ?? "<unresolved>"}  display=${c.displayName ?? "-"}  team=${c.developmentTeam ?? "-"}',
    );
  }
  print('schemes:');
  for (final s in ios.schemes.values) {
    print(
      '  ${s.name.padRight(14)} shared=${s.shared} launch=${s.buildConfiguration} archive=${s.archiveConfiguration}',
    );
  }
  print('xcconfigs: ${ios.xcconfigs.keys.toList()}');
  print('--- findings (${result.uncertainties.length}) ---');
  for (final u in result.uncertainties) {
    print(
      '[${u.severity.name}] ${u.field}\n    ${u.reason}\n    -> ${u.remedy}',
    );
  }
}
