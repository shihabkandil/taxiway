import '../core/model/android_model.dart';
import '../core/model/uncertainty.dart';
import '../core/gradle/gradle_scanner.dart';
import 'gradle_values.dart';

/// The result of a fast structural parse.
class GradleParseResult {
  const GradleParseResult({required this.android, required this.uncertainties});

  final AndroidModel android;
  final List<Uncertainty> uncertainties;
}

/// Reads `android/app/build.gradle[.kts]` without running Gradle.
///
/// The fast path. It is honest about its limits: anything referencing a
/// variable, an `ext` property, a string interpolation, a flavor created in a
/// loop, or another script becomes an [Uncertainty] that `--deep` may resolve.
class GradleStructuralParser {
  const GradleStructuralParser();

  GradleParseResult parse(
    String source, {
    required GradleDsl dsl,
    required String buildFilePath,
    List<String> sourceSets = const <String>[],
  }) {
    final log = UncertaintyLog();

    final androidBlock = GradleScanner.findBlock(source, 'android');
    if (androidBlock == null) {
      log.defect(
        field: 'android',
        reason: 'no `android { }` block was found in this build file.',
        remedy: 'Check that $buildFilePath is the app module build file.',
        source: buildFilePath,
      );
      return GradleParseResult(
        android: const AndroidModel.absent(),
        uncertainties: log.build(),
      );
    }

    _warnAboutAppliedScripts(source, log, buildFilePath);

    final body = androidBlock.body;
    final children = GradleScanner.blocksIn(body);

    final defaultConfig = _blockNamed(children, 'defaultConfig');
    final applicationId = _readApplicationId(defaultConfig, log, buildFilePath);

    final dimensions = GradleValues.flavorDimensions(body);
    for (final expression in dimensions.expressions) {
      log.nonLiteral(
        field: 'android.flavorDimensions',
        expression: expression,
        source: buildFilePath,
      );
    }

    final flavors = _readFlavors(children, log, buildFilePath);
    final signingConfigs = _readSigningConfigs(children, log, buildFilePath);
    final buildTypes = _readBuildTypes(children, log, buildFilePath);

    return GradleParseResult(
      android: AndroidModel(
        gradleDsl: dsl,
        buildFilePath: buildFilePath,
        applicationId: applicationId,
        namespace: _literal(body, 'namespace'),
        compileSdk:
            GradleValues.intProperty(body, 'compileSdk') ??
            GradleValues.intProperty(body, 'compileSdkVersion'),
        minSdk: defaultConfig == null
            ? null
            : GradleValues.intProperty(defaultConfig.body, 'minSdk') ??
                  GradleValues.intProperty(defaultConfig.body, 'minSdkVersion'),
        targetSdk: defaultConfig == null
            ? null
            : GradleValues.intProperty(defaultConfig.body, 'targetSdk') ??
                  GradleValues.intProperty(
                    defaultConfig.body,
                    'targetSdkVersion',
                  ),
        flavorDimensions: dimensions.names,
        flavors: flavors,
        buildTypes: buildTypes,
        signingConfigs: signingConfigs,
        sourceSets: sourceSets,
      ),
      uncertainties: log.build(),
    );
  }

  /// `apply from:` pulls in configuration the fast path cannot see at all.
  void _warnAboutAppliedScripts(
    String source,
    UncertaintyLog log,
    String buildFilePath,
  ) {
    final matches = RegExp(
      '''(?:^|\\n)\\s*apply\\s+from\\s*:?\\s*["']([^"']+)["']''',
    ).allMatches(source);
    for (final match in matches) {
      log.note(
        field: 'android',
        reason:
            'this build file applies `${match.group(1)}`, whose contents '
            'taxiway did not read.',
        remedy:
            'Re-run with `--deep` if flavors or signing are configured '
            'there.',
        source: buildFilePath,
      );
    }
  }

  String? _readApplicationId(
    GradleBlock? defaultConfig,
    UncertaintyLog log,
    String buildFilePath,
  ) {
    if (defaultConfig == null) return null;
    final value = GradleValues.property(defaultConfig.body, 'applicationId');
    if (value == null) return null;
    final literal = value.literalOrNull;
    if (literal != null) return literal;
    log.nonLiteral(
      field: 'android.applicationId',
      expression: value.toString(),
      source: buildFilePath,
    );
    return null;
  }

  Map<String, AndroidFlavor> _readFlavors(
    List<GradleBlock> children,
    UncertaintyLog log,
    String buildFilePath,
  ) {
    final productFlavors = _blockNamed(children, 'productFlavors');
    if (productFlavors == null) return const <String, AndroidFlavor>{};

    final flavors = <String, AndroidFlavor>{};
    for (final block in GradleScanner.blocksIn(productFlavors.body)) {
      final name = block.declaredName;
      if (name == null) {
        // A flavor built in a loop or a conditional. We cannot name it, so we
        // must not pretend the flavor list is complete.
        log.nonLiteral(
          field: 'android.productFlavors',
          expression: block.header,
          source: buildFilePath,
        );
        continue;
      }
      flavors[name] = _readFlavor(name, block.body, log, buildFilePath);
    }
    return flavors;
  }

  AndroidFlavor _readFlavor(
    String name,
    String body,
    UncertaintyLog log,
    String buildFilePath,
  ) {
    String? literalOrLog(String property) {
      final value = GradleValues.property(body, property);
      if (value == null) return null;
      final literal = value.literalOrNull;
      if (literal != null) return literal;
      log.nonLiteral(
        field: 'android.flavors.$name.$property',
        expression: value.toString(),
        source: buildFilePath,
      );
      return null;
    }

    final resValues = GradleValues.resValues(body);
    for (final expression in resValues.expressions) {
      log.nonLiteral(
        field: 'android.flavors.$name.resValue',
        expression: expression,
        source: buildFilePath,
      );
    }

    final placeholders = GradleValues.manifestPlaceholders(body);
    for (final expression in placeholders.expressions) {
      log.nonLiteral(
        field: 'android.flavors.$name.manifestPlaceholders',
        expression: expression,
        source: buildFilePath,
      );
    }

    return AndroidFlavor(
      name: name,
      dimension: literalOrLog('dimension'),
      applicationId: literalOrLog('applicationId'),
      applicationIdSuffix: literalOrLog('applicationIdSuffix'),
      versionNameSuffix: literalOrLog('versionNameSuffix'),
      signingConfig: GradleValues.signingConfigReference(body),
      resValues: resValues.values,
      manifestPlaceholders: placeholders.values,
    );
  }

  Map<String, AndroidSigningConfigDeclaration> _readSigningConfigs(
    List<GradleBlock> children,
    UncertaintyLog log,
    String buildFilePath,
  ) {
    final block = _blockNamed(children, 'signingConfigs');
    if (block == null) {
      return const <String, AndroidSigningConfigDeclaration>{};
    }
    final configs = <String, AndroidSigningConfigDeclaration>{};
    for (final entry in GradleScanner.blocksIn(block.body)) {
      final name = entry.declaredName;
      if (name == null) continue;
      final storeFile = GradleValues.property(entry.body, 'storeFile');
      final keyAlias = GradleValues.property(entry.body, 'keyAlias');
      // Reading credentials from a properties file is the correct shape, so an
      // absent literal here is expected rather than a problem to report.
      final fromProperties =
          entry.body.contains('Properties') ||
          entry.body.contains('propert') ||
          entry.body.contains('System.getenv');
      configs[name] = AndroidSigningConfigDeclaration(
        name: name,
        storeFile: storeFile?.literalOrNull,
        keyAlias: keyAlias?.literalOrNull,
        readsFromProperties: fromProperties,
      );
    }
    return configs;
  }

  List<String> _readBuildTypes(
    List<GradleBlock> children,
    UncertaintyLog log,
    String buildFilePath,
  ) {
    final block = _blockNamed(children, 'buildTypes');
    if (block == null) return const <String>[];
    final types = <String>[];
    for (final entry in GradleScanner.blocksIn(block.body)) {
      final name = entry.declaredName;
      if (name != null) types.add(name);
    }
    return types;
  }

  static GradleBlock? _blockNamed(List<GradleBlock> blocks, String name) {
    for (final block in blocks) {
      if (block.declaredName == name) return block;
    }
    return null;
  }

  static String? _literal(String body, String property) =>
      GradleValues.property(body, property)?.literalOrNull;
}
