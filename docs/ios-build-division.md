# Spike: who builds the iOS archive

The Phase 2 plan rests on one assumption, and it is the highest-risk assumption
in the project: **`flutter build ipa` produces the archive and the `.ipa`, and
fastlane only signs and uploads.** If that were wrong, Phase 2 would change
shape entirely, so it was tested before any generator was written.

Verified 2026-09-09 against Flutter 3.47.2 (Dart 3.13.2), Xcode 26.6,
fastlane 2.238.0 — on a throwaway `flutter create` app for the archive and gym
questions, and on a real two-flavor CocoaPods app with real signing for the
export leg, which produced an actual signed `.ipa`.

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

So `gym` has nothing to add to the archive step, and taxiway generates the
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

Plus `match` in readonly mode for signing. `gym` never *archives* -- though it
may legitimately export, see the third shape below.

## The signed export, verified end to end

Confirmed on a real project rather than a scaffold: a two-flavor CocoaPods app
(Firebase, Google Maps, an entitlements file with push, associated domains and
in-app payments), signed with a genuine Apple Development identity.

```
flutter build ipa --release --no-pub --flavor development \
  --export-options-plist=<generated> lib/main_dev.dart
```

```
Xcode archive done.                    168.0s
* Built build/ios/archive/Runner.xcarchive (285.2MB)
[OK] App Settings Validation
     Version Number: 3.0.3   Build Number: 1
     Display Name: Lahent Dev
     Bundle Identifier: com.la-hent.client.dev
Building development IPA...             20.8s
* Built IPA to build/ios/ipa (25.4MB)
```

The artifact is properly signed, not an unsigned bundle:

```
Identifier=com.la-hent.client.dev
Authority=Apple Development: Shihab Kandil (CT29X3L3DC)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=76M2WGPM33
```

with `embedded.mobileprovision` naming the profile used. Export took 21 seconds
against 168 for the archive, which is the ratio that makes re-exporting cheap
and re-archiving expensive.

Two details a generated lane must get right:

- **The `.ipa` is named after `CFBundleDisplayName`, not the target.** This build
  produced `build/ios/ipa/Lahent Dev.ipa` -- a flavor's display name, spaces and
  all. A lane that hardcodes `Runner.ipa` finds nothing. Glob
  `build/ios/ipa/*.ipa` rather than construct the name.
- **Xcode 26 rewrites the export method.** `method: development` comes back as
  `method: "debugging"` in the `ExportOptions.plist` Xcode leaves beside the
  `.ipa`. The old names (`app-store`, `ad-hoc`, `development`, `enterprise`) are
  still accepted and normalised to the new ones (`app-store-connect`,
  `release-testing`, `debugging`, ...).

The earlier `errSecInternalComponent` that blocked this turned out to be a
per-key keychain ACL awaiting a one-time interactive grant, not a property of
the machine -- all three development identities sign non-interactively now.
Worth keeping in the classifier anyway, with the remedy:

```
security set-key-partition-list -S apple-tool:,apple: -s \
  -k <login password> ~/Library/Keychains/login.keychain-db
```

## A third shape: let `gym` do only the export

A real shipping Fastfile for the project above divides the work one notch
differently from this plan, and it works:

```ruby
flutter_build(type: "ipa", flavor: flavor, ...)   # flutter archives

build_app(
  skip_build_archive: true,                       # gym does NOT archive
  archive_path: "build/ios/archive/Runner.xcarchive",
  output_directory: "build/ios/ipa",
  export_method: "app-store",
  export_options: { provisioningProfiles: { bundle_id => profile_name } }
)
```

`skip_build_archive: true` is the whole difference between this and the broken
arrangement: gym exports a Flutter-made archive instead of trying to make one.

So there are two workable shapes, not one:

| | archive | export | upload |
|---|---|---|---|
| **A** -- this plan | `flutter build ipa --export-options-plist` | same command | fastlane |
| **B** -- the real project | `flutter build ipa` | `build_app(skip_build_archive: true)` | fastlane |
| **C** -- the trap | `build_app` | `build_app` | fastlane |

B has a real advantage: with `match`, the profile name is only known at lane
runtime, from `SharedValues::MATCH_PROVISIONING_PROFILE_MAPPING`, and gym's
`export_options:` takes it directly. A static `ExportOptions-<flavor>.plist` has
to have the name written into it ahead of time.

Which taxiway generates is still open.

## What the Android side does

The same project, confirming the plan without qualification -- `flutter build`
then `supply`, with these artifact paths:

| type | path |
|---|---|
| appbundle | `build/app/outputs/bundle/<flavor>Release/app-<flavor>-release.aab` |
| apk | `build/app/outputs/flutter-apk/app-<flavor>-release.apk` |
| mapping | `build/app/outputs/mapping/<flavor>Release/mapping.txt` |

Its package names also justify the two-base-id schema field: Android
`com.la_hent.client` against iOS `com.la-hent.client`, because an Android
`applicationId` may not contain a hyphen.

## Incidental finding

This spike is what surfaced the flavored-xcconfig defect described in
[`deviations.md`](deviations.md) — flavored builds were losing `FLUTTER_TARGET`,
every dart-define and both version numbers. It was found by planting a compile
error in `lib/main.dart` and watching a build that had been told to compile
`lib/main_prod.dart` fail on it.
