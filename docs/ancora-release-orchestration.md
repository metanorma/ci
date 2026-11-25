# ancora-driven release orchestration — candidate → gated → promoted (ci#508)

Status: **design** (ancora is the reserved orchestration surface; this
document is the build spec). Depends on two landed foundations:
the ci#515 release-PR pipeline and the ci#504–#507 render-baseline
program.

Implementation: [`ancora-candidate.yml`](../.github/workflows/ancora-candidate.yml),
[`ancora-gate.yml`](../.github/workflows/ancora-gate.yml),
[`ancora-promote.yml`](../.github/workflows/ancora-promote.yml); operator sequence in
[`ancora-release-runbook.md`](ancora-release-runbook.md). These drive the
wave model of the ancora engine (candidates `X.Y.Z.pre.alpha.N`, one lock over the
candidate set), which supersedes the per-PR gate battery sketched below where they differ.

## The train

A gem release moves through three stages; ancora owns the train state
(which candidates exist, what each gate returned, whether promotion is
armed), metanorma/ci owns the gates, rubygems-release.yml owns the
publish mechanics. Nothing in this design adds a second publish path —
ci#515's publish leg remains the only one.

```
candidate   dispatch next_version → release PR opens (ci#515)
            + the standing verifier runs on the PR
    │
    ▼
gated       ancora attaches the release PR to the train and fires the
            gate battery on the PR's merge-preview ref:
              1. the standing release verifier (ci#515 stage 4)
              2. render-baseline compare vs frozen (ci#504, per the
                 samples family the flavor declares)
              3. render drift-accepted audit — acceptlist entries
                 reported, never silent (ci#505)
              4. engine parity gate where the flavor is dual-engine
                 (ci#507)
            a red gate pins the train: the release PR cannot auto-merge
            until fixed or explicitly waived (waivers are recorded
            train-state, not silent merges)
    │
    ▼
promoted    all gates green → ancora arms auto-merge → the merge fires
            the publish leg → tag + GitHub Release on the merge commit →
            the versions register annotation (ci#367 lineage) records
            train provenance: gate run ids, waiver ids, merge commit
```

## Why this shape

- **No new publish mechanics** — the train is orchestration over
  events that already exist (release PR opened → gates → merged →
  publish leg). The ci#370 lesson (relay choreography) is respected:
  still no second path, just an external state holder and gate battery.
- **Gates ride artifacts, not re-renders** — the gated stage consumes
  the render-baseline compare reports produced on the PR head, so gate
  cost is one render per samples repo per candidate, not per gate.
- **Waivers are first-class** — an accepted-risk release (e.g. a known
  upstream drift with an acceptlist entry pending upstream fix)
  records waiver id + reason in the train; the release provenance
  carries it.

## ancora's interface (v0 sketch)

- Train state store: `metanorma/ancora` (train.yml per candidate:
  gem, release PR, gate run ids, verdicts, waivers).
- Gate battery: metanorma/ci reusables invoked via
  `workflow_call` (render-baseline compare, parity, verifier) —
  ancora dispatches and collects conclusions; it computes nothing.
- Promotion: ancora enables auto-merge on the release PR when the
  gate battery is green (or a waiver covers every red); the publish
  leg does the rest exactly as today.

## Staged rollout

1. **Stage A** — train state + gate collection for the metanorma-cli
   canary (gates report-only; verdicts posted to the release PR).
2. **Stage B** — gate-enforced auto-merge on the canary; the fleet
   stays on plain ci#515 until the canary survives a release cycle.
3. **Stage C** — opt-in per flavor via the cimas release template's
   input (`orchestration: ancora`); non-opted repos keep plain #515.
