# Whole-stack release runbook (metanorma/metanorma#684, ci#508)

The whole-stack release as one command sequence with human checkpoints,
written against ancora commands and the reusable workflows in this repo.
Design: [`ancora-release-orchestration.md`](ancora-release-orchestration.md).

Conventions used below:

- **real** — the command exists today. ancora commands marked *(todo/corpus-gate)*
  live on the open PR #2 branch; *(PR #6)* / *(PR #7)* are open PRs and not yet on `main`.
- **planned** — named in the ancora roadmap or in progress, not usable yet. The step
  says what to do by hand until it lands.
- **CHECKPOINT** — a human decision. The sequence stops there until it is given.
- `ancora` means `bundle exec exe/ancora` from a clone of `metanorma/ancora`.
  `CHAIN=examples/metanorma.chain.yml` (terminus `metanorma-cli`);
  `DATA` is the collector output (`network.json`, `delta.json`).

Releasing is the owner's decision at every stage. Nothing here releases
anything until the promote checkpoint (stage 6).

## 0. Preconditions

1. Collector data is fresh: `network.json` / `delta.json` regenerated for today.
2. The chain's `main` branches are green. real: `ancora ci metanorma/<gem> main` per gem
   prints the latest run line; read it for `completed success`. Its exit status is 0 for
   failed, pending and missing runs too, so it is not a pass/fail signal by itself.
3. No hold on releases is in force (owner's call). **CHECKPOINT 0: owner says go.**

## 1. Drift and floors

| Step | Command | Status |
|---|---|---|
| Fleet drift (floorless edges, stale pins, prerelease floors, unreleased main) | `ancora drift --network DATA/network.json --delta DATA/delta.json --chain $CHAIN` | real |
| Weekly drift report as an issue | `ancora drift-report --network ... --delta ... --chain $CHAIN [--tags] [--issue OWNER/REPO]` | real on PR #7 |
| Release-policy rules as machine checks, per gem checkout | `ancora policy [--next-version V] <gem-checkout>` | real on PR #6 |
| Semantic plan (bump level per gem from API change) | `ancora plan` + semantic bump | **planned** — until then, versions come from the owner/advisory (`version_advisory` input of `rubygems-release.yml`, ci#369) |
| Floor raise (floors to finals) | floor command | **planned** — until then, raise floors by hand in a PR per gem and re-run drift |
| External-chain needs (pubid/relaton/lutaml finals the chain floors on) | `ancora externals --chain $CHAIN --network ... --delta ...` | real (exit 1 while a need awaits a final) |

`externals` exit 1 means another chain must release first (a release request on that
chain's repo). Nothing promotes against another chain's prerelease.

**CHECKPOINT 1: owner reviews the drift report and `externals`, and fixes the target
versions for the wave.**

## 2. Plan the wave

```sh
ancora plan --network DATA/network.json --delta DATA/delta.json --chain $CHAIN
```

real. Prints antichain waves, leaves first, `metanorma-cli` alone in the last wave.
Scoped repair waves: `--seeds gem1,gem2`.

## 3. Rehearsal (releases nothing)

Run the chain rehearsal in the order you will cut. It builds every gem, installs the set
into an isolated `GEM_HOME`, pins bundler to the built versions and loads the flavor
registry. real: dispatch **release-rehearsal** in this repo (or
`script/release-rehearsal.sh .github/workflows/metanorma-chain.json`); see
[`release-rehearsal.md`](release-rehearsal.md). Keep the manifest aligned with the wave.

The *sandbox fleet-ops* and *clean-`GEM_HOME` relock* steps of the manual wave have no
ancora or ci command today. By hand: relock each consuming repo in a fresh `GEM_HOME`
(`rm Gemfile.lock && bundle install`) and run its suite in a scratch clone, never on the
working checkout. The rehearsal's isolated-`GEM_HOME` chain phase covers the set
resolution but not per-repo relocks. **planned**: fold both into `ancora gate`.

**CHECKPOINT 2: rehearsal green, owner confirms the wave.**

## 4. Candidates

State machine: `ancora step` returns one action per run and commits the manifest.

```sh
ancora step --chain $CHAIN --network DATA/network.json --delta DATA/delta.json \
  --manifest state/waves.json --format json > action.json
```

real. When `action` is `dispatch_wave`, run
[`ancora-candidate.yml`](../.github/workflows/ancora-candidate.yml) with
`items` = `action.json`'s `items` (versions are `X.Y.Z.pre.alpha.N`; the workflow
rejects anything else). It dispatches each gem's own release workflow (the ci#515
release-PR flow) and waits for the version on rubygems.org. Pre-releases are invisible
to default resolvers. Start with `dry_run: true`.

Repeat `ancora step` until the action is `gate`.

## 5. Gate

When `action` is `gate`:

1. Run [`ancora-gate.yml`](../.github/workflows/ancora-gate.yml) with
   `pins` (the attempt's candidates), `corpora` (from `action.json`), `suites`
   (`{gem, repo, version}` per pin; the JSON action has no suites field, so take the
   gem/repo pairs from the text form of `ancora step` (its `suite <gem> (<repo>)` lines)
   and the versions from `pins`) and `canary_commands` (`canary.commands` of chain.yml).
   It builds one lock pinning the whole candidate set
   (`ancora pin --externals` plus the candidate overrides), runs each wave gem's
   suite against it (the gem's own Gemfile layered with the candidate pins), runs the
   canary commands, and compiles every configured `mn-samples-*[-private]` corpus
   against it. The result output is `green` or `red`.
2. Optional render regression on the same candidates: the render-baseline compare
   ([`render-baseline.md`](render-baseline.md)).
3. Record the verdict on the manifest. **planned** (`ancora` verdict recording; the
   `bin/run-action` gate branch in ancora documents the contract). Until then, edit
   `state/waves.json` by hand as the owner of the manifest.

A red gate: fix on `main`, then `ancora step` spawns attempt K+1 with new alphas only
for gems whose `main` changed; `max_attempts` halts for humans.

**CHECKPOINT 5: owner reads the green gate (suites, canary, corpora) and decides to promote.**

## 6. Promote

```sh
ancora approve --manifest state/waves.json   # real: records the approval
ancora step ... --format json                 # emits promote_wave only after approval
```

`promote_approval: manual` is the chain default: the machine holds a green wave until
approval is recorded, and holds while an external need lacks a final.

Then run [`ancora-promote.yml`](../.github/workflows/ancora-promote.yml) with
`items` from the `promote_wave` action, `gate_result: green` and the gate run URL. The
`approve` job runs in a GitHub environment (default `ancora-promote`); the owner
approves the run in the Actions UI. Finals are dispatched in wave order and each is
awaited on rubygems.org before the next. The environment and its required reviewers
must exist in the calling repository; this repo does not create them.

**CHECKPOINT 6: owner approval, twice: `ancora approve` and the environment gate.**

## 7. Tag and publish verification

Per released gem, after the publish leg:

```sh
ancora check <gem> <version>              # real: version on rubygems.org
ancora tag metanorma/<gem> <version>      # real: v<version> tag exists
ancora ci metanorma/<gem> main            # real: latest CI run on main
```

Release notes for the terminus carry the wave manifest:
`ancora notes --prs prs.json --version V` (real on PR #6). The standing verifier
[`release-coherence.yml`](../.github/workflows/release-coherence.yml) checks
stub / tag / GitHub Release / rubygems agreement weekly; dispatch it after the wave.

Raise floors to the finals (never to prereleases) in a follow-up PR; re-run
`ancora drift` and expect no prerelease floors and no stale pins.

**CHECKPOINT 7: owner closes the wave (`ancora step` returns `done`).**

## What is not covered

- The 2026-10-31 manual wave has no write-up in metanorma/ci, metanorma/metanorma or
  ancora; the mechanics here are taken from ancora's README/TODO and the existing
  release workflows.
- Verdict recording, floor raise, semantic plan and `ancora gate` are planned.
