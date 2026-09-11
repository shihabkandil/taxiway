import 'package:shipway/src/core/model/android_model.dart';
import 'package:shipway/src/core/model/uncertainty.dart';
import 'package:shipway/src/inspect/gradle_structural_parser.dart';
import 'package:test/test.dart';

GradleParseResult parseKts(String source) =>
    const GradleStructuralParser().parse(
      source,
      dsl: GradleDsl.kotlin,
      buildFilePath: 'android/app/build.gradle.kts',
    );

GradleParseResult parseGroovy(String source) =>
    const GradleStructuralParser().parse(
      source,
      dsl: GradleDsl.groovy,
      buildFilePath: 'android/app/build.gradle',
    );

/// The same project written both ways, so every assertion can be made twice.
const String _kts = '''
plugins {
    id("com.android.application")
}

android {
    namespace = "com.acme.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.acme.app"
        minSdk = 24
        targetSdk = 36
    }

    flavorDimensions += "environment"

    productFlavors {
        create("development") {
            dimension = "environment"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            resValue("string", "app_name", "Acme Dev")
        }
        create("production") {
            dimension = "environment"
            resValue("string", "app_name", "Acme")
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = "upload"
        }
    }

    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
        }
        getByName("debug") { }
    }
}
''';

const String _groovy = '''
apply plugin: 'com.android.application'

android {
    namespace 'com.acme.app'
    compileSdkVersion 36

    defaultConfig {
        applicationId "com.acme.app"
        minSdkVersion 24
        targetSdkVersion 36
    }

    flavorDimensions "environment"

    productFlavors {
        development {
            dimension "environment"
            applicationIdSuffix ".dev"
            versionNameSuffix "-dev"
            resValue "string", "app_name", "Acme Dev"
        }
        production {
            dimension "environment"
            resValue "string", "app_name", "Acme"
        }
    }

    signingConfigs {
        release {
            keyAlias 'upload'
        }
    }

    buildTypes {
        release {
            signingConfig signingConfigs.release
        }
        debug { }
    }
}
''';

void main() {
  group('both dialects produce the same model', () {
    for (final entry in <String, GradleParseResult Function(String)>{
      'kts': parseKts,
      'groovy': parseGroovy,
    }.entries) {
      final dialect = entry.key;
      final parse = entry.value;
      final source = dialect == 'kts' ? _kts : _groovy;

      group(dialect, () {
        late GradleParseResult result;
        setUp(() => result = parse(source));

        test('reads defaultConfig', () {
          expect(result.android.applicationId, 'com.acme.app');
          expect(result.android.namespace, 'com.acme.app');
          expect(result.android.compileSdk, 36);
          expect(result.android.minSdk, 24);
          expect(result.android.targetSdk, 36);
        });

        test('reads flavor dimensions', () {
          expect(result.android.flavorDimensions, <String>['environment']);
        });

        test('reads both flavors with their suffixes', () {
          expect(result.android.flavors.keys, <String>[
            'development',
            'production',
          ]);
          final dev = result.android.flavors['development']!;
          expect(dev.dimension, 'environment');
          expect(dev.applicationIdSuffix, '.dev');
          expect(dev.versionNameSuffix, '-dev');
          expect(dev.resValues['app_name'], 'Acme Dev');

          final prod = result.android.flavors['production']!;
          expect(prod.applicationIdSuffix, isNull);
          expect(prod.resValues['app_name'], 'Acme');
        });

        test('derives the effective application id per flavor', () {
          expect(
            result.android.flavors['development']!.effectiveApplicationId(
              result.android.applicationId,
            ),
            'com.acme.app.dev',
          );
          expect(
            result.android.flavors['production']!.effectiveApplicationId(
              result.android.applicationId,
            ),
            'com.acme.app',
          );
        });

        test('reads signing configs and build types', () {
          expect(result.android.signingConfigs.keys, <String>['release']);
          expect(result.android.signingConfigs['release']!.keyAlias, 'upload');
          expect(
            result.android.buildTypes,
            containsAll(<String>['release', 'debug']),
          );
        });

        test('reports no uncertainties for a fully literal build file', () {
          expect(result.uncertainties.map((u) => u.toString()), isEmpty);
        });
      });
    }
  });

  group('non-literal values become uncertainties, never guesses', () {
    test('an applicationId from an ext property is flagged, not invented', () {
      final result = parseKts('''
android {
    defaultConfig {
        applicationId = appId
    }
}
''');
      expect(
        result.android.applicationId,
        isNull,
        reason: 'must not guess a value it cannot see',
      );
      final uncertainty = result.uncertainties.single;
      expect(uncertainty.field, 'android.applicationId');
      expect(uncertainty.reason, contains('appId'));
      expect(uncertainty.remedy, contains('--deep'));
      expect(uncertainty.deepMayResolve, isTrue);
    });

    test('a Groovy ext-property applicationId is flagged', () {
      final result = parseGroovy('''
android {
    defaultConfig {
        applicationId project.ext.applicationId
    }
}
''');
      expect(result.android.applicationId, isNull);
      expect(result.uncertainties.single.field, 'android.applicationId');
    });

    test('a string interpolation is not a literal', () {
      final result = parseGroovy(r'''
android {
    defaultConfig {
        applicationId "com.acme.${flavorSuffix}"
    }
}
''');
      expect(result.android.applicationId, isNull);
      expect(result.uncertainties, hasLength(1));
    });

    test('a flavor created in a loop is reported as an incomplete list', () {
      final result = parseKts('''
android {
    productFlavors {
        listOf("dev", "prod").forEach { name ->
            create(name) { }
        }
        create("staging") { }
    }
}
''');
      // The one flavor it can name is kept; the loop is declared unreadable so
      // the user knows the list is not complete.
      expect(result.android.flavors.keys, contains('staging'));
      expect(
        result.uncertainties.map((u) => u.field),
        contains('android.productFlavors'),
      );
    });

    test('a non-literal flavor suffix is flagged against that flavor', () {
      final result = parseKts('''
android {
    productFlavors {
        create("dev") {
            applicationIdSuffix = suffixes["dev"]
        }
    }
}
''');
      expect(result.android.flavors['dev']!.applicationIdSuffix, isNull);
      expect(
        result.uncertainties.single.field,
        'android.flavors.dev.applicationIdSuffix',
      );
    });

    test('`apply from:` is noted because its contents were not read', () {
      final result = parseGroovy('''
apply from: "flavors.gradle"
android {
    defaultConfig { }
}
''');
      final note = result.uncertainties.firstWhere(
        (u) => u.severity == UncertaintySeverity.informational,
      );
      expect(note.reason, contains('flavors.gradle'));
    });

    test('a missing android block is a defect, not a crash', () {
      final result = parseKts('plugins { id("x") }\n');
      expect(result.android.exists, isFalse);
      expect(result.uncertainties.single.severity, UncertaintySeverity.defect);
    });
  });

  group('signing config shapes', () {
    test('recognises a properties-backed signing config as intentional', () {
      final result = parseKts('''
android {
    signingConfigs {
        create("release") {
            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = keystoreProperties["storePassword"] as String?
            keyAlias = keystoreProperties["keyAlias"] as String?
        }
    }
}
''');
      final config = result.android.signingConfigs['release']!;
      expect(config.readsFromProperties, isTrue);
      expect(config.storeFile, isNull);
      // Credentials deliberately kept out of the build file is the correct
      // shape, so it must not be reported as a problem.
      expect(result.uncertainties, isEmpty);
    });

    test('reads a signingConfig reference in both dialects', () {
      expect(
        parseKts('''
android {
  buildTypes {
    getByName("release") { signingConfig = signingConfigs.getByName("rel") }
  }
  productFlavors { create("dev") { signingConfig = signingConfigs.getByName("rel") } }
}
''').android.flavors['dev']!.signingConfig,
        'rel',
      );
      expect(
        parseGroovy('''
android {
  productFlavors { dev { signingConfig signingConfigs.rel } }
}
''').android.flavors['dev']!.signingConfig,
        'rel',
      );
    });
  });

  group('flavorDimensions shapes', () {
    test('reads += , = listOf, = [ ], and the Groovy bare form', () {
      String? dims(String body) => const GradleStructuralParser()
          .parse(
            'android {\n$body\n}',
            dsl: GradleDsl.kotlin,
            buildFilePath: 'b',
          )
          .android
          .flavorDimensions
          .join(',');

      expect(dims('flavorDimensions += "env"'), 'env');
      expect(dims('flavorDimensions = listOf("env", "tier")'), 'env,tier');
      expect(dims('flavorDimensions = ["env", "tier"]'), 'env,tier');
      expect(dims('flavorDimensions "env"'), 'env');
    });
  });

  group('real-world argument shapes', () {
    test('reads a Kotlin named-argument resValue', () {
      // Real projects write this form; a positional-only parser drops the
      // display name silently, which is worse than failing.
      final result = parseKts('''
android {
    productFlavors {
        create("development") {
            resValue(type = "string", name = "app_name", value = "Lahent Dev")
        }
    }
}
''');
      expect(
        result.android.flavors['development']!.resValues['app_name'],
        'Lahent Dev',
      );
      expect(result.uncertainties, isEmpty);
    });

    test('reads named arguments given out of order', () {
      final result = parseKts('''
android {
    productFlavors {
        create("dev") {
            resValue(value = "Acme Dev", type = "string", name = "app_name")
        }
    }
}
''');
      expect(result.android.flavors['dev']!.resValues['app_name'], 'Acme Dev');
    });

    test('reads Kotlin indexed manifestPlaceholders', () {
      final result = parseKts('''
android {
    productFlavors {
        create("dev") {
            manifestPlaceholders["deepLinkHost"] = "dev.lahent.sa"
        }
    }
}
''');
      expect(
        result.android.flavors['dev']!.manifestPlaceholders['deepLinkHost'],
        'dev.lahent.sa',
      );
    });

    test('reads a Groovy manifestPlaceholders map literal', () {
      final result = parseGroovy('''
android {
    productFlavors {
        dev {
            manifestPlaceholders = [deepLinkHost: "dev.lahent.sa"]
        }
    }
}
''');
      expect(
        result.android.flavors['dev']!.manifestPlaceholders['deepLinkHost'],
        'dev.lahent.sa',
      );
    });

    test('a non-literal placeholder is flagged rather than dropped', () {
      final result = parseKts('''
android {
    productFlavors {
        create("dev") {
            manifestPlaceholders["MAPS_API_KEY"] = localProperties.getProperty("k")
        }
    }
}
''');
      expect(result.android.flavors['dev']!.manifestPlaceholders, isEmpty);
      expect(
        result.uncertainties.single.field,
        'android.flavors.dev.manifestPlaceholders',
      );
    });
  });

  group('comments and strings do not confuse the parser', () {
    test('a commented-out flavor is not read as real', () {
      final result = parseKts('''
android {
    productFlavors {
        // create("ghost") { }
        create("real") { }
    }
}
''');
      expect(result.android.flavors.keys, <String>['real']);
    });

    test('a brace inside a resValue string does not break block matching', () {
      final result = parseKts('''
android {
    productFlavors {
        create("dev") {
            resValue("string", "app_name", "Acme { Dev }")
        }
    }
}
''');
      expect(
        result.android.flavors['dev']!.resValues['app_name'],
        'Acme { Dev }',
      );
    });
  });
}
