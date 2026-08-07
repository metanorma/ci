# rubygems-release.yml

Reusable workflow for building and publishing a single Ruby gem to RubyGems.org.

A release is atomic: a maintainer dispatches the workflow with a version bump, and the workflow bumps, tags, and publishes in one job. There is no relay, no deferred publication, no second phase gated on tests. If the publish step does not run, the workflow fails — it does not report green.

## Who is this for

Any gem that wants to publish to RubyGems.org via GitHub Actions. The workflow is consumed two ways:

1. **Standalone** — any repo writes a `release.yml` that calls this workflow. No cimas installation, no `cimas.yml`, no special secret naming convention. Any GitHub secret works.
2. **Cimas-managed** — repos managed by [cimas](https://github.com/metanorma/cimas) have their `release.yml` auto-synced from a template in `cimas-config/gh-actions/master/release.yml`. Cimas is just one consumer of this workflow; it is not required.

Defaults and behavior are identical for both populations. Authentication works with any GitHub secret; the `METANORMA_CI_*` naming convention used by cimas is just one specialization.

## When does the gem actually get published?

**Always, on every `workflow_dispatch` run.** A green run means the gem is on rubygems.org. There is no deferred state.

The workflow also re-publishes idempotently if it's re-triggered by a stale `repository_dispatch: do-release` event from a consumer's rake.yml — the idempotent push guard sees the version is already published and treats that as success.

## Usage

```yaml
# .github/workflows/release.yml
name: release
on:
  workflow_dispatch:
    inputs:
      next_version:
        description: 'Next version (x.y.z, major, minor, patch, or skip)'
        required: true
        default: 'skip'
  repository_dispatch:
    types: [ do-release ]

permissions:
  contents: write
  id-token: write   # required for the OIDC Trusted Publishing path

jobs:
  release:
    uses: metanorma/ci/.github/workflows/rubygems-release.yml@main
    with:
      next_version: ${{ github.event.inputs.next_version }}
    secrets:
      rubygems-api-key: ${{ secrets.METANORMA_CI_RUBYGEMS_API_KEY }}
      pat_token: ${{ secrets.METANORMA_CI_PAT_TOKEN }}
```

The `repository_dispatch: do-release` listener is kept for backward compatibility with consumer rake.yml files that still dispatch it. In the new model the gem is already published by the time do-release fires; the idempotent guard handles the duplicate push.

## Consumer versioning discipline

The example above pins to `@main` for brevity. Production consumers should pin explicitly to one of two shapes:

- **`@v1` (moving tag)** — advances as this workflow evolves. Consumers get improvements automatically at the cost of silent behaviour shifts when the tag moves. Suitable for early-adopter repos willing to react to unannounced changes.

- **`@v1.x` (immutable tags)** — pinned to a specific release cut. Consumers explicitly version-bump when they want new behaviour. Aligned with the maintainer-authority principle: consumers know exactly which reusable version is in their release path, and are the ones who decide when to move to a new one.

Immutable tags never move once cut; the moving `v1` tag tracks the latest immutable `v1.x`. Check `git tag -l` on this repo for the current available immutable tags.

**Current baselines:**

- `v1.0.0` (`7ebab76`, 2026-07-23) — cimas-config cleanup baseline; predates the `#333`/`#370`/`#371` reverts.
- `v1.1.0` (*proposed on this PR's merge SHA*) — post-`#333`/`#370`/`#371` baseline: atomic publish, no breaking-change heuristic guard. Recommended pin for new consumers and for consumers wanting the current-blessed shape.

Version-bump semantics for this reusable follow SemVer at the reusable-interface level: consumer-facing input additions, deprecations, or behavioural changes trigger minor bumps; bug fixes without input-surface change trigger patch bumps.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `next_version` | yes | — | `patch`, `minor`, `major`, `x.y.z`, or `skip` (release the current gemspec version, no bump) |
| `release_command` | no | `bundle exec rake release` | Command to build and publish (API-key path only) |
| `bundler_cache` | no | `false` | **DEPRECATED — ignored.** The release job always runs with caching off. See [ci#314](https://github.com/metanorma/ci/issues/314). |
| `gated` | no | `false` | **DEPRECATED — ignored.** Kept as a no-op for backward compat with consumer repos that still pass it. The workflow always publishes immediately; the idempotent guard handles any duplicate push. See [ci#370](https://github.com/metanorma/ci/issues/370). |
| `post_install` | no | `''` | Command to run after `bundle install` |
| `submodules` | no | `true` | Checkout submodules |
| `role_to_assume` | no | — | OIDC Role ID (`rg_oidc_akr_…`) for RubyGems Trusted Publishing. If omitted with no API key, the workflow uses Trusted Publisher auto-discovery via `GITHUB_REPOSITORY`. |
| `environment` | no | `''` | GitHub environment name (e.g. `release` for required approvers) |
| `event_name` | no | — | Deprecated alias for `github.event_name`. |
| `release_notes` | no | `auto` | `auto` creates a GitHub Release with auto-generated notes if none exists; `manual` skips. See [ci#354](https://github.com/metanorma/ci/issues/354). |
| `version_advisory` | no | `false` | When true, run the Prism AST change-detector in preflight and emit a suggested bump. Advisory only — never blocks. See [ci#369](https://github.com/metanorma/ci/issues/369). |

## Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `rubygems-api-key` | no | RubyGems API key. If omitted, the workflow uses OIDC Trusted Publishing (with `role_to_assume` if set, otherwise auto-discovery). |
| `pat_token` | no | GitHub PAT for `repository_dispatch` calls (the `release-passed` event). When omitted, the workflow uses `github.token`. |

## Authentication

Three publish paths, selected automatically:

1. **API key** (default when `rubygems-api-key` is set): writes `~/.gem/credentials` and runs `release_command` (default `bundle exec rake release`, which builds + pushes).
2. **OIDC with explicit role** (when `rubygems-api-key` is empty and `role_to_assume` is set): uses `rubygems/configure-rubygems-credentials@v2.1.0` with the role token (`rg_oidc_akr_…`) to mint short-lived credentials, then `gem push`.
3. **OIDC Trusted Publisher auto-discovery** (when neither is set): same action with no `role-to-assume` input, discovers the trust config via `GITHUB_REPOSITORY`. Requires the gem's Trusted Publisher entry on rubygems.org to match this caller's repo + workflow filename.

All three paths require `id-token: write` on the calling workflow **only for paths 2 and 3**. Path 1 (API key) works without it, but declaring it at the top level is harmless and future-proof.

## Preflight checks (`workflow_dispatch` only)

The `preflight` job runs first on every `workflow_dispatch` invocation. Skipped on `repository_dispatch` and `push` paths (those already passed preflight in the originating dispatch leg). Total cost: ~90s–2min. If any check fails, the workflow stops before bump, tag, or publish.

Motivated by [ci#309](https://github.com/metanorma/ci/issues/309): the `metanorma-cli` v1.16.6 release wasted 2h27m to learn `bundle install` failed at the publish step. Preflight is the fail-fast answer.

| Check | What it catches |
|---|---|
| **Fresh `bundle install`** (with `Gemfile.lock` removed) | Dep-resolution failures: GH Packages auth slip, unsatisfiable constraint, missing private gem |
| **`gem build <gemspec>`** | Gemspec errors: syntax, missing files in `spec.files`, invalid metadata |
| **Verify publish credentials** | No `rubygems-api-key` AND no `role_to_assume` AND no Trusted Publisher config |
| **OIDC Trusted Publisher exchange** (only when no API key and no role) | Trust-policy mismatch on rubygems.org — runs the same `configure-rubygems-credentials@v2.1.0` action the publish step uses, just upfront |
| **`bundle exec rake` resolves** (release job, API-key path only) | `rake` not installed because the Gemfile excludes the development group. See [ci#363](https://github.com/metanorma/ci/issues/363). |
| **Version awareness** (informational, non-blocking) | Current gemspec version already on rubygems.org. For `next_version=skip` this means the publish will idempotent-skip. |
| **Version advisory** (opt-in, non-blocking) | Prism AST diff of `lib/` vs previous tag → suggested SemVer bump. Only when `version_advisory: true`. |

Preflight cannot catch everything. It runs on `ubuntu-latest` only, doesn't run the actual test matrix, can't dry-run MFA/OTP prompts, and doesn't verify downstream-cascade receivers.

## Idempotent publish

The workflow calls [`gem-idempotent-push-guard-action`](./gem-idempotent-push-guard.md) before `gem push`. The guard queries `rubygems.org/api/v1/versions/<gem>.json` for the gem name + version. If the version is already on rubygems, it sets `skip_push=true` and the publish step is skipped. The post-publish verification step still runs (and confirms the version is live).

This handles:

- A maintainer manually re-running `workflow_dispatch` after a partially-failed release.
- A consumer repo's rake.yml still dispatching `do-release` after the publish already happened (the legacy relay, now a no-op but tolerated).
- A `next_version: skip` run on a version that's already published.

The publish step itself also tolerates "already been pushed" errors from `gem push` (treats them as success with a `::notice::` in the audit trail). Belt and suspenders.

## Post-publish verification

After `gem push`, the workflow polls `rubygems.org/api/v1/versions/<gem>.json` every 5s for 120s. If the version is not visible after 120s, the workflow fails.

This catches silent-fail shapes where `gem push` returned green but the gem isn't actually live. See [ci#302](https://github.com/metanorma/ci/issues/302).

## Events dispatched

- **`release-passed`**: Dispatched after successful publish (via `peter-evans/repository-dispatch@v3`), carrying the tag ref + sha in the client payload. Downstream workflows in the caller repo (e.g. `notify.yml`, `ruby-artifacts.yml` for docker image rebuilds) trigger off this event.

## What happened to the gated relay

Previous versions of this workflow had a `gated` mode that deferred publication to a multi-hop relay: workflow_dispatch → tag push → rake tests → `repository_dispatch: do-release` → re-run workflow → publish. That architecture was reverted in [ci#370](https://github.com/metanorma/ci/issues/370) / [#371](https://github.com/metanorma/ci/pull/371) because:

- A green run could mean "tagged but not published," inverting the meaning of a green check.
- The relay required per-consumer wiring (a tag-listener workflow that dispatched `do-release`) that wasn't enforced. fractor's release failed silently because its rake.yml didn't dispatch do-release.
- The wrapper-workflow pattern (omnizip and similar non-cimas consumers) couldn't reach override inputs on the inner shared workflow.
- The original motivation (a double-publish race) was already handled by the idempotent push guard.

The `gated` input remains as a deprecated no-op for backward compatibility. Consumer repos that still pass `gated: true` will see no behavior change beyond the publish now happening immediately.

## Version advisory (opt-in)

When `version_advisory: true`, preflight runs the encapsulated composite action [`version-advisory-action`](../version-advisory-action/action.yml). It diffs `lib/` between the previous tag and HEAD via Prism AST and emits:

- a markdown table to `$GITHUB_STEP_SUMMARY` (change / classification / evidence / suggested bump)
- a `::notice::` with the overall suggested bump

Never blocks (exit 0 always). Default off — no behaviour change for existing consumers.

### Classification signals (first-match-wins)

1. Annotations: `# @api public` / `# @api private` / `:nodoc:` / Yard `@!method`
2. Contract file: `public_api.txt` allowlist at repo root (use-only-if-present)
3. Namespace convention: `Internal::` / `Private::` / leading `_`
4. Directory convention: `lib/*/internal/`, `lib/*/private/`
5. Default: `unknown`

### Bump table

| Change | public | internal | unknown |
|---|---|---|---|
| added | minor | patch | patch |
| removed / signature-broken | major (minor pre-1.0) | patch | unknown |
| body-changed | unknown | patch | unknown |

### Phase-2 limitations

`class << self`, `attr_*`, inheritance/include changes, `define_method` metaprogramming — not covered. Documented in the script header.

### Encapsulation

The heuristic lives in a composite action. Consumers of `rubygems-release.yml` never curl a raw script from main. Pin the reusable (and thereby the action) via the three-tier tag discipline.

## Related

- [`./monorepo-rubygems-release.md`](./monorepo-rubygems-release.md) — monorepo variant
- [`./gem-idempotent-push-guard.md`](./gem-idempotent-push-guard.md) — the idempotency guard action
- [`./generic-rake.md`](./generic-rake.md) — the rake test matrix reusable workflow
- [`./prepare-rake.md`](./prepare-rake.md) — rake setup helper
- [ci#370](https://github.com/metanorma/ci/issues/370) — revert of the gated relay architecture
- [ci#309](https://github.com/metanorma/ci/issues/309) — release-workflow maintainer experience (origin of preflight)
- [ci#314](https://github.com/metanorma/ci/issues/314) — `bundler-cache: false` (stale-cache missing-gem class)
