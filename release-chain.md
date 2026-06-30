# Release chain — maintainer reference

How a metanorma-org gem actually gets released, layer by layer. Aimed at maintainers (and any contributor or external consumer) who needs to:

- Understand what happens between firing `gh workflow run release.yml` and the docker image rebuilding downstream.
- Diagnose a release that failed at some stage — know which stage, why, and what to do.
- Recognise half-released states and how to recover from them.

Companion to the per-workflow docs that detail each individual piece: [`rubygems-release.md`](rubygems-release.md), [`monorepo-rubygems-release.md`](monorepo-rubygems-release.md), [`generic-rake.md`](generic-rake.md), [`prepare-rake.md`](prepare-rake.md), [`gem-idempotent-push-guard.md`](gem-idempotent-push-guard.md). Filed against [`metanorma/ci#309`](https://github.com/metanorma/ci/issues/309).

## Why this doc exists

A real `metanorma-cli` v1.16.6 release attempt on 2026-06-27 walked the full chain in ~2 hours 27 minutes and failed at the second-to-last gate. The maintainer had no predictive signal during the 2-hour rake matrix wait, no playbook for the failure mode when it appeared, and no documented recovery for the half-released state that resulted (tag in git, gem not on rubygems, no GH Release page, no downstream cascade). This doc removes that asymmetry: every failure mode below is named, every recovery is concrete.

## The chain at a glance

The "gated-direct" release model (adopted 2026-06-18, see [`metanorma/cimas:plans/cimas-revival-and-release-workflow-realignment.md`](https://github.com/metanorma/cimas/blob/main/plans/cimas-revival-and-release-workflow-realignment.md)) has 11 sequential layers between maintainer dispatch and downstream cascade completion:

| # | Layer | Where the code lives | Typical duration |
|---|---|---|---|
| 1 | `release.yml workflow_dispatch` | per-gem repo `.github/workflows/release.yml` | < 1 min |
| 2 | `rake` on `push branch=v<version>` (tag-triggered) | per-gem repo `.github/workflows/rake.yml` → `metanorma/ci/.github/workflows/generic-rake.yml@main` | 30 min – 2 h+ |
| 3 | `rake` on `push branch=main` (commit-triggered, parallel) | same as #2 | 30 min – 2 h+ |
| 4 | `repository_dispatch do-release` fired | inside `generic-rake.yml`, post-test | < 1 min |
| 5 | `release.yml` re-run on `repository_dispatch` | per-gem repo `release.yml` | starts immediately |
| 6 | GH Packages auth setup | `metanorma/ci/gh-rubygems-setup-action@main` | < 1 min |
| 7 | `bundle install` / dependency resolve | `ruby/setup-ruby@v1` with `bundler-cache: true` inside `rubygems-release.yml` | 30 s – 2 min |
| 8 | Idempotent gem-push guard | `metanorma/ci/gem-idempotent-push-guard-action@main` | < 1 min |
| 9 | Actual `gem push` to rubygems.org | `rubygems-release.yml` Publish step | < 1 min |
| 10 | GitHub Release page creation | `softprops/action-gh-release` (transitive) | < 1 min |
| 11 | `release-passed` dispatch | `peter-evans/repository-dispatch@v3` step in `rubygems-release.yml` | < 1 min |
| 12 | `ruby-artifacts.yml` on `release` event → docker dispatch | per-gem repo `.github/workflows/ruby-artifacts.yml`, dispatches to `metanorma/metanorma-docker`, `metanorma/packed-mn` | 5–30 min downstream |

Total wall-clock for a happy-path release: 30 min – 2.5 h, dominated by the rake matrix.

## Preflight (fail-fast guard, runs before layer 1)

A `preflight` job in `rubygems-release.yml` runs as the very first job on every `workflow_dispatch` invocation (skipped on `repository_dispatch` and `push` paths because those already passed preflight in the originating `workflow_dispatch` leg). It runs the cheap, deterministic checks that would otherwise fail much later in the chain. **Total cost: ~90 sec – 2 min**. If it fails, the chain stops immediately — no bump, no tag, no rake. The `release` job is gated by `needs: preflight` with `if: success() || skipped`.

What preflight verifies:

| Check | Catches | Would otherwise fail at |
|---|---|---|
| **Fresh `bundle install` resolve** (with `Gemfile.lock` removed first) | Dep resolution failures: GH Packages auth slip, unsatisfiable version constraint, missing private gem — the v1.16.6 case. | Layer 7, **~2h27m in** |
| **`gem build <gemspec>`** | Gemspec errors: syntax, missing files declared in `spec.files`, invalid `required_ruby_version`, bad metadata | Layer 9, **~2h+ in** |
| **Verify publish credentials available** | Neither `rubygems-api-key` secret nor `role_to_assume` input configured → no publish path viable | Layer 9, ~2h+ in |
| **Version awareness** (informational, not blocking) | Flags when current gemspec version is already published — for `next_version=skip` this means the chain will re-trigger but the publish itself will idempotent-skip. Helps maintainer recognise re-publish-of-existing-version scenarios before committing to the 2h rake wait. | (would just silently no-op at layer 8) |

Preflight is **not** a substitute for the full chain — it's a gate that filters out the cheap-to-detect failure modes early. Things preflight cannot catch (and which still surface later):

- Actual test failures in the rake matrix (layers 2/3 — that's the point of the matrix)
- MFA / OTP prompts at `gem push` (one-time codes can't be dry-run)
- OIDC trust-policy mismatches (the token exchange happens at publish time)
- Downstream cascade failures (layer 12 — a separate workflow on the per-gem side)
- Failures only reproducible on a specific runner OS (preflight runs on ubuntu-latest)

See [`metanorma/ci#309`](https://github.com/metanorma/ci/issues/309) for the maintainer-experience rationale that motivated preflight (the v1.16.6 case: 2h27m wasted to learn `bundle install` failed at layer 7).

## Layer-by-layer: what can fail, how to recognise, how to recover

### Layer 1 — `workflow_dispatch` on per-gem `release.yml`

**What it does.** Maintainer fires `gh workflow run release.yml --repo metanorma/<gem> --field next_version=patch` (or `minor`/`major`/`skip`). The per-gem caller workflow invokes `metanorma/ci/.github/workflows/rubygems-release.yml@main` with the appropriate inputs.

**Failure modes.**
- *Workflow file syntax error*: `gh` returns `HTTP 422 invalid workflow file`. Recovery: fix the per-gem `release.yml`.
- *Missing required secrets* (`pat_token`, `rubygems-api-key`): the workflow starts but fails immediately. Recovery: configure secrets in the gem repo Settings.
- *Branch protection blocks the bump push*: visible in the workflow log at the `gem bump` step. Recovery: relax protection for `metanorma-ci` bot, or use a PAT with bypass rights.

**Recognise.** Run shows `conclusion: failure` within ~1 minute, log points at the failing step.

**Recovery.** Fix and re-fire; nothing destructive happened yet (no tag pushed).

### Layer 2/3 — `rake` matrix on tag-push and main-push

**What it does.** The bump commit on `main` and the new tag `v<version>` both trigger the test matrix via `metanorma/ci/.github/workflows/generic-rake.yml@main`. Matrix = Ruby (3.3, 3.4, 4.0) × OS (ubuntu, macos, windows) × per-template/per-sample test variants. Can be 50–100 jobs for a metanorma flavour processor.

**Failure modes.**
- *Genuine test failures*: code under test broke against the matrix. Recovery: fix code, push fix to `main`, re-fire the workflow_dispatch (or push a new bump).
- *Flaky tests*: intermittent matrix-job failure (network, runner state, race condition). Recovery: re-run the failed job(s) via `gh run rerun --failed`; if persistent, file an issue against the flaky test.
- *Runner timeout*: GHA job kills at the 6-hour limit. Rare but possible for monster matrices. Recovery: reduce matrix scope or split into separate workflows.
- *Tool-setup failures* (Inkscape network install, Ghostscript build, Chocolatey cache miss): visible in the early steps. Recovery: retry; if persistent, see [`metanorma/ci`](https://github.com/metanorma/ci) tool-setup actions.

**Recognise.** Watch via `gh run watch <id>`. Conclusion at the end of the matrix.

**Recovery.** Re-firing the original `workflow_dispatch` produces a fresh bump (a new patch version) unless `next_version=skip`. If the tests are deterministically failing on a real bug, fix the bug in `main` first, then re-fire — the tests will run against the fixed code.

**Caveat: this is the longest layer by far.** Hours of wait. Layers 4–12 take a combined ~3–5 minutes. So a failure at layer 7 or 9 represents 2+ hours of wasted maintainer attention before the failure surfaces — that's what motivated [`metanorma/ci#309`](https://github.com/metanorma/ci/issues/309) and the planned fail-fast preflight (Track A in the #309 remediation slate).

### Layer 4 — `repository_dispatch do-release` fired

**What it does.** After all rake jobs pass, `generic-rake.yml`'s final job dispatches a `repository_dispatch` with `event_type: do-release` back to the same gem repo, carrying the tag ref in the client payload.

**Failure modes.**
- *Missing or insufficient `pat_token`*: the workflow uses a PAT (not the default `GITHUB_TOKEN`) because dispatches from the latter can't trigger downstream workflows. Without PAT, the dispatch silently does nothing; the chain stalls between rake green and the next layer. Recovery: configure `METANORMA_CI_PAT_TOKEN` (or per-gem equivalent) at repo or org level.
- *Wrong event type or payload shape*: dispatch fires but the receiver doesn't recognise it. Recovery: check `release.yml` `on: repository_dispatch: types:` matches.

**Recognise.** Rake completes successfully, but no new `release.yml` run appears within 1–2 minutes.

**Recovery.** Manually fire the do-release: `gh api repos/<owner>/<gem>/dispatches -f event_type=do-release -F 'client_payload[ref]=refs/tags/v<version>'`.

### Layer 5 — `release.yml` re-run on `repository_dispatch`

**What it does.** The same per-gem `release.yml` runs again, this time with `github.event_name == 'repository_dispatch'`. It skips bump/tag (those already happened in the workflow_dispatch run) and proceeds to the publish path.

**Failure modes.** Usually just a thin wrapper; failures are downstream (layers 6–11).

### Layer 6 — GH Packages auth setup

**What it does.** `metanorma/ci/gh-rubygems-setup-action@main` runs `gen-gemrc-for-gh-packages.sh` and `gen-bundle-config-for-gh-packages.sh`, configuring `~/.gemrc` and bundler to authenticate against `https://rubygems.pkg.github.com/metanorma` using the PAT.

**Failure modes.**
- *Token lacks `read:packages` scope*: bundler can fetch metadata but `bundle install` may fail on the actual download. Recovery: re-issue PAT with correct scope.
- *Action invocation error*: script fails to source. Recovery: pin the action to a known-good ref.

**Recognise.** Step exits non-zero; log shows the auth-setup script output.

### Layer 7 — `bundle install` / resolve

**What it does.** `ruby/setup-ruby@v1` with `bundler-cache: true` resolves the gem's `Gemfile` against all configured sources (public rubygems.org + the scoped GH Packages source for `metanorma-nist` / `metanorma-bsi`). All transitive dependencies installed.

**Failure modes.**
- *`Bundler::GemNotFound: Could not find gem 'X' in locally installed gems`*: **stale bundler-cache hit**. Root cause: `ruby/setup-ruby@v1`'s `bundler-cache: true` uses GitHub Actions cache keyed on `Gemfile.lock` hash. metanorma-org gems don't commit `Gemfile.lock`, so the cache key is unstable, and `ruby/setup-ruby` falls back to **partial-key restore-match** — restoring a cache from a previous release run that had a different Gemfile state. After the stale restore, `bundle install` only installs the diff (often a single recent gem), leaving any newly-added gems silently un-installed. The next `bundle exec rake release` then fails. **Bit the metanorma-cli v1.16.6 release twice** (2026-06-27 and 2026-06-28) on `metanorma-nist`. Fixed at source by [`metanorma/ci#314`](https://github.com/metanorma/ci/issues/314) (hardcode `bundler-cache: false` in the release job). Cost: ~30 sec extra per release for a fresh install.
- *`Bundler::GemNotFound` (other)*: a specifically-scoped gem isn't resolvable at all (not stale cache). Could be:
  - GH Packages auth not propagated correctly (revisit layer 6)
  - The gem genuinely isn't published to GH Packages at the required version
  - Bundler resolution edge case with the scoped-source syntax
- *Version-constraint conflict*: one gem pins a version of another gem that contradicts a third. Recovery: relax constraints in the gemspec.
- *Native extension build failure*: a transitively-pulled-in gem with a C extension fails to compile (e.g., `nokogumbo` on Ruby 4 — see the recent metanorma#568 env-orphan case as a non-release-side instance of the same shape). Recovery: pin to a version with prebuilt binaries or remove the dependency.

**Recognise.** Step exits non-zero; the `Could not find gem` or build-error message is in the log.

**Recovery.** Local reproduction: run `bundle install` on a clean checkout of the gem with the same Ruby version (`ruby/setup-ruby@v1` uses Ruby 3.3 in this workflow). If it fails locally too, the issue is the Gemfile or the GH Packages publication; if it passes locally, it's the CI env (token scope, auth setup).

**This is now caught by the preflight job** (see "Preflight" section above) — preflight runs a fresh `bundle install` (with `Gemfile.lock` removed) on every `workflow_dispatch` invocation, BEFORE bump/tag/rake. The v1.16.6-shape failure now surfaces in ~90 sec instead of 2h 27m. If you see the failure at layer 7 anyway (i.e. preflight passed but the live release run still failed here), the cause is likely environment drift between the preflight invocation and the do-release invocation — worth investigating as a real anomaly.

### Layer 8 — Idempotent `gem-push` guard

**What it does.** `metanorma/ci/gem-idempotent-push-guard-action@main` queries `https://rubygems.org/api/v1/versions/<gem>.json` for the gem name + version. If the version is already on rubygems, sets `skip_push=true`, otherwise `skip_push=false`. Allows safe re-runs of the do-release relay without double-publishing.

**Failure modes.**
- *rubygems API down*: rare. Action falls back gracefully (typically assumes push needed).
- *Misidentification*: very rare; would require gem-identity step (layer ~5) to have got the wrong name/version.

**Recognise.** Step output names the decision.

### Layer 9 — Actual `gem push` to rubygems

**What it does.** Two paths:
- **API key path**: `gem push` using `~/.gem/credentials` populated from `secrets.rubygems-api-key`.
- **OIDC Trusted Publishing path**: `rubygems/configure-rubygems-credentials@v1.0.0` exchanges a GHA OIDC token for short-lived rubygems credentials, then `gem push`.

**Failure modes.**
- *Auth failure*: API key expired, OIDC trust policy mismatch, MFA required (rubygems MFA prompts for OTP and fails in non-interactive contexts). Recovery: rotate key, or — if MFA is enabled — use a key with MFA enforcement disabled for this specific gem, or use OIDC Trusted Publishing.
- *Gem name conflict*: someone else owns the name. Recovery: contact rubygems support.
- *Network failure*: retry.

**Recognise.** `gem push` step exits non-zero.

### Layer 10 — GitHub Release page creation

**What it does.** Triggered indirectly: the `gem push` succeeded, and somewhere in the chain (typically `softprops/action-gh-release` invoked by a sub-action like `ruby-artifacts.yml`) the GitHub Release entity is created with the tag + release notes + uploaded gem assets.

**Failure modes.**
- *`Resource not accessible by integration`*: insufficient `contents: write` permission on the workflow's `GITHUB_TOKEN`. Recovery: add `permissions: contents: write` to the calling workflow.
- *Release already exists* (re-run of do-release): action either updates or skips; rarely an outright failure.

**Recognise.** Step log shows the action's output; visible on the gem repo's Releases page.

### Layer 11 — `release-passed` dispatch

**What it does.** `peter-evans/repository-dispatch@v3` fires a `repository_dispatch` with `event_type: release-passed` back to the same gem repo. Downstream workflows in the gem repo (e.g. `notify.yml`, `ruby-artifacts.yml`) trigger off this event.

#### Critical distinction: "dispatch accepted" vs "dispatch acted on"

The `Dispatch release-passed` step reports success when the GitHub repository-dispatch API returns `2xx` to `peter-evans/repository-dispatch`. That confirms the request was **ACCEPTED** by GitHub's API surface, NOT that any workflow on the receiving end actually **ACTED ON** it. Two distinct things:

| Confirmation | What proves it | Failure modes it does NOT catch |
|---|---|---|
| **Dispatch accepted** | The `Dispatch release-passed` step exits 0 | Receiver rejects the payload (HTTP 422 on the receiving workflow's first run — `metanorma-cli#426` shape); receiver doesn't exist (HTTP 404 — `metanorma-cli#427` shape); receiver is disabled |
| **Dispatch acted on** | A workflow run on the receiver, triggered by `repository_dispatch`, appears in `gh run list` shortly after | (Catches all three above) |

Without the second check, every shape on the right is a **silent fail**: the dispatch step is green, downstream simply doesn't fire, and nobody notices until the next maintainer-initiated release attempt — or, in `metanorma-cli#426`'s actual case, after **6 weeks** of stale Docker Hub.

The `rubygems-release.yml` workflow now includes a `Verify release-passed dispatch acknowledged downstream` step ([`metanorma/ci#326`](https://github.com/metanorma/ci/pull/326)) that polls the same repo's `workflow_runs` API for a `repository_dispatch` run created at or after the dispatch timestamp, with a 90-second timeout. If no such run appears, the release run fails with explicit references to `#302` and `#426`. This closes the silent-fail mode at the cost of ~5-10 seconds per release (typical) or 90 seconds (timeout).

#### Failure modes (post-`#326`)

- *PAT scope insufficient*: same shape as layer 4. The dispatch step itself fails fast; not a silent fail.
- *Receiver doesn't listen on the event type*: dispatch step reports 2xx, no run is created, the verification step times out at 90s and the release run errors.
- *Receiver payload mismatch* (HTTP 422 / 404 / disabled): same as above — dispatch step reports 2xx, no run is created, verification times out and errors.
- *Receiver creates a run but it fails at the first step*: dispatch step reports 2xx, A run was created (so the verification step is satisfied), but that run's own conclusion is `failure`. The verification step doesn't gate on the downstream conclusion — that's the receiver workflow's own monitoring responsibility.

**Recognise.** Run shows the dispatch fired AND the verification step's `✓ Downstream repository_dispatch run found: <id> ...` line. If the verification times out, the release run errors with a pointer to inspect the receiver repo's Actions tab.

### Layer 12 — `ruby-artifacts.yml` on `release` event → docker / packed-mn dispatch

**What it does.** When the GitHub Release entity is created (layer 10), GHA fires a `release: published` event. `ruby-artifacts.yml` listens for it, packages release artefacts, and fires `gh workflow run` against `metanorma/metanorma-docker/build-push.yml`, `metanorma/metanorma-docker/build-push-windows.yml`, etc., to rebuild the docker images with the new gem version.

**Failure modes.**
- *Downstream workflow input-schema mismatch* (`HTTP 422: Unexpected inputs provided`): the dispatch passes a `--field` the receiving workflow doesn't declare in its `workflow_dispatch.inputs`. **Bit metanorma-cli silently for 5+ weeks** until fixed in [`metanorma-cli#427`](https://github.com/metanorma/metanorma-cli/pull/427). Recovery: drop the unaccepted field, or add the corresponding `inputs.<name>` to the receiver's `workflow_dispatch`.
- *Downstream workflow doesn't exist* (`HTTP 404: Not Found`): the dispatch references a workflow file that's been renamed or removed. **Bit metanorma-cli for ~6 years** (packed-mn `build.yml` was split per-platform in 2020 but the dispatch was never updated). Fixed in [`metanorma-cli#427`](https://github.com/metanorma/metanorma-cli/pull/427); deeper packed-mn chain reconstruction tracked in [`metanorma-cli#428`](https://github.com/metanorma/metanorma-cli/issues/428).
- *Downstream workflow is disabled*: `HTTP 422: Cannot trigger a 'workflow_dispatch' on a disabled workflow`. Recovery: enable it via the Actions UI or remove the dispatch.
- **All of layer 12's failures are silent by default**: the calling step uses `set -e` (bash GHA default), so the first dispatch failure short-circuits the rest of the script; the calling workflow (`ruby-artifacts.yml`) still reports `conclusion: failure`, but nobody routinely watches that specific run, so the chain silently doesn't rebuild downstream. [`metanorma/ci#302`](https://github.com/metanorma/ci/issues/302) tracks "green means published" + downstream-cascade observability as the structural fix.

## Half-released states and how to recover

A failure at layer N often leaves the system in a state that's partially-released: the tag exists in git but the gem isn't on rubygems, or the gem is on rubygems but there's no GH Release page, etc. These need explicit recovery:

| Failure layer | Tag pushed? | Gem on rubygems? | GH Release page? | Downstream cascade? | Recovery |
|---|---|---|---|---|---|
| 1–2 | no | no | no | no | Nothing to clean up. Fix and re-fire. |
| 3 (rake on main) | yes | no | no | no | The bump commit is on `main`; the tag is on the bump commit. Either fix and re-fire (which produces *another* patch bump unless `next_version=skip`), or manually fire the do-release dispatch (layer 4 recovery) once the cause is fixed. |
| 4 | yes | no | no | no | Manually fire do-release. |
| 5–7 (e.g. v1.16.6's case) | yes | no | no | no | Fix the bundle-resolve issue. Re-fire do-release manually, or re-fire the workflow_dispatch which will produce a new bump unless `next_version=skip`. |
| 8 (idempotent guard says skip) | yes | yes (already published) | maybe | maybe | Verify GH Release page and downstream cascade fired; manually create or trigger if not. |
| 9 (push failed e.g. MFA) | yes | no | no | no | Re-fire do-release with auth fixed. |
| 10 | yes | yes | no | no | Manually create GH Release page (`gh release create v<version> --notes-from-tag`); then fire `release-passed` dispatch manually (layer 11 recovery). |
| 11 | yes | yes | yes | no | Manually fire `release-passed`: `gh api repos/<owner>/<gem>/dispatches -f event_type=release-passed -F 'client_payload[ref]=refs/tags/v<version>'`. |
| 12 (downstream dispatch failed) | yes | yes | yes | partial | Manually fire the specific downstream workflows: `gh workflow run build-push.yml --repo metanorma/metanorma-docker --ref main`. |

## Triggering modes (which event starts what)

- **`workflow_dispatch`** (`next_version=patch|minor|major|<x.y.z>`): manual maintainer trigger. Bumps version, pushes tag, runs full chain.
- **`workflow_dispatch`** (`next_version=skip`): no version bump; tags the *current* gemspec version and pushes. Used to re-trigger the chain for an existing version without re-publishing — the idempotent guard at layer 8 skips the actual `gem push`. Useful for re-attempting a failed downstream cascade.
- **`repository_dispatch do-release`**: fired by `generic-rake.yml` after tests pass, OR manually as a recovery step. Skips bump/tag, starts at layer 5.
- **`repository_dispatch release-passed`**: fired by `rubygems-release.yml` after publish, OR manually as a recovery step. Triggers downstream cascade.
- **`push` on `v*` tag**: triggers rake (layer 2). Tag push by `gem bump --tag --push` is what kicks off the test matrix.

## Observability safeguards landed 2026-06-30

Two post-step verification gates were added to `rubygems-release.yml` to surface silent-fail classes at the source rather than weeks later:

1. **`Verify gem published on rubygems.org`** ([`metanorma/ci#325`](https://github.com/metanorma/ci/pull/325)) — runs after both publish paths (API key and OIDC). Polls `https://rubygems.org/api/v1/versions/<gem>.json` every 5 s up to 120 s for the just-pushed version. Catches the `metanorma/ci#314`-class shape (publish appears green but gem isn't actually live).
2. **`Verify release-passed dispatch acknowledged downstream`** ([`metanorma/ci#326`](https://github.com/metanorma/ci/pull/326)) — runs after `Dispatch release-passed`. Polls the same repo's `workflow_runs` API for a `repository_dispatch` run created at or after the dispatch timestamp, 5 s × 18 attempts = 90 s. Catches the `metanorma-cli#426`-class shape (dispatch accepted but no downstream workflow actually fires).

These gates are the operational implementation of the "dispatch accepted vs dispatch acted on" distinction documented at layer 11 above. Both fail the release run with explicit references to the originating tickets so a maintainer can recognise the failure class from the error message alone.

## Known-fragile edges as of 2026-06-28

- **Layer 7** (`bundle install`) was the most common failure point that wasted the most time. **Two-layer fix now in place**: (1) preflight job catches resolution errors before bump/tag/rake (~90 sec instead of 2h 27m), and (2) [`#314`](https://github.com/metanorma/ci/issues/314) hardcodes `bundler-cache: false` to eliminate the stale-cache class of silent missing-gem failure that bit metanorma-cli v1.16.6 twice. Both fixes apply to every metanorma-org gem release.
- **Layer 12** (downstream cascade) was silent-broken for 5+ weeks before discovery — fixed structurally by [`metanorma-cli#427`](https://github.com/metanorma/metanorma-cli/pull/427) + [`#430`](https://github.com/metanorma/metanorma-cli/pull/430), but the observability gap that allowed it to hide is still open ([`#302`](https://github.com/metanorma/ci/issues/302)).
- **Layer 9** OTP: rubygems MFA prompts for OTP. If the API key has MFA enforcement and there's no human at the terminal to paste the OTP, `gem push` fails. Workaround: use OIDC Trusted Publishing where possible; or rotate to an MFA-disabled key for CI use only.
- **Public husk gems** (`metanorma-nist 1.5.0`, `metanorma-bsi 0.7.0`): shipped 2026-06-28 to close the privatisation-public-husk hole for external `gem install` consumers. Doesn't change anything for the release chain itself, but worth knowing the husks exist when reading bundler resolution logs.

## Related

- [`metanorma/ci#302`](https://github.com/metanorma/ci/issues/302) — release-pipeline observability gap ("green means published")
- [`metanorma/ci#309`](https://github.com/metanorma/ci/issues/309) — release-workflow maintainer experience (this doc is the documentation half of #309's remediation)
- [`metanorma-cli#426`](https://github.com/metanorma/metanorma-cli/issues/426) / [`#427`](https://github.com/metanorma/metanorma-cli/pull/427) — docker dispatch silent failure (fixed)
- [`metanorma-cli#428`](https://github.com/metanorma/metanorma-cli/issues/428) — packed-mn dispatch chain (open, broader investigation)
- [`metanorma/cimas:plans/cimas-revival-and-release-workflow-realignment.md`](https://github.com/metanorma/cimas/blob/main/plans/cimas-revival-and-release-workflow-realignment.md) — canonical SSOT for cimas + release-workflow architectural decisions
