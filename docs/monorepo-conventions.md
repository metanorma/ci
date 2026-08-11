# Monorepo conventions

This document codifies conventions for supporting monorepo-shaped repositories in the metanorma stack — specifically their `cimas.yml` entries, shared CI reusable workflows, and template shape.

Two known monorepo shapes exist in the stack as of 2026-08-10:

- **Schema/model monorepo** — one repo, N per-flavor subdirectories + shared grammar hub. Instance: `metanorma/standoc-models` (16 flavor subdirs `bipm/` `bsi/` `cc/` `csa/` `gb/` `ieee/` `iho/` `iso/` `itu/` `m3aawg/` `mpfa/` `nist/` `ogc/` `ribose/` `standoc/` `un/` + `grammars/`, landed via [`metanorma-core#16`](https://github.com/metanorma/metanorma-core/issues/16) / [`metanorma/ci#390`](https://github.com/metanorma/ci/pull/390)).
- **Ruby-gem monorepo** — one repo, N per-gem subdirectories under `gems/`. Instance: `metanorma/coradoc` (surfaced via [`metanorma/ci#358`](https://github.com/metanorma/ci/issues/358) / [`#359`](https://github.com/metanorma/ci/issues/359); not yet cimas-managed as of this writing).

The conventions below apply to both shapes; each convention notes shape-specific application where it differs.

## Convention 1: Single cimas.yml entry per monorepo

A monorepo has ONE `cimas.yml` entry (not N entries per sub-unit). The entry's `files:` block maps per-subdirectory paths to the appropriate `gh-actions/*` templates.

Example (standoc-models):

```yaml
standoc-models:
  remote: ssh://git@github.com/metanorma/standoc-models
  branch: main
  files:
    bipm/Gemfile: gh-actions/model/Gemfile
    bipm/Makefile: gh-actions/model/Makefile
    bsi/Gemfile: gh-actions/model/Gemfile
    # ... 16 flavors × 2 files ...
    grammars/Gemfile: gh-actions/model/Gemfile.grammar-build
    .github/workflows/make.yml: gh-actions/standoc-models/make.yml
    .github/workflows/deploy.yml: gh-actions/standoc-models/deploy.yml
    .github/workflows/automerge.yml: gh-actions/master/automerge.yml
```

**Trade-off**: verbose mappings per sub-unit vs. maintainability. Adding a sub-unit requires adding its per-sub mappings to the one entry (still cheaper than adding N separate `cimas.yml` entries).

**Shape-specific application**:

- Schema/model monorepo: mappings per flavor subdirectory (`<flavor>/Gemfile`, `<flavor>/Makefile`) + optional grammar-hub mapping (`grammars/Gemfile` for the grammar-build variant).
- Ruby-gem monorepo: mappings per gem subdirectory (`gems/<gem>/Gemfile`, `gems/<gem>/Rakefile`, etc.) + optional monorepo-level workflow mapping.

## Convention 2: Path-filtered per-subunit CI matrix in the shared reusable

The reusable workflow at `metanorma/ci/.github/workflows/<monorepo>-make.yml` computes which sub-units changed using `git diff --name-only $BASE_SHA...HEAD`, filtered by an alternation-regex derived from a single-source-of-truth shell variable. Full-rebuild triggers: main-push, tag-push, `workflow_dispatch`, cross-cutting changes (any file outside single-subunit scope), git diff failure (fail-safe against vacuously-green CI). Per-subunit matrix builds from `changed_units[] × os[]`.

Reference implementation: [`metanorma/ci/.github/workflows/standoc-models-make.yml`](https://github.com/metanorma/ci/blob/main/.github/workflows/standoc-models-make.yml) (landed via [`metanorma/ci#390`](https://github.com/metanorma/ci/pull/390)). Four jobs:

- `prepare-matrix` — OS matrix + default Ruby version via `prepare-rake.yml`.
- `prepare-filter` — path-filter shell computing `changed_units[]`, `hub_changed` (grammar/shared-code touch), `full_rebuild` flag.
- `<hub-build>` — conditional on `hub_changed` or `full_rebuild` (e.g., `grammar-build` for standoc-models).
- `per-subunit-make` — matrix strategy over `[changed_units × os]`.

**Shape-specific application**:

- Schema/model monorepo: per-flavor matrix + grammar-build as a separate job (grammar-build is decoupled from per-flavor build since flavors consume vendored artefacts from the grammar hub independently — see convention 4 sub-note about hub-vendoring).
- Ruby-gem monorepo: per-gem matrix; no separate hub job unless the monorepo has a shared build phase (e.g., shared code generation before per-gem tests).

**Defensive requirements** (from ci#390's code-review pass):

- `git diff` failure must fall through to full-rebuild — don't emit an empty matrix that silent-passes CI.
- Concurrency group must use `${{ github.head_ref || github.sha }}` for push events — empty `head_ref` on push must not cause cross-commit cancellation of full-rebuild waves on main.
- Single source of truth for the sub-unit list — extract to a shell variable at the top of the filter step; both the JSON array literal and the alternation-regex derive from it (avoids triple-duplication drift).

## Convention 3: Local-ref (./) for intra-ci reusable calls

For workflows inside `metanorma/ci` calling other workflows inside `metanorma/ci`, use local-ref instead of external-ref-with-pin:

```yaml
# In metanorma/ci/.github/workflows/some-workflow.yml
jobs:
  prepare:
    uses: ./.github/workflows/prepare-rake.yml   # local-ref (this doc's recommendation)
    # NOT: uses: metanorma/ci/.github/workflows/prepare-rake.yml@main
```

Local-ref evaluates against the same repo + same ref as the caller. Sidesteps the standing-rule question about `@main` vs `@v1` for intra-repo references (per the [`metanorma/ci#375`](https://github.com/metanorma/ci/pull/375) discussion of the three-tier tag discipline from [`metanorma/ci#372`](https://github.com/metanorma/ci/pull/372)).

External-ref-with-pin remains correct for **consumer workflows outside metanorma/ci** calling into it (`uses: metanorma/ci/.github/workflows/<file>.yml@v1`), per the three-tier tag discipline.

## Convention 4: Config-file-based opt-in for consumer-specific features

For monorepo (or consumer) features that vary per-consumer (e.g., custom rendering pipelines, per-doc parameters, deploy-target overrides), the shared template dispatches based on a repo-local config file at the consumer root:

- Shared template steps read the config file (e.g., `.<feature>-config.json`) if present, and dispatch feature-specific matrix / job / step accordingly.
- If the config file is absent, feature is off; template runs its default path.
- Consumer maintains the config file (repo-scoped, small); template consumes it.

Reference proposal: [`metanorma/ci#389`](https://github.com/metanorma/ci/issues/389) (Firelight opt-in for `samples/public-docker.yml`) — proposes `.firelight-config.json` schema at samples-repo root, template steps gated by config presence.

**Rationale**: avoids both (a) sibling-workflow fragmentation (spinning up per-consumer variant templates, which is the anti-pattern rejected by the standing rule at [`metanorma/ci#376`](https://github.com/metanorma/ci/pull/376)) and (b) hard-coded consumer-specific matrix/job values in shared templates (which don't scale beyond one consumer).

**Shape-specific application**:

- Schema/model monorepo: config file could specify per-flavor parameter overrides (e.g., which flavors participate in a special deploy pipeline).
- Ruby-gem monorepo: config file could specify per-gem test-matrix overrides (e.g., Ruby versions, OS matrix) that differ from the monorepo default.
- Samples monorepo (Firelight case): config file specifies per-repo document matrix + FL-specific packages, so the shared docker.yml template can offer opt-in FL without hard-coding any consumer's config.

## Convention 5: New conventions land via design ticket, not injection

Any addition or modification to these conventions goes through the design-decision path:

1. Open a design ticket on `metanorma/ci` (or update this doc via PR that references a design ticket).
2. Discussion + assent from maintainers.
3. Land the convention (either as a doc PR here, or as a reusable-workflow / template change with its own PR).

Standing rules or conventions should not be introduced ad-hoc via PR-supersede comments on unrelated PRs. Ad-hoc injection is hard to reference back to for later review, and can create ambiguity about which rules apply where.

Recorded per the standing-rules-as-guidelines acknowledgment shape on [`metanorma/ci#375`](https://github.com/metanorma/ci/pull/375) + [`#376`](https://github.com/metanorma/ci/pull/376) comments (2026-08-10).

## Application table (2026-08-10)

| Convention | standoc-models (schema/model) | coradoc (Ruby-gem) |
|---|---|---|
| 1. Single cimas.yml entry, N × M mappings | ✅ landed via [ci#390](https://github.com/metanorma/ci/pull/390) | ⬜ not yet cimas-managed (per [ci#359](https://github.com/metanorma/ci/issues/359)) |
| 2. Path-filtered per-subunit CI matrix | ✅ landed via `standoc-models-make.yml` | ⬜ not yet implemented |
| 3. Local-ref (`./`) for intra-ci reusable calls | ✅ `standoc-models-make.yml` uses `./.github/workflows/prepare-rake.yml` | n/a (coradoc is downstream consumer, not intra-ci) |
| 4. Config-file-based opt-in for consumer-specific features | ⬜ proposed via [ci#389](https://github.com/metanorma/ci/issues/389); not yet applied | ⬜ candidate for per-gem override support |
| 5. New conventions via design-decision path | Applies to any future addition here | Applies to any future addition here |

## Open questions / future work

- **Third monorepo shape validation**: two shapes covered here (schema/model, Ruby-gem). A third distinct shape (e.g., a documentation monorepo with per-doc subdirs) would validate the convention set beyond just these two.
- **Cimas schema extensions for monorepos**: per [`metanorma/ci#300`](https://github.com/metanorma/ci/issues/300)'s proposed schema extensions (Gap 2: monorepo sub-template family; Gap 3: drift-audit / opt-out detection), the `cimas.yml` schema itself may evolve to first-class support for monorepo shapes rather than requiring per-sub mappings.
- **Consumer conversion arcs**: for existing monorepo repos (coradoc; any others yet to be identified), converting from local-only workflow shape to cimas-managed will follow the [`metanorma/cimas#68`](https://github.com/metanorma/cimas/issues/68) conversion-arc pattern (batches by ownership, direct-to-main `cimas.yml` unmap after PRs merge).

## Cross-references

- [`metanorma/metanorma-core#16`](https://github.com/metanorma/metanorma-core/issues/16) — standoc-models P3 parent design ticket.
- [`metanorma/ci#358`](https://github.com/metanorma/ci/issues/358) / [`#359`](https://github.com/metanorma/ci/issues/359) — coradoc-as-monorepo discovery + convention discussion.
- [`metanorma/ci#372`](https://github.com/metanorma/ci/pull/372) — three-tier tag discipline (external-ref pinning for consumer workflows).
- [`metanorma/ci#375`](https://github.com/metanorma/ci/pull/375) / [`#376`](https://github.com/metanorma/ci/pull/376) — standing-rules-via-injection pattern that convention 5 preempts.
- [`metanorma/ci#389`](https://github.com/metanorma/ci/issues/389) — Firelight opt-in as first application of convention 4.
- [`metanorma/ci#390`](https://github.com/metanorma/ci/pull/390) — `standoc-models-make.yml` reusable as first application of conventions 2 and 3.
