# release-rehearsal

Prove that the whole metanorma gem chain can be released — **without
releasing anything**. `script/release-rehearsal.sh` is one implementation
used by both runners: locally, and on GHA via
`.github/workflows/release-rehearsal.yml`.

## Why

`rubygems-release.yml` validates one gem at a time. Its preflight cannot
catch chain-level failures, and history keeps producing them:

- **metanorma-cli v1.16.6** (ci#309): the release reached the publish step
  before discovering a dependency could not resolve — 2h27m wasted.
- Version bumps cut one gem ahead of its consumers' floors, or behind
  their ceilings, are only ever observed by the *consumer's* CI — after
  the gem is already on rubygems.org, where versions are forever.

A rehearsal runs the exact preflight checks the release will run, per
gem, and then proves the chain as a whole installs and loads from the
built artifacts. Green rehearsal = the dispatch of the same versions is
expected to publish cleanly and interoperate.

## What it checks

Per gem (mirrors the `rubygems-release.yml` preflight):

| Check | What it catches |
|---|---|
| Fresh `bundle install` (`Gemfile.lock` removed) | Unsatisfiable constraints, missing gems, GH Packages auth slips |
| `bundle exec rake --version` resolves | ci#363: `rake` excluded by the Gemfile so `rake release` dies at push |
| `gem build <gemspec>` | Gemspec errors: syntax, missing files, invalid metadata |
| Version awareness | The version is already on rubygems.org (a `next_version` bump is required) |

Across the chain:

| Check | What it catches |
|---|---|
| Install every built gem into an isolated `GEM_HOME` | Broken artifacts, install-time failures |
| Chain-internal constraint check | Gem A's floor/ceiling excludes the Gem B you are about to cut — the "can these versions ship together" question |
| Bundler pinned to the exact built versions, `require` every gem, load `Metanorma::Registry` | The chain resolves as a set and the flavor registry actually loads (this is what `metanorma-cli` does at startup) |

## The manifest

`.github/workflows/metanorma-chain.json` lists the chain:

```json
[
  { "repo": "metanorma/metanorma-utils", "ref": "main" },
  ...
]
```

Edit it to add/remove gems; each entry's `ref` overrides the workflow's
`ref` input. Keep the manifest aligned with the set of versions you
intend to dispatch releases for.

## Run it locally

```sh
metanorma/ci/script/release-rehearsal.sh metanorma-chain.json
```

Artifacts land in `.release-rehearsal/`: `gems/` (the built gems),
`logs/` (one log per gem plus the chain logs), `results.tsv` (summary),
`gemhome/` (the scratch install), `chain/` (the pinned bundle). Useful
flags:

- `--build-only` — per-gem phase only, for iterating on one repo.
- `--chain-only` — chain phase on a previously built `gems/` dir.
- `REHEARSAL_DIR=$PWD` — rehearse a checkout you already have (the
  workflow uses this), instead of cloning.
- `REHEARSAL_REF=<ref>` — default ref for manifest entries.

No RubyGems credentials are involved; nothing is pushed, tagged, or
bumped.

## Run it on GHA

Dispatch **release-rehearsal** on `metanorma/ci` (inputs: `ref`,
`manifest`, `ruby_version` — the default Ruby matches
`rubygems-release.yml`). One build job per gem runs in parallel; the
chain job then installs and smokes the full set. The run is green only
if every gem preflights cleanly **and** the built set resolves and loads
together.

## Relation to the release flow

The rehearsal is strictly read-only and shares no state with releases.
After a green rehearsal, dispatch `release` on each gem as usual
(`next_version` per gem, in the order you rehearsed). If a release
dispatch nonetheless fails, fix and re-rehearse the affected gem plus
the chain.
