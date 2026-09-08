# Research: A Local-First Flutter CI/CD File Generator & Runner

> Source research document for **Taxiway** (written under the working name "shipyard";
> the project was renamed on 2026-09-08 because `shipyard` is taken on pub.dev).
> Phases 0–3 are planned in detail elsewhere and supersede the phase numbering below.
> This document remains the reference for **Phases 4–6**, the competitive analysis,
> and the error-classifier catalog.

## TL;DR

- **Build it — the niche is genuinely empty.** No existing tool combines flavor-aware
  scaffolding, a guided iOS `match` wizard, generated-and-invoked fastlane lanes,
  multi-target deployment (TestFlight/App Store/Play tracks/Firebase), and declarative
  *local* pipelines behind one professional Dart CLI. Each piece exists
  (flutter_flavorizr, Codemagic CLI tools, fastlane, very_good_cli); the local
  orchestration does not.
- **The baseline architecture is sound**, with a handful of research-driven corrections:
  divide labor so `flutter build ipa/appbundle` produces the artifact and fastlane only
  signs/uploads; treat `dart pub global activate` as legacy (ship native
  `dart compile exe` binaries first); require a modern `xcodeproj` gem (≥ 1.26.0) and
  Ruby ≥ 3.0 for fastlane; and default Firebase auth to service-account JSON (the CI
  token is deprecated).
- **Sequence the work in seven phases** (0 skeleton+doctor → 1 flavors → 2 fastlane+builds
  → 3 secrets/signing wizard → 4 deploy targets → 5 pipelines → 6 polish), with hard 2026
  platform deadlines baked into `doctor`: Apple's Xcode 26/iOS 26 SDK upload requirement
  (from 28 April 2026) and Google Play's target-API-36 requirement (from 31 August 2026,
  extendable to 1 November 2026).

## Key Findings

1. **Prior art leaves a clear gap.** flutter_flavorizr scaffolds flavors but does no
   deployment; flutter_distributor packages/releases but isn't flavor/match/track-oriented;
   Codemagic CLI tools are excellent open-source deploy utilities but are Python and not a
   fastlane generator; very_good_cli/sidekick are CLI-framework references, not CI/CD. The
   orchestrator layer is the product.

2. **iOS build division of labor is the single most important technical decision.**
   Multiple documented failures (`exportArchive: The data couldn't be read because it isn't
   in the correct format`) occur when fastlane `gym` wraps a Flutter build. The reliable
   pattern used by teams and Codemagic is: `flutter build ipa --export-options-plist=<plist>`
   produces the archive, and fastlane's `pilot`/`deliver` handle upload only, with `match`
   (readonly) supplying signing.

3. **App Store Connect API key auth is now effectively mandatory** for automation
   (issuer ID + key ID + `.p8`, via `app_store_connect_api_key`, with
   `is_key_content_base64: true` when the `.p8` is base64 in an env var). It is strongly
   preferred over Apple ID + app-specific password because it avoids 2FA session
   brittleness and works with `match`, `pilot`, and `deliver`.

4. **Fastlane is actively maintained** (releases continuing through 2026; RubyGems shows
   `fastlane 2.238.0 · August 12, 2026`), so building on it is safe — but it now
   **requires Ruby ≥ 3.0** (the release dropping Ruby 2.7 states "[Ruby] Ruby 3.0 is now
   the minimum") and the docs warn it "will soon require Ruby 3.3.0 or newer." `doctor`
   must version-check Ruby, not just detect it.

5. **Xcode 16's "synchronized folders" changed the project file format** (new
   `PBXFileSystemSynchronizedRootGroup` ISA, `objectVersion` bumped 60→70). This broke
   older `xcodeproj` gems with `unknown ISA PBXFileSystemSynchronizedRootGroup`. The fixed
   gem is **xcodeproj 1.26.0** (released October 27, 2024); 1.27.0 followed October 31,
   2024. Manual `project.pbxproj` mutation via the gem remains the standard approach for
   Flutter iOS; the tool must simply require the modern gem.

6. **Firebase App Distribution CI-token auth is deprecated;** the newer fastlane plugin no
   longer uses the Firebase CLI and expects a **Google service-account JSON**
   (`service_credentials_file` or `GOOGLE_APPLICATION_CREDENTIALS`). Tokens produce
   `App Distribution could not generate credentials from the refresh token` failures.

7. **Distribution best practice for the tool itself has shifted.** As of Dart 3.10,
   dart.dev labels `dart pub global` as legacy in favor of `dart install` (AOT,
   self-contained). Ship **native `dart compile exe` binaries** via Homebrew tap +
   installer script + GitHub Releases as primary, with pub activation secondary.

## Details

### Validated vs. Corrected Assumptions

**Validated by research:**

- **Dart CLI with `args` + `mason`/`mason_logger`.** very_good_cli itself depends on
  `args`, `mason`, `mason_logger`, `cli_completion`, `pub_updater`, `checked_yaml`, and
  `pubspec_parse` — nearly the exact proposed toolset. This is the proven mainstream
  pattern. *(Taxiway later diverged: plain Dart templates, no mason bricks.)*
- **Fastlane as an internal implementation detail** behind generated lanes referencing
  `ENV[...]` only. Sound and safe given active maintenance.
- **Secrets never in generated files.** Strongly validated; fastlane idioms (`ENV`, dotenv
  `.env.<flavor>`, `MATCH_PASSWORD`) support name-only references.
- **`xcodeproj` Ruby gem for iOS mutation** rather than hand-parsing `project.pbxproj` —
  exactly how flutter_flavorizr works internally (via its `dart_xcodeproj` dependency
  shelling to the Ruby gem). Study its processors as reference.
- **Build-number strategy querying stores** — `latest_testflight_build_number` + 1 and
  `google_play_track_version_codes[0]` + 1 are the canonical actions; the community
  `fastlane-plugin-get_new_build_number` unifies this across stores.
- **Idempotent generation with managed blocks + a content-hash lockfile** — matches
  mason's conflict model and the `--set-exit-if-changed` idiom.

**Corrected / refined:**

1. **`dart pub global activate` is now "legacy"** (Dart 3.10 recommends `dart install`).
   Ship native binaries first.
2. **Require `xcodeproj` gem ≥ 1.26.0** and warn on `objectVersion` 70 projects (Xcode 16
   synchronized folders); workaround if needed is reverting 70→60 in the file.
3. **`doctor` must check Ruby ≥ 3.0** (push toward 3.3 for fastlane).
4. **Default Firebase auth to service-account JSON**, not the deprecated CLI token.
5. **`flutter build ipa` produces the archive; fastlane uploads** — do not let `gym` drive
   the Flutter build.
6. **Design the schema for monorepos now** (top-level `apps:` map) even if multi-app
   orchestration ships later, to avoid a painful migration.

### Prior Art / Competitive Analysis

| Tool | What it does | What it does NOT do | License | Reuse recommendation |
|---|---|---|---|---|
| **flutter_flavorizr** | Scaffolds Android product flavors + iOS schemes/configs/xcconfig, dart entrypoints, per-flavor Firebase config; uses Ruby `xcodeproj` gem internally | No deployment, no fastlane generation, no secrets, no pipelines; works best on clean projects | MIT | **Reference / optional delegate.** Study its processors; consider invoking or reimplementing. |
| **flutter_distributor** | Packaging/distribution for desktop + mobile (`dart run flutter_distributor release`) | Not focused on flavors, match wizardry, or store-track granularity | MIT-family | **Partial reference**, not a base. |
| **fastlane-plugin-flutter_version** | Reads pubspec version/build for Fastfiles | Tiny scope | MIT | **Reuse directly** inside generated Fastfiles. |
| **Codemagic CLI tools** | Open-source Python utilities (`app-store-connect`, `google-play`, `xcode-project`, build-number increment, `use-profiles`, keychain); run locally or any CI | Python; not a flavor scaffolder or fastlane generator; no guided match wizard | Open source | **Strong reference & optional shell-out**; basis of a future fastlane-free path. |
| **sidekick (phntmxyz)** | Generates a per-project `args`-based Dart CLI | Not CI/CD/deploy; you write automation | MIT | **Architectural reference** for command ergonomics. |
| **very_good_cli** | Dart command-runner reference; mason templating; testing patterns | Not CI/CD | MIT | **Primary architectural template** (structure, testing, completion, self-update). |
| **melos** | Dart/Flutter monorepo task runner | Not deploy/signing | MIT | **Interoperate** for monorepo detection; don't reimplement. |
| **Shorebird** | Code push / OTA Dart updates (`shorebird release`/`patch`) | Not store deployment or signing; complementary | Proprietary SaaS + OSS | **Interoperate later** as an optional deploy target. |
| **fastlane** | The signing/upload engine (match, pilot, deliver, supply) | Not Flutter-aware; Ruby; poor error surface | MIT | **Core dependency** (generated + invoked), wrapped behind the CLI. |

### Recommended Architecture

Strict layered dependency direction (**cli → core → generators/adapters → runner/secrets**):

- **cli** — command definitions (extends `CommandRunner`), prompts
  (`interact`/`mason_logger`), spinners/colored output (`mason_logger`), shell completion
  (`cli_completion`, bash/zsh/fish).
- **core** — typed config model (`checked_yaml` + `json_serializable`), validation
  (`json_schema`), the secret-resolution chain, and a project inspector (detects flavors,
  Gradle DSL, Firebase).
- **generators** — producing Fastfile/Appfile/Gymfile/Matchfile/Pluginfile/Gemfile, Gradle
  flavor blocks, xcconfig, dart-define JSON, entrypoints, `.env.<flavor>` templates, and
  `.gitignore` entries. Each implements a common interface and writes **managed blocks**
  guarded by markers plus a lockfile of content hashes.
- **platform adapters** — `IosAdapter`, `AndroidAdapter`, `FirebaseAdapter` encapsulate
  xcodeproj-gem invocation, build.gradle(.kts) editing, and google-services placement.
- **secrets** — `SecretProvider` implementations + a `Redactor`.
- **runner** — a step-graph (DAG) engine that executes pipelines, captures/redacts logs,
  classifies failures, and writes artifact manifests.

**Key interfaces (illustrative Dart):**

```dart
abstract class DeployTarget {
  String get id;                       // 'testflight','play','firebase','appstore'
  Platform get platform;               // ios | android | both
  List<SecretRef> get requiredSecrets; // names only
  Future<void> validate(ResolvedConfig c);
  List<PipelineStep> plan(ReleaseRequest r);
}

abstract class SecretProvider {
  int get priority; // flag=0, env=1, dotenv=2, keychain=3, prompt=4
  Future<String?> lookup(SecretRef ref);
}

abstract class Generator {
  String get name;
  Future<List<GeneratedFile>> render(ResolvedConfig c);
}

class GeneratedFile {
  final String path;
  final String contents;
  final bool fullyManaged;   // whole-file vs. managed-block
  final String contentHash;  // stored in lockfile
}

class PipelineStep {
  final String id;
  final Future<StepResult> Function(RunContext) run;
  final List<String> dependsOn; // enables parallel iOS/Android
  final bool resumable;
}
```

**Step/runner model:** A pipeline is a DAG of `PipelineStep`s. The runner topologically
sorts, runs independent branches in parallel (iOS + Android), streams process output
through the `Redactor`, records each step's status/duration/artifacts to
`.taxiway/runs/<timestamp>.json`, and supports `--dry-run` (print plan) and `--resume`
(skip prior-success steps with unchanged inputs).

**Generator model & idempotency:** Fully-managed files (Fastfile, Matchfile) are rewritten
wholesale when their hash in `.taxiway/lock.json` matches the last generated hash; if a
user edited them (mismatch), the tool prints a diff and requires `--force`. Partially-owned
files (build.gradle.kts, .gitignore, Podfile) use
`# BEGIN taxiway (managed) — do not edit` / `# END taxiway` marker blocks; only the block
is replaced.

**Process execution:** Use `dart:io` `Process.start` with streamed stdout/stderr piped
through the `Redactor` (rather than `process_run` convenience wrappers) for control over
interleaving, exit codes, and cancellation. All fastlane invocations run via
`bundle exec fastlane <lane>` so a pinned Gemfile controls versions.

### Configuration Schema (`taxiway.yaml`)

```yaml
version: 1                         # schema version, drives migrations
project:
  name: acme_app
  pubspec: pubspec.yaml            # source of version+build
  flutter_min: "3.35.0"            # doctor enforces
apps:                              # monorepo-ready; single app = one entry
  main:
    path: .                        # Flutter app root
    flavors:
      dev:
        suffix: .dev               # appended to base bundle/app id
        display_name: "Acme Dev"
        dart_defines: { ENV: dev, API: "https://dev.api" }
        icon: assets/icon/dev.png
        firebase:
          android: android/app/src/dev/google-services.json
          ios: ios/flavors/dev/GoogleService-Info.plist
      prod:
        suffix: ""
        display_name: "Acme"
        dart_defines: { ENV: prod, API: "https://api" }
    signing:
      ios:
        match_git_url: git@github.com:acme/certs.git
        match_storage: git         # git | googlecloud | s3
        team_id: ABCDE12345
        api_key:                   # App Store Connect API key (names only)
          key_id_ref: ASC_KEY_ID
          issuer_id_ref: ASC_ISSUER_ID
          p8_ref: ASC_KEY_P8_BASE64  # base64 .p8, resolved at runtime
      android:
        keystore_ref: ANDROID_KEYSTORE_BASE64
        key_properties:
          store_password_ref: ANDROID_STORE_PASSWORD
          key_password_ref: ANDROID_KEY_PASSWORD
          key_alias: upload
    targets:
      testflight:
        groups: [internal, qa]
        distribute_external: false
        changelog_from: git        # git | file | prompt
      appstore:
        submit_for_review: false
        metadata_path: ios/fastlane/metadata
      play:
        track: internal            # internal | alpha | beta | production
        release_status: draft      # draft | completed | inProgress | halted
        rollout: 0.1               # user_fraction for inProgress
        artifact: aab              # aab | apk
      firebase:
        android_app_id_ref: FB_ANDROID_APP_ID
        ios_app_id_ref: FB_IOS_APP_ID
        groups: [testers]
    versioning:
      strategy: remote             # timestamp | increment | remote
      sync_ios_android: true       # keep CFBundleVersion == versionCode
secrets:
  dotenv: .env.{flavor}
  keychain: true
notify:
  slack_webhook_ref: SLACK_WEBHOOK
```

**Field notes:** `apps:` is a map keyed by app id so a monorepo can list several; a
single-app repo has one entry. Every `_ref` names an env var / secret key — never a value.
`versioning.strategy: remote` queries the store for the latest build number; `increment`
bumps pubspec; `timestamp` uses `yyMMddHHmm`. `match_storage` mirrors fastlane's
git/googlecloud/s3 modes. `release_status`/`rollout` map to `supply` semantics (staged
rollout requires `inProgress` + fractional `user_fraction`).

### Phase-by-Phase Plan (original seven-phase sketch)

> Phases 0–3 have since been re-planned in far more detail, including a new Phase 1A
> (inspect/import) that inverts the build order. What follows is the original sketch;
> **Phases 4–6 below are still the live plan.**

**Phase 0 — Skeleton + `doctor`.** *Goal:* installable CLI, config parsing, environment
validator. *In:* command runner, `taxiway.yaml` load/validate (`checked_yaml`+`json_schema`),
`doctor`. *Out:* file generation. *Approach:* `doctor` shells out to version-check Xcode
(and enforce that App Store Connect uploads must be built with Xcode 26 or later using an
iOS 26 SDK — per Apple's Upcoming Requirements, "Begins April 28, 2026"), CocoaPods +
`xcodeproj` gem ≥ 1.26.0, Ruby ≥ 3.0 (docs: "fastlane supports Ruby versions 3.0 or newer,
but prefers Ruby 3.3 or greater"), bundler, fastlane, JDK/Gradle (flag Groovy vs Kotlin
DSL), Flutter/Dart, Firebase CLI, and Google Play target-API-36 readiness (per Play Console
Help: "Starting August 31, 2026: New apps and app updates must target Android 16 (API level
36) or higher," with a one-time extension available to November 1, 2026). Emits a checklist
with fix hints and `--json`. *Effort:* M. *Risk:* version-string drift — permissive parsers
+ tests.

**Phase 1 — Flavor scaffolding.** *Goal:* turn flavor definitions into working
Android/iOS variants. *In:* Android `productFlavors`/`flavorDimensions` in
**build.gradle.kts** (Kotlin DSL is the default for new projects since Flutter 3.29) with a
Groovy fallback; iOS schemes + `Debug-<flavor>`/`Release-<flavor>`/`Profile-<flavor>`
configurations via the `xcodeproj` gem; xcconfig; `main_<flavor>.dart`;
`--dart-define-from-file` JSON; per-flavor icons/display names; per-flavor Firebase file
placement. *Approach:* mutate `project.pbxproj` via the Ruby `xcodeproj` gem and write
**shared** `.xcscheme` files into `xcshareddata/xcschemes` (never `xcuserdata`, which is
per-user/git-ignored) — schemes must be shared for Flutter flavors to work, and
configuration names must follow the `<Config>-<flavor>` convention Flutter requires.
Firebase config via `flutterfire configure` per flavor (or file placement into
`android/app/src/<flavor>/` and `ios/flavors/<flavor>/`). *Effort:* L. *Risk:*
Xcode-project mutation fragility — xcodeproj gem, shared-scheme handling, backup+diff
before write, and an e2e that actually builds.

**Phase 2 — fastlane generation + local builds.** *Goal:* generate the fastlane project
and drive local builds. *In:* Fastfile, Appfile, Gymfile, Matchfile, Pluginfile, Gemfile
(pinned fastlane + `firebase_app_distribution` plugin); `taxiway build ios|android --flavor X`.
*Approach:* lanes reference `ENV[...]` only. **iOS:**
`flutter build ipa --flavor prod --export-options-plist=<generated>` produces the archive;
fastlane runs `match` (readonly) + upload. **Android:** `flutter build appbundle --flavor prod`
then `supply`. Pin Gemfile; always `bundle exec fastlane`. *Effort:* L. *Risk:* two-way
drift on hand-edited Fastfiles — managed-whole-file + hash lock + `--force` diff.

**Phase 3 — Secrets & signing wizard.** *Goal:* guided `match` setup and secret
provisioning. *In:* `taxiway setup ios-signing` (match repo init + storage choice; App Store
Connect API key capture: issuer ID, key ID, `.p8` → base64; bundle-ID registration),
`taxiway setup android-signing` (keystore via `keytool`; key.properties), Play
service-account JSON guidance + required permissions, Firebase service-account JSON, secret
redaction. *Approach:* resolution chain flag → env → `.env.<flavor>` → OS keychain →
prompt. Keychain via `security` (macOS), `secret-tool`/libsecret (Linux), Credential
Manager (Windows) — shell out behind a thin abstraction; base64-encode values to avoid the
macOS `security` non-ASCII hex-encoding quirk. match uses the App Store Connect API key
with **readonly** for day-to-day runs, reserving write mode for explicit setup/nuke.
*Effort:* XL. *Risk:* keychain-prompt/`set-key-partition-list` issues and wrong-passphrase
decryption failures — covered by the error classifier. (Recommend documenting/optionally
integrating `sops`/`age`/`git-crypt` for teams who want the match repo or `.env` encrypted
at rest, but do not require them.)

**Phase 4 — Deployment targets.** *Goal:* ship to TestFlight, App Store, Play, Firebase.
*In:* `DeployTarget` implementations; version/build-number strategies. *Approach:*
TestFlight via `upload_to_testflight`/`pilot` (`groups`, `changelog`,
`skip_waiting_for_build_processing`, `distribute_external`, `notify_external_testers`);
App Store via `upload_to_app_store`/`deliver` + metadata; Play via
`upload_to_play_store`/`supply` (`track`, `release_status`, `rollout` as `user_fraction`
with `inProgress`, aab default, `track_promote_to`); Firebase via the plugin using
**service-account JSON** (not the deprecated token). Build numbers: `remote` uses
`latest_testflight_build_number + 1` and `google_play_track_version_codes[0] + 1`; keep
iOS/Android in sync when configured. *Deliverables:* `TestFlightTarget`, `AppStoreTarget`,
`PlayTarget`, `FirebaseTarget`, `VersionResolver`. *Exit:* dry-run plans validated; live
upload to internal/TestFlight succeeds on a test app. *Effort:* XL. *Risk:* duplicate build
numbers, Play version-code monotonicity, TestFlight processing delays — classifier +
pre-flight checks.

**Phase 5 — Declarative pipelines.** *Goal:* named pipelines (analyze → test → build →
deploy → notify). *In:* pipeline definitions in config, pre/post hooks, parallel
iOS/Android, `--dry-run`, `--resume`, run summary. *Approach:* the DAG runner; each stage a
`PipelineStep`; run manifest + summary table via `mason_logger`. *Exit:* a `beta` pipeline
runs iOS+Android in parallel and resumes from a failed deploy step. *Effort:* L. *Risk:*
partial-failure semantics — explicit resumability flags per step.

**Phase 6 — Polish.** Shell completions (`cli_completion`), `upgrade` (`pub_updater` for
pub installs + release-manifest check for binaries), a plugin interface for custom
`DeployTarget`s, Slack/Discord notifications, changelog-from-git, and config schema
migrations driven by `version:`. *Effort:* M.

### Command Surface

```
taxiway
  doctor [--json]
  init [--flavors dev,prod]
  generate [flavors|fastlane|firebase|all] [--force] [--dry-run]
  setup ios-signing | android-signing | firebase
  build ios|android --flavor <f> [--release]
  release ios|android --flavor <f> --target testflight|appstore|play|firebase
          [--track internal|beta|production] [--rollout 0.1]
          [--changelog <text|file>] [--dry-run]
  run <pipeline> [--dry-run] [--resume] [--only ios|android]
  secrets set|list|import --flavor <f>
  upgrade
  completion install
```

Global flags: `--config`, `--app <id>` (monorepo), `--verbose`, `--no-color`, `--yes`.

### Generated-Artifact Inventory

- `taxiway.yaml` (init) — the config.
- `.taxiway/lock.json` — content hashes for idempotency.
- `.taxiway/runs/*.json` — run manifests / audit logs.
- `android/app/build.gradle.kts` — managed flavor block.
- `android/key.properties` (git-ignored) + keystore reference.
- `ios/Runner.xcodeproj/project.pbxproj` — configurations (via xcodeproj gem).
- `ios/Runner.xcodeproj/xcshareddata/xcschemes/<flavor>.xcscheme` — shared schemes.
- `ios/flavors/<flavor>/GoogleService-Info.plist`,
  `android/app/src/<flavor>/google-services.json`.
- `ios/Flutter/<flavor>.xcconfig`.
- `lib/main_<flavor>.dart`, `dart_defines/<flavor>.json`.
- `ios/fastlane/{Fastfile,Appfile,Gymfile,Matchfile,Pluginfile}`, `ios/Gemfile`.
- `android/fastlane/{Fastfile,Appfile,Pluginfile}`, `android/Gemfile`.
- `.env.<flavor>.example` (committed) and `.env.<flavor>` (git-ignored).
- `.gitignore` — managed block adding secret patterns.

### Error Classifier Catalog

| Signature (substring/pattern) | Diagnosis | Suggested one-line fix |
|---|---|---|
| `No profiles for 'com.x.y' were found` / `No profile for team ... matching` | Missing/mismatched provisioning profile | Run `taxiway setup ios-signing` or `match <type>`; verify bundle id + team. |
| `wrong final block length` / `Couldn't decrypt` | Wrong `MATCH_PASSWORD` | Re-enter match passphrase; check `.env`/keychain entry. |
| `Could not find a matching code signing identity for type 'AdHoc'` | Cert not in active keychain / needs write mode | Unlock keychain; run match without readonly to create; check `set-key-partition-list`. |
| `Version code has already been used` (Play) | versionCode not strictly increasing | Bump versionCode; use `remote` versioning strategy. |
| `The provided entity includes an attribute with a value that has already been used` (ASC) | Duplicate build number on TestFlight/App Store | Increment CFBundleVersion; use `latest_testflight_build_number + 1`. |
| Play API `403` / `does not have permission` | Service account lacks Play permissions | Grant access in Play Console → Users & Permissions; enable Google Play Android Developer API. |
| `requires a development team` / `Signing for "Runner" requires a development team` | No team set / automatic signing on | Set team_id; disable automatic signing; run match. |
| `exportArchive: The data couldn't be read because it isn't in the correct format` | fastlane `gym` wrapping a Flutter build | Use `flutter build ipa --export-options-plist` then upload only. |
| `unknown ISA PBXFileSystemSynchronizedRootGroup` | Xcode-16 synchronized folders + old xcodeproj gem | Update `xcodeproj` gem to ≥ 1.26.0 (or revert objectVersion 70→60). |
| `App Distribution could not generate credentials from the refresh token` | Deprecated Firebase token auth | Switch to Google service-account JSON (`service_credentials_file`). |
| Gradle `Unsupported class file major version` / daemon errors | JDK/Gradle mismatch | Align JDK with Gradle version; run `doctor`. |
| `WARNING: Support for your Ruby version ... going away` | Ruby too old for fastlane | Upgrade Ruby to ≥ 3.3. |

### Testing Strategy

- **Unit:** config parsing/validation, secret-resolution ordering, version parsing,
  redaction — `test` + `mocktail`.
- **Golden-file:** one golden per generator (Fastfile, build.gradle.kts block, xcconfig,
  entrypoints), using the `--set-exit-if-changed` idiom.
- **Integration:** run generators against a fixture Flutter app in a temp dir; assert
  idempotency (second run = zero diff) and marker-block behavior.
- **E2E (nightly):** scaffold a real Flutter app, run `doctor`, generate,
  `flutter build apk/ipa`; optionally a gated live upload to an internal track with test
  credentials.
- Inject a `ProcessRunner` abstraction so command construction is asserted without
  executing real fastlane.

### Local-First CI/CD Considerations

Running on a developer laptop rather than a hosted runner changes several defaults:

- **Keychain hygiene.** `setup_ci` creates a temporary keychain and switches match to
  readonly — but it makes that keychain the *default* and doesn't reliably clean up, and on
  persistent machines this pollutes the login keychain and can leave a lingering default.
  Recommendation: create a **dedicated named keychain** (e.g. `taxiway.keychain`) via
  `create_keychain`, add it to the search list, run match against it in readonly mode, and
  **explicitly delete/reset it after each run** rather than relying on `setup_ci` defaults.
  Set `set-key-partition-list` to avoid the macOS Sierra+ "always allow" prompt.
- **Avoid polluting the login keychain** with match certificates by scoping to the
  dedicated keychain and using `MATCH_KEYCHAIN_NAME`/`MATCH_KEYCHAIN_PASSWORD`.
- **Concurrency:** guard against two simultaneous builds with a lockfile in `.taxiway/`;
  keychains and build dirs are not safe to share.
- **Resilience:** wrap uploads with retry/backoff for network flakiness; use
  `skip_waiting_for_build_processing` to avoid long TestFlight blocking; make steps
  resumable.
- **Auditability:** every run writes a manifest (`.taxiway/runs/*.json`) with step statuses,
  durations, artifact paths/hashes, and the resolved (redacted) environment.

### Distribution & Versioning of the Tool Itself

- Primary: **`dart compile exe`** native binaries per OS (Linux cross-compile supported via
  `--target-os`), published on **GitHub Releases** + a **Homebrew tap** + a `curl | bash`
  installer.
- Secondary: `dart pub global activate taxiway` (legacy) / `dart install` (Dart 3.10+, AOT,
  self-contained).
- Self-update: `taxiway upgrade` uses `pub_updater` for pub installs and a release-manifest
  check for binaries. Shell completion via `cli_completion`.
- SemVer; `version: 1` in config drives schema migrations (Phase 6).

## Recommendations

**Staged next steps:**

1. **Ship Phase 0 first and treat `doctor` as a product in its own right.** It de-risks
   everything downstream and immediately surfaces the 2026 deadlines (Xcode 26/iOS 26 SDK
   from 28 April 2026; Play target API 36 from 31 August 2026), Ruby version, and
   xcodeproj-gem version. **Benchmark to advance:** `doctor` runs green on a clean Mac and
   correctly flags a deliberately-broken environment (old Ruby, old gem).
2. **Prototype the iOS build/upload division of labor early on a throwaway app** before
   investing in the full generator suite — it is the highest-technical-risk assumption.
   **Benchmark:** a signed IPA built by `flutter build ipa` uploads to TestFlight via
   `pilot` with `match` readonly.
3. **Build the flavor scaffolder against both a Kotlin-DSL and a Groovy fixture project.**
   **Benchmark:** golden tests pass and a re-run is a no-op diff on both.
4. **Invest disproportionately in the signing wizard and the error classifier** — these are
   where non-expert users fail and where the tool earns its keep. **Benchmark:** a developer
   with only an Apple Developer account and a fresh machine reaches a signed build in one
   guided session, with zero secrets written to disk unencrypted or printed to logs.

**Thresholds that would change the plan:**

- If fastlane announces genuine end-of-life or an unfixed Ruby-toolchain break, **pivot the
  runner to shell out to Codemagic CLI tools** (Python) via the same `DeployTarget`
  interface — which is why that interface must stay fastlane-agnostic.
- If Apple deprecates classic `project.pbxproj` groups in favor of synchronized folders
  wholesale, **revisit the mutation approach** (potentially adopting a Swift-based
  `XcodeProj` library via a helper binary).
- If early users are overwhelmingly monorepo teams, **promote monorepo orchestration from
  "future work" into Phase 5**.

## Caveats

- **Some search results carried 2026 dates** (fastlane 2.238.0, VGV package v0.6.0 releases
  in Aug 2026); these appear to be genuine release records and are reported as-is, but
  verify exact latest versions at build time against pub.dev and RubyGems.
- **"Maintenance mode" for fastlane is a third-party blogger's impression, not an official
  statement.** The release cadence indicates active maintenance; there is no official EOL or
  funding-crisis announcement. Still, the Ruby dependency is a strategic risk worth hedging.
- **Store requirements change frequently.** The Apple (Xcode 26/iOS 26 SDK, privacy
  manifests, DSA trader status) and Google (target API 36, Play App Signing, account
  verification) deadlines cited should be re-verified against Apple's "Upcoming
  requirements" and the Play Console Help pages before each release cycle; `doctor` should
  hard-code these with a "last verified" date.
- **The `flutter build ipa` + fastlane-upload division of labor is a strong recommendation
  grounded in documented failures**, but exact behavior can vary by Flutter and Xcode
  version; validate on the target toolchain.
- **Xcode-16 synchronized folders primarily bite** when developers add Xcode-created targets
  (widgets/extensions) as buildable folders or run an old gem; Flutter's default Runner
  project still uses classic groups. Requiring `xcodeproj` ≥ 1.26.0 addresses the common
  case but does not guarantee flawless mutation of every hand-modified project.
- **Effort sizings (M/L/XL) are relative, not absolute**; the deploy-targets and
  signing-wizard phases are the largest and riskiest and should carry the most schedule
  buffer.
