import 'package:taxiway/src/core/gradle/gradle_scanner.dart';
import 'package:test/test.dart';

void main() {
  group('block finding', () {
    test('finds a top-level block', () {
      const source = 'android {\n  compileSdk = 36\n}\n';
      final blocks = GradleScanner.blocksIn(source);
      expect(blocks, hasLength(1));
      expect(blocks.single.declaredName, 'android');
      expect(blocks.single.body.trim(), 'compileSdk = 36');
    });

    test('finds sibling blocks', () {
      const source = 'plugins {\n id("x")\n}\nandroid {\n a = 1\n}\n';
      expect(
        GradleScanner.blocksIn(source).map((b) => b.declaredName),
        <String>['plugins', 'android'],
      );
    });

    test('matches nested braces rather than the first close', () {
      const source = '''
android {
  defaultConfig {
    applicationId = "com.x"
  }
  buildTypes {
    release { }
  }
}
''';
      final android = GradleScanner.findBlock(source, 'android')!;
      expect(android.body, contains('buildTypes'));
      final inner = GradleScanner.blocksIn(
        android.body,
      ).map((b) => b.declaredName).toList();
      expect(inner, <String>['defaultConfig', 'buildTypes']);
    });

    test('ignores braces inside line comments', () {
      const source = '''
android {
  // productFlavors { fake { } }
  compileSdk = 36
}
''';
      final android = GradleScanner.findBlock(source, 'android')!;
      expect(GradleScanner.blocksIn(android.body), isEmpty);
      expect(android.body, contains('compileSdk = 36'));
    });

    test('ignores braces inside block comments', () {
      const source = '''
android {
  /* productFlavors {
       dev { }
     } */
  compileSdk = 36
}
''';
      final android = GradleScanner.findBlock(source, 'android')!;
      expect(GradleScanner.blocksIn(android.body), isEmpty);
    });

    test('ignores braces inside strings', () {
      const source = r'''
android {
  defaultConfig {
    resValue("string", "x", "a { b } c")
  }
}
''';
      final android = GradleScanner.findBlock(source, 'android')!;
      expect(
        GradleScanner.blocksIn(android.body).map((b) => b.declaredName),
        <String>['defaultConfig'],
      );
    });

    test('handles a Groovy GString interpolation containing braces', () {
      const source = r'''
android {
  defaultConfig {
    versionName "${project.version}"
  }
}
''';
      final android = GradleScanner.findBlock(source, 'android')!;
      expect(
        GradleScanner.blocksIn(android.body).map((b) => b.declaredName),
        <String>['defaultConfig'],
      );
    });

    test('handles triple-quoted strings', () {
      const source = '''
android {
  x = """
    not a { block }
  """
  defaultConfig { }
}
''';
      final android = GradleScanner.findBlock(source, 'android')!;
      expect(
        GradleScanner.blocksIn(android.body).map((b) => b.declaredName),
        <String>['defaultConfig'],
      );
    });

    test('returns null for a block that is not there', () {
      expect(GradleScanner.findBlock('android { }', 'productFlavors'), isNull);
    });

    test('survives an unbalanced brace without hanging', () {
      final blocks = GradleScanner.blocksIn('android {\n  defaultConfig {\n');
      expect(blocks, isEmpty);
    });
  });

  group('declaredName across both dialects', () {
    String? nameOf(String header) =>
        GradleScanner.blocksIn('$header {\n}\n').single.declaredName;

    test('Groovy bare identifier', () {
      expect(nameOf('dev'), 'dev');
    });

    test('KTS create()', () {
      expect(nameOf('create("dev")'), 'dev');
      expect(nameOf("create('dev')"), 'dev');
      expect(nameOf('create ( "dev" )'), 'dev');
    });

    test('KTS getByName, named, register, maybeCreate', () {
      expect(nameOf('getByName("release")'), 'release');
      expect(nameOf('named("release")'), 'release');
      expect(nameOf('register("staging")'), 'staging');
      expect(nameOf('maybeCreate("qa")'), 'qa');
    });

    test('Groovy quoted name', () {
      expect(nameOf('"dev"'), 'dev');
    });

    test('a loop header has no name and is flagged dynamic', () {
      final block = GradleScanner.blocksIn(
        'listOf("a","b").forEach { name ->\n}\n',
      ).single;
      expect(block.declaredName, isNull);
      expect(block.isDynamic, isTrue);
    });
  });

  group('offsets map back onto the source', () {
    test('body offsets bracket the block contents exactly', () {
      const source = 'android {\n  compileSdk = 36\n}\n';
      final block = GradleScanner.findBlock(source, 'android')!;
      expect(source.substring(block.bodyStart, block.bodyEnd), block.body);
      expect(source[block.bodyEnd], '}');
      expect(source.substring(block.headerStart), startsWith('android'));
    });
  });
}
