import 'package:shipway/src/core/config/shipway_config.dart';
import 'package:shipway/src/generators/version_resolver.dart';
import 'package:test/test.dart';

String render(
  VersioningStrategy strategy, {
  String platform = 'ios',
  bool sync = true,
}) => VersionResolver.render(
  strategy: strategy,
  syncIosAndroid: sync,
  platform: platform,
);

void main() {
  test('the marketing version always comes from pubspec', () {
    // A version name is a decision somebody makes, not something to derive.
    for (final strategy in VersioningStrategy.values) {
      final ruby = render(strategy);
      expect(ruby, contains('def version_name'), reason: strategy.name);
      expect(ruby, contains('pubspec_version[:name]'), reason: strategy.name);
    }
  });

  test('an unreadable pubspec version fails with what to fix', () {
    // Every release needs a version to claim, and the regex failing silently
    // would produce a build numbered nil.
    expect(render(VersioningStrategy.increment), contains('user_error!'));
    expect(render(VersioningStrategy.increment), contains('version: x.y.z+n'));
  });

  test('an explicit build number always wins', () {
    // Whatever the strategy, passing one is how a re-run reuses a number
    // rather than minting a fresh one the store has never heard of.
    for (final strategy in VersioningStrategy.values) {
      for (final platform in const <String>['ios', 'android']) {
        final ruby = render(strategy, platform: platform);
        expect(
          ruby,
          contains('def build_number(requested'),
          reason: '${strategy.name}/$platform',
        );
        expect(
          ruby,
          contains('value = requested.to_s.strip'),
          reason: '${strategy.name}/$platform takes no requested value',
        );
      }
    }
  });

  group('increment', () {
    test('takes pubspec at its word', () {
      final ruby = render(VersioningStrategy.increment);
      expect(ruby, contains('pubspec_version[:code]'));
      // Nothing remote: this is the strategy that works offline.
      expect(ruby, isNot(contains('latest_testflight_build_number')));
      expect(ruby, isNot(contains('google_play_track_version_codes')));
    });
  });

  group('timestamp', () {
    test('is monotonic without asking anything', () {
      final ruby = render(VersioningStrategy.timestamp);
      expect(ruby, contains('%y%m%d%H%M'));
      // UTC, or a build made either side of a timezone change goes backwards.
      expect(ruby, contains('Time.now.utc'));
    });
  });

  group('remote', () {
    test('iOS asks App Store Connect', () {
      final ruby = render(VersioningStrategy.remote);
      expect(ruby, contains('latest_testflight_build_number'));
      // A brand new app has no builds; without this the first upload fails.
      expect(ruby, contains('initial_build_number: 0'));
      expect(ruby, contains('latest.to_i + 1'));
    });

    test('Android asks Play, and takes the highest code', () {
      // `.first` is what the plan said. The API does not promise an order, and
      // the wrong element produces a code Play rejects as non-increasing.
      final ruby = render(VersioningStrategy.remote, platform: 'android');
      expect(ruby, contains('google_play_track_version_codes'));
      expect(ruby, contains('.max.to_i + 1'));
      // The expression, not the prose: the comment above it names `.first`
      // precisely because that is the trap.
      expect(ruby, isNot(contains('codes[0]')));
      expect(ruby, isNot(contains('codes.first')));
    });

    test('Android reads the service account by the shared name', () {
      expect(
        render(VersioningStrategy.remote, platform: 'android'),
        contains('ENV.fetch("PLAY_SERVICE_ACCOUNT_JSON_PATH")'),
      );
    });

    test('each platform gets only its own lookup', () {
      // Rendering both would put an action in a Fastfile that cannot run it.
      expect(
        render(VersioningStrategy.remote, platform: 'ios'),
        isNot(contains('google_play_track_version_codes')),
      );
      expect(
        render(VersioningStrategy.remote, platform: 'android'),
        isNot(contains('latest_testflight_build_number')),
      );
    });
  });

  test('sync_ios_android is stated either way', () {
    expect(render(VersioningStrategy.increment, sync: true), contains('once'));
    expect(
      render(VersioningStrategy.increment, sync: false),
      contains('numbers itself'),
    );
  });
}
