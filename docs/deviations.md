# Deviations from the implementation plan

Each entry records a place where the built thing differs from
`docs/research.md` and the Phases 0–3 plan, and why. Kept so a reader of the
plan is not surprised by the code, and so a deviation is a decision rather than
a drift.

## Dart SDK floor is 3.8, not 3.6

The plan sets Dart ≥ 3.6 and separately pins `json_serializable` 6.14.1. Those
are inconsistent: 6.14.1 requires SDK `^3.8.0`. Taking the pinned dependency
versions, the package declares `sdk: ^3.8.0` and `doctor`'s Dart check uses the
same floor, in one place.

The alternative — an older `json_serializable` — would have meant unpinning a
version the plan states explicitly.

## The Gradle init script is Groovy, not Kotlin DSL

The plan names `tool/gradle/taxiway_dump.gradle.kts`. It is
`tool/gradle/taxiway_dump.gradle`, written in Groovy.

The script reads AGP's `android` extension **reflectively**, after the project
has been evaluated. Groovy's dynamic property access does this with no AGP types
on its own classpath, so one script works identically against a Kotlin-DSL or a
Groovy-DSL build. A Kotlin init script would need compile-time types it cannot
have — it would have to declare a dependency on AGP, pinned to a version, and
would then break on projects using a different one.

## `--deep` does not pass `--offline`

An early version did, reasoning that a read should not touch the network. That
was wrong: a Flutter Android build resolves the Kotlin and Flutter Gradle
plugins from the network, and `--offline` turns a working project into a failed
deep read for anyone without a fully warm cache. Verified against a real
project, where it failed to resolve `org.jetbrains.kotlin.jvm`.

`--no-daemon` is still passed: a read must not leave a daemon running against a
project it only meant to look at.

## The dependency-direction test encodes a DAG, not a chain

The plan states the direction as
`cli → core → {inspect, generators} → platform → secrets`. Read literally as
"each layer may only import to its right", that is not satisfiable — every
reader needs `core`'s `ProcessRunner` and `ProjectModel`.

`test/unit/architecture/dependency_direction_test.dart` encodes the DAG the
arrow describes instead: `core` is the shared base that imports nothing
internal, `cli` is the outermost layer, and each layer in between names exactly
what it may import. The plan's one hard rule — nothing in `core` imports `cli` —
is asserted separately.

## Config fields added beyond the plan's schema

Four, each forced by a real project failing the import-fidelity gate. They are
documented with their reasons in [`config-schema.md`](config-schema.md).

## `doctor` gained a Gradle wrapper check

Not in the plan's check table. Added because a real project failed to build and
to deep-read for exactly this reason: its wrapper was Gradle 8.12 against
Flutter's 8.14 minimum. Flutter's own error names a Gradle version and nothing a
user would think to search for, and the same condition silently disables
`taxiway import --deep`.

The floor lives in `platform_deadlines.dart` with the other facts about the
world that go stale, so it carries a `lastVerified` date like the rest.

## No per-flavor `ios/Flutter/<flavor>.xcconfig` is generated

The plan's artifact inventory lists one, and taxiway wrote one and attached it
to each `<BuildType>-<flavor>` configuration as its base configuration. That is
wrong, and the way it is wrong is silent.

A build configuration has exactly one base configuration. Attaching taxiway's
displaces the stock `ios/Flutter/Debug.xcconfig` / `Release.xcconfig`, and those
are the files that `#include "Generated.xcconfig"` — the file `flutter build`
writes, carrying `FLUTTER_TARGET`, `DART_DEFINES`, `FLUTTER_BUILD_NAME` and
`FLUTTER_BUILD_NUMBER`. A flavored build therefore:

- compiled `lib/main.dart` no matter what `-t` said, so `main_<flavor>.dart` was
  generated and then ignored — the wrong app under the right bundle id;
- dropped every `--dart-define`;
- produced an `Info.plist` with **no** `CFBundleShortVersionString` and no
  `CFBundleVersion`, because Xcode drops a key whose value expands to empty.
  App Store Connect rejects that upload.

None of it is visible in a build log: `flutter build ipa` prints
`Version Number: Missing` in its App Settings Validation block and exits 0.

In a CocoaPods project the same displacement also drops the
`#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.<config>.xcconfig"`
line, along with anything the project itself keeps in those files.

So flavor configurations now inherit the base configuration of the build type
they derive from, which is what a hand-made flavor setup does — verified against
a real two-flavor project, where `Release-development` points at the stock
`Release.xcconfig` and every per-flavor value lives in the configuration's own
`buildSettings`. taxiway does the same: bundle id, `APP_DISPLAY_NAME` and
`DEVELOPMENT_TEAM` are written onto the configuration, which is also where they
have to be for a target's own settings to win.

The inherited reference is read from the project rather than assumed, so a
project that points `Profile` somewhere other than `Release.xcconfig` keeps
doing so.

Projects generated by the earlier behaviour are repaired in place: the bridge
re-asserts the inherited base configuration on every run, and
`LegacyXcconfigCleanup` deletes the orphaned `<flavor>.xcconfig` — but only when
taxiway wrote it and it is still byte-for-byte what taxiway wrote. One that has
been edited is left alone and reported, because deleting somebody's build
settings is worse than leaving a file nothing references.
