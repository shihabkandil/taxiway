# Design: Phase 5, declarative pipelines

A named sequence of steps in `taxiway.yaml`, run with one command.

```yaml
pipelines:
  beta:
    - analyze
    - test
    - parallel:
        - release: { flavor: prod, target: testflight }
        - release: { flavor: prod, target: play }
```

```
taxiway run beta
```

It adds no shipping ability: everything a pipeline does can already be done by
hand. What it adds is sequencing, parallelism, recoverability and a record of
what happened — the seams between commands, which is where releasing actually
goes wrong.

## Stages, not a DAG

The plan says "the DAG runner". This uses **sequential stages with an explicit
`parallel` block** instead.

A DAG is more expressive and, here, worse. Inferred dependencies mean a reader
has to reconstruct the execution order in their head, and a missing edge is a
race that shows up once in twenty runs. The only parallelism anyone actually
wants is *iOS and Android at the same time*, and writing that down is clearer
than deriving it:

- steps run in order;
- a `parallel:` block runs its steps together and waits for all of them;
- the order in the file is the order of execution, always.

If a real case turns up that stages cannot express, a DAG can be added later
without changing what is already written.

## Steps

| Step | Does |
|---|---|
| `analyze` | `flutter analyze` |
| `test` | `flutter test` |
| `build` | `taxiway build <platform> --flavor <f>` |
| `release` | `taxiway release <platform> --flavor <f> --target <t>` |
| `run` | an arbitrary command, for whatever this list does not cover |

`build` and `release` invoke taxiway's own commands **in process**, through the
same command runner the CLI uses. Not by shelling out to `taxiway`: that would
require it on `PATH` inside its own pipeline, and would lose the exit codes and
classified errors those commands already produce.

`notify` is deliberately **not** here. The config carries
`notify.slack_webhook_ref`, but posting to Slack means an HTTP client and a
whole category of failure — retries, timeouts, a webhook that 404s — that has
nothing to do with shipping. It belongs with the rest of the notification work
in Phase 6.

## Resume, and why it is the hard part

The failure that matters: a `beta` pipeline uploads to TestFlight, then fails
on Play. Re-running the whole thing re-uploads the iOS build, and App Store
Connect rejects it as a duplicate build number — the exact error already in the
classifier.

So a run writes a manifest to `.taxiway/runs/<id>.json` recording each step's
outcome, and:

```
taxiway run beta --resume
```

**re-runs from the first step that did not succeed.** Everything before is
skipped. That rule is simple enough to hold in your head, which matters more
here than cleverness — a resume that does something subtle is one nobody will
trust with a release.

### Repeatability is a property of the step

Each step declares whether running it twice is safe:

| Step | Repeatable | Why |
|---|---|---|
| `analyze`, `test` | yes | They only read. |
| `build` | yes | Rebuilding overwrites an artifact. |
| `run` | **unknown** | taxiway has no idea what the command does. |
| `release` | **no** | The upload may have landed before the failure. |

This matters in one specific case: the step being resumed *into* is the one
that failed, and for a `release` that failure might have come **after** a
successful upload — a network drop while waiting for a response, a cancelled
job. taxiway cannot tell the difference, so it does not pretend to: `--resume`
into a non-repeatable step **says so and asks**, and `--yes` is how you say you
have checked.

Not asking would be worse in both directions. Silently re-running risks a
duplicate upload; silently skipping risks a release everyone believes shipped
and did not.

## Failure semantics

- A failed step stops the pipeline. There is no `continue-on-error`: a pipeline
  that carries on past a failure is a pipeline whose result means nothing.
- Inside a `parallel` block, a failure lets the others **finish** rather than
  cancelling them. Killing a half-finished upload is worse than waiting for it,
  and a cancelled build leaves a partial artifact that the next run may pick up.
- The exit code is the first failing step's, so a caller can tell a bad config
  from a bad machine using the codes taxiway already defines.

## What a run leaves behind

`.taxiway/runs/<id>.json` — already in the generated `.gitignore` — holding each
step's status, duration and exit code, plus the resolved environment with
secrets redacted. It is what `--resume` reads, and what answers "what actually
happened" after the terminal is gone.

A summary table prints at the end either way, because scrollback is not a
report.

## Layering

`lib/src/pipeline/` holds the definitions, the plan and the manifest, and
imports only `core`. It cannot reach the CLI, so the executor takes the
command invoker as a function and `cli` supplies one. That keeps the dependency
direction intact and makes the runner testable without running anything.
