# Design: cleaning up files shipway no longer produces

## The problem

`shipway generate` writes files derived from `shipway.yaml`. When the config
changes so that a file is no longer derived, nothing removes it. It stays on
disk, and stays in `.shipway/lock.json` marked as shipway's own.

Renaming one flavor from `dev` to `development` currently leaves behind:

```
lib/main_dev.dart
dart_defines/dev.json
ios/Runner.xcodeproj/xcshareddata/xcschemes/dev.xcscheme
```

Deleting a flavor leaves the same set. Switching `ios.export` from `flutter` to
`gym` leaves `ios/ExportOptions-<flavor>.plist`. Removing `signing.ios.match_git_url`
leaves `ios/fastlane/Matchfile`.

### Why this is worse than untidiness

Each of these is not merely stale, it is *loaded*:

- **`lib/main_dev.dart`** still compiles. A hand-run `flutter build --target
  lib/main_dev.dart` still works, and builds an app whose flavor no longer
  exists. This is the same class of failure as the missing `--target`: the wrong
  app under the right identity, built successfully.
- **`dev.xcscheme`** appears in Xcode's scheme picker and in `xcodebuild -list`.
  Someone can select and archive it. It references `Release-dev`, a build
  configuration that no longer exists, so it fails in a way that names a
  configuration nobody can find in the config file.
- **`ExportOptions-dev.plist`** names a `match` provisioning profile. Under the
  gym export shape nothing reads it, so it sits there looking authoritative
  while being unreferenced — exactly the trap the export-shape decision was
  written to avoid.
- **The lock entry** claims shipway owns a file no generator produces, so
  `status` and everything built on it reason about a phantom.

## Why the obvious rule is wrong

The tempting rule is: *any file the lock marks `generated` that this run did not
produce is an orphan.* That is unsafe in at least five ways, and each one
destroys real work.

| Case | What the naive rule does |
|---|---|
| `shipway generate flavors` | Produces no fastlane files, so deletes the entire fastlane setup. |
| `shipway generate entrypoints` | Deletes everything except the entrypoints. |
| `--app b` in a monorepo | Deletes app `a`'s files. |
| `Runner.xcscheme` temporarily unreadable | `IosSchemeGenerator` produces nothing, so every generated scheme is deleted — because the *template* was missing, not because the config changed. |
| `lib/main_common.dart` | Declared by the generator but skipped by the writer, since it is create-once scaffolding. Looks unproduced. |

The common fault is treating *absence of output* as *evidence of removal*.
Absence has several causes and only one of them is "the config no longer asks
for this".

## The model

Two ideas make the decision safe.

### 1. Territory

A generator declares which paths it is *responsible for*, as a predicate rather
than a list — the whole point is to match files for flavors that are no longer
in the config, whose names cannot be enumerated from the config.

```dart
/// Whether [path] is one this generator is responsible for.
bool owns(String path) => false;   // default: opts out of cleanup
```

`DartDefinesGenerator` owns `dart_defines/*.json`. `DartEntrypointGenerator`
owns `lib/main_*.dart` except `main.dart` and `main_common.dart`. A generator
that says nothing owns nothing, and its files are never swept.

This makes cleanup **scoped to the generators that actually ran**: a
`generate flavors` run considers only flavor territory, so the fastlane files
are not even candidates.

### 2. Competence

A generator states whether its silence is meaningful.

```dart
/// False when this generator could not run for reasons unrelated to the
/// config. Cleanup is then suppressed rather than guessed at.
bool canDetermineOwnership(ResolvedApp app) => true;
```

`IosSchemeGenerator` returns false when the project has no readable
`Runner.xcscheme`, because it derives every scheme from that template. It
produced nothing, but not because the config said so.

### The rule

A path is an orphan when **all** of these hold:

1. the lock records it as `Ownership.generated` — shipway created it, so it is
   not adopted and not somebody else's file;
2. some generator that **ran in this invocation** `owns()` it;
3. that generator returned `canDetermineOwnership() == true`;
4. no generator in this run produced it;
5. the config declares exactly one app.

Condition 5 is a deliberate, temporary limitation: paths are not app-scoped
today, so a monorepo cannot distinguish app `a`'s `dart_defines/dev.json` from
app `b`'s. Rather than risk it, cleanup is skipped and says so.

## What happens to an orphan

Deletion is irreversible in a way that writing is not, so the decision turns on
one question: **does this file contain any information the user would lose?**

```
             on-disk content == what shipway last wrote?
                    │                        │
                   yes                       no
                    │                        │
             delete it                 keep it, and stop
        (contains nothing              managing it: the file
         the user authored)            holds an edit somebody
                                       made on purpose
```

- **Unmodified** — the content hash in the lock still matches. The file holds
  literally nothing the user authored, so removing it loses nothing and the
  next `generate` would recreate it if the config changed back. Delete it and
  drop the lock entry.
- **Edited** — leave the file exactly as it is, and downgrade its lock entry to
  `Ownership.unmanaged`. shipway will never write it again; it is now the user's
  file. Reported once, then never nagged about again, because a tool that
  reports the same thing on every run is a tool people stop reading.

Both outcomes are reported line by line alongside every other change, and both
are shown by `--dry-run` without doing anything.

Empty directories are deliberately **not** removed. An empty `dart_defines/` is
harmless, git does not track it, and directory removal has a blast radius out of
all proportion to the tidiness it buys.

### Escape hatch

`--no-prune` skips the sweep entirely, for anyone who wants the old behaviour or
is debugging.

## Where it lives

`lib/src/generators/orphan_sweep.dart`.

The layer is right: `generators` may import `core` (for the lock) and does file
I/O already — `GeneratedFileWriter` is its neighbour. The "generators are pure"
rule applies to `Generator` implementations, which decide *what* to write, not
to the machinery that decides *whether* shipway may write it.

The sweep runs after the write loop and before the Xcode mutation, so its
results appear in the same report.

## What this does not solve

- **Monorepos**, as above, until paths are app-scoped.
- **Files whose generator was removed from shipway itself.** No generator runs,
  so no territory matches. That is what the one-off `LegacyXcconfigCleanup`
  migration exists for, and a future removal would need the same treatment.
- **Orphans outside any territory**, such as an `android/app/src/<flavor>/`
  source set left by a removed flavor. Those are directories of files shipway
  never wrote, and deleting them is not its business.
