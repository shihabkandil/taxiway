/// A store requirement that has, or will, come into force on a date.
class PlatformDeadline {
  const PlatformDeadline({
    required this.id,
    required this.summary,
    required this.effective,
    required this.sourceUrl,
    this.extendedTo,
  });

  final String id;

  /// One line, phrased as the requirement itself.
  final String summary;

  /// When the requirement started, or starts, being enforced.
  final DateTime effective;

  /// Where this was read from.
  final String sourceUrl;

  /// A published extension, where the platform granted one.
  final DateTime? extendedTo;

  /// The date that actually binds.
  DateTime get enforcedFrom => extendedTo ?? effective;

  bool isActiveOn(DateTime date) => !date.isBefore(enforcedFrom);
}

/// Store deadlines and version floors, in one place with provenance.
///
/// These are facts about the world that go stale, not facts about this
/// codebase. `doctor` prints [lastVerified] so a user can see whether the tool
/// is reasoning from current information — a checker that is confidently wrong
/// about a submission deadline is worse than one that admits its age.
abstract final class PlatformDeadlines {
  /// When a human last checked every entry below against its source.
  static final DateTime lastVerified = DateTime.utc(2026, 9, 8);

  /// Minimum Xcode for App Store Connect submissions.
  static const ToolFloor xcode = ToolFloor(
    id: 'xcode',
    name: 'Xcode',
    minimum: '26.0.0',
    reason:
        'App Store Connect requires apps built with Xcode 26 / the iOS 26 '
        'SDK.',
    sourceUrl: 'https://developer.apple.com/news/upcoming-requirements/',
  );

  /// Minimum `targetSdk` for Play submissions.
  static const int playTargetSdk = 36;

  /// Minimum Gradle the current Flutter stable will build with.
  ///
  /// Flutter raises this floor over time and fails the build outright when a
  /// project's wrapper is below it, so it belongs here with the other facts
  /// about the world that go stale rather than in a check's own source.
  static const ToolFloor gradleWrapper = ToolFloor(
    id: 'gradle_wrapper',
    name: 'Gradle wrapper',
    minimum: '8.14.0',
    reason:
        'Flutter refuses to build when the project Gradle version is below '
        'its minimum.',
    sourceUrl: 'https://docs.flutter.dev/release/breaking-changes',
  );

  static final PlatformDeadline appStoreXcode26 = PlatformDeadline(
    id: 'app-store-xcode-26',
    summary: 'App Store Connect requires builds made with Xcode 26 or later.',
    effective: DateTime.utc(2026, 4, 28),
    sourceUrl: 'https://developer.apple.com/news/upcoming-requirements/',
  );

  static final PlatformDeadline playTargetApi36 = PlatformDeadline(
    id: 'play-target-api-36',
    summary:
        'Google Play requires new and updated apps to target API level '
        '$playTargetSdk (Android 16).',
    effective: DateTime.utc(2026, 8, 31),
    extendedTo: DateTime.utc(2026, 11, 1),
    sourceUrl:
        'https://developer.android.com/google/play/requirements/target-sdk',
  );

  static final List<PlatformDeadline> all = <PlatformDeadline>[
    appStoreXcode26,
    playTargetApi36,
  ];

  /// Days since [lastVerified], for the staleness note `doctor` prints.
  static int ageInDaysOn(DateTime now) =>
      now.toUtc().difference(lastVerified).inDays;

  /// Past this, the data is old enough that a user should re-check it.
  static const int staleAfterDays = 90;

  static bool isStaleOn(DateTime now) => ageInDaysOn(now) > staleAfterDays;
}

/// A minimum tool version shipway enforces, with the reason it exists.
class ToolFloor {
  const ToolFloor({
    required this.id,
    required this.name,
    required this.minimum,
    required this.reason,
    required this.sourceUrl,
  });

  final String id;
  final String name;

  /// Parsed lazily by the check that uses it.
  final String minimum;

  final String reason;
  final String sourceUrl;
}
