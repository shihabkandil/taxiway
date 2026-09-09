# taxiway command reference

Every command taxiway currently ships. Phases 0, 1A, 1B and the first half of
Phase 2 are implemented; commands the plan describes but which do not exist yet
are listed under [Not built yet](#not-built-yet) rather than documented as if
they worked.

```
taxiway <command> [arguments]
```

## The shape of the thing

taxiway reads a project as readily as it writes one, and the two directions are
deliberately separate:

```
  read                                   write
  ────                                   ─────
  import  ──▶ taxiway.yaml ──▶ generate ──▶ project files
  status  ──▶ what differs      adopt   ──▶ permission to write
  doctor  ──▶ can this machine ship it?
  build   ──▶ the artifact
```

`import` never modifies your project. `generate` never writes a file taxiway
does not own — `adopt` is the only way to hand one over, and it shows you the
diff first.

## Global options

Accepted before any command.

| Option | Meaning |
|---|---|
| `-h, --help` | Usage for taxiway or for one command. |
| `--version` | Print the version and exit. |
| `-v, --verbose` | Show every command taxiway runs and its full output. |
| `--no-color` | Disable coloured output. |
| `-y, --yes` | Assume yes for every prompt. Implies non-interactive. |
| `--config=<path>` | Use this `taxiway.yaml` instead of searching for one. |
| `--app=<id>` | Which app in a monorepo to act on. |
| `--env=<name>` | `workstation`, `ci` or `persistent`. Decides which sources secrets may come from and whether taxiway may prompt. Detected when omitted; also settable as `TAXIWAY_ENV` or `ci.environment`. |

## Exit codes

Coarse on purpose, so a CI script can tell the three kinds of failure apart
without parsing output.

| Code | Meaning |
|---|---|
| `0` | Success. |
| `1` | You asked for something invalid — bad flags, bad config, a conflict needing a decision. |
| `2` | This machine cannot do it — a missing or too-old tool, a failing check, a failed build. |
| `70` | A bug in taxiway. Worth reporting. |

---

## `taxiway doctor`

> Check whether this machine can build and ship this app.

```
taxiway doctor [--json] [--only <id>]
```

Runs every environment check and prints a checklist with a fix hint for
anything wrong. Works **before** `init` does — its whole job is telling you why
nothing else will, so it never requires a `taxiway.yaml`.

| Option | Meaning |
|---|---|
| `--json` | Emit the report as JSON, for CI. |
| `--only=<id>` | Run only the named checks. Repeatable. |

Check ids: `flutter`, `dart`, `xcode`, `cocoapods`, `ruby`, `bundler`,
`fastlane`, `xcodeproj_gem`, `pbxproj_object_version`, `jdk`, `gradle_dsl`,
`gradle_wrapper`, `play_target_sdk`, `firebase`, `flutterfire`, `keychain`,
`fastlane-shim`, `gemfile-pins`.

A **warning** means it will work now and bite later — a Ruby near end of
support, a store deadline approaching. A **failure** blocks shipping.

Two checks are worth knowing about because their symptoms are misleading:

- `fastlane-shim` catches a Homebrew `fastlane`, which is a shell script that
  overrides `GEM_HOME` and `GEM_PATH`. `bundle exec fastlane` then silently runs
  a different fastlane against different gems, and fails with
  `Could not find <gem> in locally installed gems` — which reads like a broken
  bundle rather than a hijacked one. The fix is a binstub.
- `gemfile-pins` checks that the pins in the generated Gemfile can actually be
  solved on your Ruby. `bundle install` does not degrade when they cannot; it
  installs nothing.

## `taxiway init`

> Set up taxiway in this project.

```
taxiway init [--force]
```

The front door. Looks at the project, then writes a `taxiway.yaml` describing
what is already there. **No project file is modified.**

| Option | Meaning |
|---|---|
| `--force` | Overwrite an existing `taxiway.yaml`. |

## `taxiway import`

> Read this project and write a taxiway.yaml describing it.

```
taxiway import [--deep] [--dry-run] [--out <path>] [--force]
```

The read direction, in full. Derives a config from the Gradle files, the Xcode
project, the Dart entrypoints, the Firebase config and any existing fastlane
setup. Writes exactly two things — `taxiway.yaml` and `.taxiway/lock.json` —
and nothing else.

Anything the readers could not determine is **left out** rather than guessed.

| Option | Meaning |
|---|---|
| `--deep` | Ask Gradle for the resolved build model. Slower, but reads values the fast parser cannot — computed application ids, values from `ext` blocks. |
| `--dry-run` | Print the derived config without writing. |
| `--out=<path>` | Where to write it. Defaults to `taxiway.yaml`. |
| `--force` | Overwrite an existing config. |

`--deep` runs a real Gradle build model, so it needs a project whose wrapper
Gradle version satisfies Flutter's floor. `doctor`'s `gradle_wrapper` check
tells you if it does not.

## `taxiway status`

> Show how this project differs from taxiway.yaml.

```
taxiway status [--json]
```

Re-reads the project and compares it to the config. On a freshly imported
project this reports no drift — that round trip is a correctness gate, not a
nicety.

| Option | Meaning |
|---|---|
| `--json` | Emit the drift report as JSON. |

## `taxiway generate`

> Write the files taxiway.yaml describes.

```
taxiway generate [flavors|fastlane|all] [--dry-run] [--force] [--no-prune]
```

The write direction. Defaults to `all`.

| Option | Meaning |
|---|---|
| `--dry-run` | Show what would change, write nothing. |
| `--force` | Overwrite content you have edited *inside a taxiway block*. Never overrides an unadopted file. |
| `--no-prune` | Keep files taxiway generated that the config no longer describes. |

**Groups**

| Group | Produces |
|---|---|
| `flavors` | Android product flavors, shared Xcode schemes, Dart entrypoints, dart-define files |
| `fastlane` | Gemfiles, Pluginfiles, Appfiles, Matchfile, ExportOptions plists, the iOS Fastfile |
| `ci` | A GitHub Actions release workflow |
| `all` | All of the above, plus the `.gitignore` block |

Individual generators can also be named: `android-flavors`, `ios-schemes`,
`entrypoints`, `dart-defines`, `gemfiles`, `pluginfiles`, `appfiles`,
`matchfile`, `export-options`, `ios-fastfile`, `gitignore`.

**What it refuses to do.** A file that existed before taxiway is reported as
`conflict` and left alone. That refusal is the feature: on a real project the
Gradle build file and the Xcode project were there first, and generating over
them would replace a working build. Run `taxiway adopt` to hand one over.

Re-running is a byte-identical no-op.

**Cleaning up after a config change.** Rename a flavor from `dev` to `staging`
and the files derived from the old name are removed:

```
  removed  lib/main_dev.dart
           no longer described by taxiway.yaml
  release  dart_defines/dev.json
           no longer described by taxiway.yaml, but you have edited it —
           left in place and no longer managed
```

A file is only deleted when taxiway wrote it *and* its content is still exactly
what taxiway wrote, so nothing you authored is ever removed. One you have edited
is left alone and handed back to you — reported once, then never again.

Cleanup is scoped to the generators that ran, so `taxiway generate flavors`
cannot touch the fastlane files, and a generator that could not run (no readable
`Runner.xcscheme` to derive schemes from) sweeps nothing, because producing
nothing is not the same as no longer being asked to. See
[`orphan-cleanup.md`](orphan-cleanup.md).

Cleanup is skipped, with a note, when the config declares more than one app:
generated paths are not app-scoped yet.

Besides files, `generate` also mutates `ios/Runner.xcodeproj/project.pbxproj`
and `ios/Runner/Info.plist` through adapters that back up, verify and restore on
failure.

## `taxiway adopt`

> Let taxiway write to a file that was here before it.

```
taxiway adopt <path|all> [--dry-run]
```

Shows the difference adopting would make, then records the file as taxiway's to
write. Ownership lives in `.taxiway/lock.json`, which is committed on purpose —
it is a team-wide fact, and a teammate who pulls the repo inherits the same
permissions.

| Option | Meaning |
|---|---|
| `--dry-run` | Show what adopting would change without recording anything. |

## `taxiway build`

> Build a flavor for one platform.

```
taxiway build ios|android --flavor <flavor> [options]
```

Constructs the `flutter build` invocation from the same resolved config the
generators used. This exists because the command is easy to get wrong in ways
that **do not fail**:

- omit `--target` and Flutter compiles `lib/main.dart` under the flavor's bundle
  id — the wrong app, built successfully;
- omit `--dart-define-from-file` and it builds against the wrong backend.

Neither produces an error, so taxiway assembles the command rather than leaving
it to memory.

| Option | Meaning |
|---|---|
| `-f, --flavor <name>` | Which flavor. Required when the config declares any. |
| `--artifact appbundle\|apk` | Android only. Defaults to `appbundle`. |
| `--debug` | Build debug instead of release. |
| `--no-codesign` | iOS only: archive without signing, which is what the generated fastlane lane uses because gym signs on export. |
| `--dry-run` | Print the command that would run, and stop. |

**It reads successful builds too.** `flutter build` exits `0` on an archive
whose `Info.plist` lost its version keys, and App Store Connect then rejects the
upload. A zero exit code is not evidence an artifact can be shipped, so the
output of a *successful* build is classified as well, and anything recognised is
reported as a warning with its remedy.

For iOS the reported artifact is the `.xcarchive`, not an `.ipa`: the export
names the `.ipa` after `CFBundleName` under Flutter and after the product target
under gym, so it can only be found by globbing `build/ios/ipa/*.ipa`. Since
taxiway varies only `CFBundleDisplayName` per flavor, every flavor exports to
the same filename — which is why the generated lanes accept only an `.ipa`
written after their own build began.

## `taxiway secrets`

> Show which credentials this project needs, and whether they are set.

```
taxiway secrets list|check [--json] [--flavor <f>]
```

`list` reports; `check` exits `2` when a required credential is missing. Run
`check` as the first step of a CI job and a twenty-minute build that dies at the
upload becomes a five-second failure that names the variable.

**Neither ever prints a value.** That is a property of the types rather than of
care: the resolver returns a status carrying a *source*, and is never handed a
secret to leak.

```
$ taxiway secrets check --env ci

Environment: ci (from --env). Looking in: environment.

  missing ASC_KEY_P8_BASE64
          signing.ios.api_key.p8_ref
  no file PLAY_SERVICE_ACCOUNT_JSON_PATH
          the play lane
          names play.json, which does not exist
       ok MATCH_PASSWORD
          the certificates lane — found in environment

1 of 3 resolved.
```

A variable naming a file that is not there is reported as missing, because it
is the same failure as being unset — only found twenty minutes later.

The list is derived from `taxiway.yaml`: every `*_ref` field names a credential,
so the config is the single source of truth for what a project needs. A test
asserts the names checked here are the ones the generated lanes actually read —
a pre-flight that checks a different name than the lane reads is worse than
none, because it reports green and the build still fails.

### Where secrets are looked for

The chain depends on `--env`, because a prompt on a build machine is a hang, and
a hang is worse than a failure:

| Environment | Chain |
|---|---|
| `workstation` | environment → `.env` → keychain → prompt |
| `ci` (hosted runner) | environment |
| `persistent` (self-hosted, Mac mini) | environment → `.env` |

The login keychain is deliberately absent off the workstation: on a headless Mac
it may not be unlocked after a reboot, and depending on it is what makes
self-hosted builders fail in ways that look like signing problems.

See [`execution-environments.md`](execution-environments.md).

## Generated fastlane lanes

`taxiway generate fastlane` writes lanes you run yourself, always through
bundler:

```
cd ios && bundle install
bundle exec fastlane ios beta flavor:prod
```

**iOS** — `cd ios && bundle exec fastlane ios <lane>`

| Lane | Does |
|---|---|
| `certificates` | Syncs signing via `match`, readonly unless asked otherwise. |
| `build_ipa` | Builds and signs an `.ipa` for one flavor. |
| `beta` | `certificates` → `build_ipa` → upload to TestFlight. Takes `dry_run: true`. |

**Android** — `cd android && bundle exec fastlane android <lane>`

| Lane | Does |
|---|---|
| `build` | Builds a release artifact. `type: "appbundle"` (default) or `"apk"`. |
| `play` | `build` → `upload_to_play_store`, on the configured track. Takes `dry_run: true`. |
| `firebase` | `build` → Firebase App Distribution. Only generated when `targets.firebase.android_app_id_ref` is set. |

Every lane takes `flavor:`, and refuses with the list of valid flavors without
it. The Play lane never touches the store listing — metadata belongs to whoever
writes it, not to a build.

Every credential reaches a lane through `ENV`; nothing that could be a secret is
written into a generated file, and a test greps all fastlane output to keep it
that way.

> **If `bundle exec fastlane` fails with `Could not find <gem>`,** you have a
> Homebrew fastlane shadowing the bundle. Use a binstub instead:
> `cd ios && bundle binstubs fastlane`, then `./bin/fastlane ios beta`.
> `taxiway doctor` warns about this.

## Continuous integration

`taxiway generate ci` writes `.github/workflows/release.yml` — created once,
then yours. It calls the same lanes you run locally, so green there and green
here mean the same thing.

What it handles that a hand-written workflow usually forgets:

- **Match repository access.** A runner has no SSH agent and no credential
  helper, so a private certificates repo needs an explicit credential. taxiway
  picks `MATCH_GIT_PRIVATE_KEY` or `MATCH_GIT_BASIC_AUTHORIZATION` from the URL
  scheme in your config — match treats them as mutually exclusive and silently
  ignores the wrong one.
- **The Android keystore.** A checkout has neither the keystore (binary,
  git-ignored) nor `key.properties` (passwords). The workflow rebuilds both from
  secrets, with an absolute `storeFile` because Gradle resolves it relative to
  `android/app`.
- **Path-valued service accounts.** Play and Firebase want a *file*, so the
  workflow writes one before the lane runs.
- **`secrets check` as the first step**, so a missing variable fails in seconds.

A test asserts the workflow provides everything the pre-flight requires — a
workflow whose own check step fails is worse than none, since it looks
configured and refuses to run.

Supported CI target is **GitHub-hosted runners**. Self-hosted runners are
detected correctly but not yet supported; see
[`execution-environments.md`](execution-environments.md).

## Not built yet

Planned, and deliberately absent rather than half-present:

| Command | Phase |
|---|---|
| `taxiway setup ios-signing \| android-signing \| firebase` | 3 |
| `taxiway release ios\|android --target testflight\|appstore\|play\|firebase` | 4 |
| `taxiway run <pipeline>` | 5 |
| `taxiway secrets set\|list\|import` | 3 |
| `taxiway upgrade`, `taxiway completion install` | 6 |

The generated lanes stop at TestFlight, the Play internal track and Firebase
App Distribution. Promotion between tracks, App Store submission and staged
rollout management are Phase 4.

## See also

- [`config-schema.md`](config-schema.md) — every `taxiway.yaml` field.
- [`ios-build-division.md`](ios-build-division.md) — who builds the iOS archive,
  and why gym must not.
- [`execution-environments.md`](execution-environments.md) — how Phase 3 is
  designed to run on a laptop, a hosted runner and a self-hosted Mac alike.
- [`orphan-cleanup.md`](orphan-cleanup.md) — how files the config no longer
  describes are removed without deleting anybody's work.
- [`deviations.md`](deviations.md) — where the built thing differs from the plan,
  and why.
