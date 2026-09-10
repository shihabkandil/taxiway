# `taxiway.yaml` reference

Schema `version: 1`.

Every `*_ref` field names an environment variable or keychain key — **never a
value**. A validator rejects any `*_ref` that looks like a secret rather than a
name (contains `-----BEGIN`, exceeds 100 characters, decodes as base64 of more
than 64 bytes, or matches a known credential prefix), because this file is
committed and a pasted key in it is a disclosed key.

`taxiway import` derives this file from a project. Anything the readers could
not determine is **left out** rather than guessed.

## Full example

```yaml
version: 1

project:
  name: acme_app              # from pubspec.yaml
  pubspec: pubspec.yaml       # source of version and build number
  flutter_min: "3.35.0"       # doctor enforces this floor when set

apps:                         # keyed by app id; a single-app repo uses `main`
  main:
    path: .

    android:
      application_id: com.acme.app     # defaultConfig.applicationId, unsuffixed
    ios:
      bundle_id: com.acme.app          # PRODUCT_BUNDLE_IDENTIFIER, unsuffixed
      export: gym                      # gym | flutter — who turns the archive into an .ipa

    flavors:
      dev:
        suffix: .dev                   # appended to the base id on both platforms
        version_name_suffix: "-dev"    # Android versionNameSuffix
        dimension: environment         # omit unless it is not `environment`
        display_name: "Acme Dev"       # app_name on Android, CFBundleDisplayName on iOS
        entrypoint: lib/main_dev.dart  # omit when it is lib/main_<flavor>.dart
        dart_defines: { ENV: dev, API: "https://dev.api" }
        icon: assets/icon/dev.png
        firebase:
          android: android/app/src/dev/google-services.json
          ios: ios/config/dev/GoogleService-Info.plist
      prod:
        suffix: ""                     # the unsuffixed production flavor
        display_name: "Acme"

    signing:
      ios:
        match_git_url: git@github.com:acme/certs.git
        match_storage: git             # git | googlecloud | s3
        team_id: ABCDE12345
        api_key:
          key_id_ref: ASC_KEY_ID
          issuer_id_ref: ASC_ISSUER_ID
          p8_ref: ASC_KEY_P8_BASE64    # names the secret holding the base64 .p8
      android:
        keystore_ref: ANDROID_KEYSTORE_BASE64
        key_properties:
          store_password_ref: ANDROID_STORE_PASSWORD
          key_password_ref: ANDROID_KEY_PASSWORD
          key_alias: upload            # not a secret, so a literal

    targets:
      testflight:
        groups: [internal, qa]
        distribute_external: false
        changelog_from: git            # git | file | prompt
      appstore:
        submit_for_review: false
        metadata_path: ios/fastlane/metadata
      play:
        track: internal                # internal | alpha | beta | production
        release_status: draft          # draft | completed | inProgress | halted
        rollout: 0.1                   # user fraction; supply derives the status
        artifact: aab                  # aab | apk
        service_account_ref: PLAY_SERVICE_ACCOUNT_JSON
      firebase:
        android_app_id_ref: FB_ANDROID_APP_ID
        ios_app_id_ref: FB_IOS_APP_ID
        groups: [testers]

    versioning:
      strategy: increment              # timestamp | increment | remote
      sync_ios_android: true           # keep CFBundleVersion == versionCode

secrets:
  dotenv: .env.{flavor}                # `{flavor}` substituted at resolution
  keychain: true

notify:
  slack_webhook_ref: SLACK_WEBHOOK

ci:
  environment: persistent      # workstation | ci | persistent
```

## Minimal valid config

```yaml
version: 1
project:
  name: minimal_app
apps:
  main:
```

A map entry written with no body — `main:` or `prod:` — means "this exists and
takes every default".

## Validation rules beyond the schema

These are semantic and cannot be expressed as a shape:

- `version` must be `1`.
- `apps` must be non-empty, and when there is more than one, exactly one must be
  named `main` — otherwise no command knows what to act on without `--app`.
- Flavor names must match `^[A-Za-z][A-Za-z0-9]*$`. Both Gradle product flavors
  and Xcode build-configuration names derive from them, and Flutter matches them
  **case-sensitively**.
- Two flavors may not share a `suffix`. They would produce one application id,
  and installing the second would silently replace the first on a device.
- `rollout` must be in `(0, 1]`, mirroring `supply`'s own check. It does **not**
  require `release_status: inProgress`: supply derives the status from the user
  fraction on both the upload and the promote path, setting `inProgress` below 1
  and `completed` at 1. `taxiway release --dry-run` shows the status that will
  actually be used.
- `targets.testflight.distribute_external` requires at least one entry in
  `groups`. Without one the build uploads and then fails at distribution, which
  is after the slowest part of the job.
- No `*_ref` may hold a secret rather than name one.

## Fields added beyond the original plan

Each of these exists because a real project could not otherwise be described
faithfully, and `taxiway status` reported drift immediately after a clean
import. Import fidelity is a correctness gate, so a value the readers can find
must have somewhere to live.

| Field | Why |
|---|---|
| `apps.<id>.android.application_id` and `apps.<id>.ios.bundle_id` | The plan assumed one base id with a per-flavor suffix. The two platforms genuinely disagree: an Android `applicationId` may not contain a hyphen, so a project whose bundle id does (`com.acme-co.app` on iOS, `com.acme_co.app` on Android) needs two base ids. |
| `flavors.<name>.entrypoint` | Flavors named `development`/`production` very often have `main_dev.dart`/`main_prod.dart`. Assuming `main_<flavor>.dart` would build the wrong app under the right bundle id — a failure that looks like success. |
| `flavors.<name>.version_name_suffix` | Read from Gradle's `versionNameSuffix`. Without it the round trip loses the value and `status` reports drift on a freshly imported project. |
| `flavors.<name>.dimension` | Recorded only when it is not `environment`, the dimension taxiway generates. Projects using another name would otherwise drift forever. |

## `ios.export` — who exports the `.ipa`

`flutter build ipa` always produces the `.xcarchive`; only the export leg is in
question, and both answers are verified working.

`gym` (the default) has Flutter archive with `--no-codesign` and then
`build_app(skip_build_archive: true)` export it. The provisioning profile name
is read from match's `MATCH_PROVISIONING_PROFILE_MAPPING` at lane runtime, so it
cannot go stale, and gym also writes a dSYM zip.

`flutter` has `flutter build ipa --export-options-plist=<generated>` do both
legs in one command, with no gym in the build lane. It needs the profile name
written into `ios/ExportOptions-<flavor>.plist` ahead of time, which taxiway
generates only under this setting — a stale plist sitting beside a gym export
would be a trap.

Two consequences worth knowing:

- The exported filename differs. Flutter names it after `CFBundleDisplayName`
  (`Acme Dev.ipa`), gym after the product target (`Runner.ipa`). Generated lanes
  glob `build/ios/ipa/*.ipa` rather than predict it.
- Under `gym`, the lane must pass `export_team_id`. An archive built with
  `--no-codesign` records an empty `Team`, so export has none to infer and fails
  with `exportArchive No Team Found in Archive`.

## How `display_name` reaches each platform

On Android it becomes a `resValue("string", "app_name", …)` per flavor, and the
generated block enables `buildFeatures { resValues = true }` because AGP 8+
generates no resource values without it.

On iOS it becomes an `APP_DISPLAY_NAME` build setting per configuration, and
`ios/Runner/Info.plist` is pointed at `$(APP_DISPLAY_NAME)` — Xcode expands
build-setting references in the plist at build time, which is the only mechanism
that varies the home-screen name per configuration.

That plist rewrite has a trap worth knowing about: once the literal is replaced,
any configuration that does **not** define `APP_DISPLAY_NAME` produces an app
with an empty name. taxiway therefore seeds the unflavored `Debug`, `Release`
and `Profile` configurations with whatever the plist said before — once, as a
migration. It does not re-derive that value on later runs, both because the
package name is not the display name and because you may have changed it since.
