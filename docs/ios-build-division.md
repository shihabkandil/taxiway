# Spike: who builds the iOS archive

The Phase 2 plan rests on one assumption, and it is the highest-risk assumption
in the project: **`flutter build ipa` produces the archive and the `.ipa`, and
fastlane only signs and uploads.** If that were wrong, Phase 2 would change
shape entirely, so it was tested before any generator was written.

Verified 2026-09-09 against Flutter 3.47.2 (Dart 3.13.2), Xcode 26.6,
fastlane 2.238.0, on a `flutter create` app.

**The assumption holds.** The reasoning the plan gives for it is out of date,
and the failure it names no longer appears — a different one does, earlier and
louder. Details below.

## What `flutter build ipa` actually does

Two phases, and it says so itself. With `--no-codesign` it stops after the
first and prints `Codesigning disabled with --no-codesign, skipping IPA.`

1. **Archive.** Produces `build/ios/archive/Runner.xcarchive`, well-formed:
   `ArchiveVersion 2`, an `ApplicationProperties` dict naming
   `Applications/Runner.app` with the bundle id, version and build number, and
   `dSYMs/` for `App.framework`, `Flutter.framework` and `Runner.app`.
2. **Export.** Runs, from `flutter_tools/lib/src/commands/build_ios.dart`:

   ```
   xcodebuild -exportArchive \
     -allowProvisioningDeviceRegistration -allowProvisioningUpdates \
     -archivePath <archive> -exportPath <out> -exportOptionsPlist <plist>
   ```

   That is the same command `gym` would run to export. `--export-options-plist`
   is passed straight through; `--export-method` generates a plist instead, and
   the two flags are mutually exclusive.

So there is nothing left for `gym` to add, and taxiway generates the
`ExportOptions-<flavor>.plist` that `--export-options-plist` consumes.

## Why letting `gym` drive the build breaks

The plan attributes this to `gym` producing a malformed archive, diagnosed by:

```
exportArchive: The data couldn't be read because it isn't in the correct format
```

That is not what happens on a current Flutter, and the archive is not the
problem. Two separate findings replace it.

### 1. On a fresh clone it fails at package resolution, not at export

Flutter 3.47 resolves the Flutter framework and plugins through Swift Package
Manager, from `ios/Flutter/ephemeral/`, which is git-ignored and written by
`flutter build`. A `gym` that runs before any `flutter` command has nothing to
resolve against:

```
xcodebuild: error: Could not resolve package dependencies:
  the package at '.../ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage'
  cannot be accessed (doesn't exist in file system)
```

Exit status 74, before a single file compiles. This is the signature to seed the
error classifier with; the plan's `exportArchive` string belongs there too, but
as the older CocoaPods-era form.

### 2. After a `flutter build`, `gym` succeeds — and that is the dangerous case

Run `gym` once `flutter build` has populated `ios/Flutter/`, and it produces an
archive **structurally identical** to Flutter's own: same `ArchiveVersion`, same
`ApplicationProperties`, same dSYMs. Nothing fails.

But `ios/Flutter/Generated.xcconfig` — written by whichever `flutter build` ran
last, and marked *"generated file; do not edit or check into version control"* —
is what carries:

```
FLUTTER_TARGET=lib/main_dev.dart
DART_DEFINES=<base64 of ENV=dev, API_URL=..., FLUTTER_APP_FLAVOR=dev, ...>
FLUTTER_BUILD_NAME=1.0.0
FLUTTER_BUILD_NUMBER=1
```

`gym` has no way to set any of it. A `gym(scheme: "prod")` lane run after a dev
build compiles **dev's** entrypoint and **dev's** dart-defines into an archive
stamped with prod's bundle id and display name. It exits zero. Nothing in the
log says which Dart code went in.

That is the real argument for the division of labor, and it is stronger than a
build that fails: a build that fails gets fixed.

## What fastlane is left to do

Upload an artifact that already exists — confirmed present in the installed
fastlane:

| Action | Option | Notes |
|---|---|---|
| `upload_to_testflight` / `pilot` | `ipa:` (`PILOT_IPA`) | also `skip_waiting_for_build_processing` |
| `upload_to_play_store` / `supply` | `aab:`, `apk:`, `aab_paths:` | plus `track`, `release_status`, `rollout` |
| `firebase_app_distribution` | plugin 1.0.0 installed | service-account JSON, not the deprecated token |

Plus `match` in readonly mode for signing. No `gym`, ever.

## Not yet verified: the signed export

Every result above was obtained with `--no-codesign` or `skip_codesigning`,
because signing on this machine fails before it reaches the export step:

```
.../App.framework/App: replacing existing signature
.../App.framework/App: errSecInternalComponent
```

The login keychain is unlocked and holds three valid Apple Development
identities; a bare `codesign` of a trivial binary fails the same way, so this is
the private key's ACL refusing a non-interactive process rather than anything to
do with Flutter or taxiway. Clearing it needs the login password:

```
security set-key-partition-list -S apple-tool:,apple: -s \
  -k <login password> ~/Library/Keychains/login.keychain-db
```

What remains untested is therefore the export leg only — that
`xcodebuild -exportArchive` with a taxiway-written `ExportOptions.plist` yields
a `.ipa`. The archive it consumes is verified well-formed, and the command line
is read from Flutter's own source, so the risk is low; but it is not zero, and
it should be closed before the fastlane generators are trusted end to end.

`errSecInternalComponent` belongs in the error classifier with the remedy above:
it is the failure a developer hits the first time they run a build from a script
rather than from Xcode, and it names nothing they could usefully search for.

## Incidental finding

This spike is what surfaced the flavored-xcconfig defect described in
[`deviations.md`](deviations.md) — flavored builds were losing `FLUTTER_TARGET`,
every dart-define and both version numbers. It was found by planting a compile
error in `lib/main.dart` and watching a build that had been told to compile
`lib/main_prod.dart` fail on it.
