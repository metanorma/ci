# Render baseline program (ci#504 → #505 → #506 → #507)

The fleet's render changes are currently validated by smoke-green only.
This program adds the professional discipline: **every render is diffed
against a frozen baseline; every diff is classified; regressions block.**

## Components

| Workflow | Issue | Role |
|---|---|---|
| [`render-baseline.yml`](../.github/workflows/render-baseline.yml) | #504 | The harness: render a samples repo with a pinned `metanorma/metanorma` tag, hash every output file into a manifest, then **capture** (freeze the manifest on the `render-baselines` branch) or **compare** (diff against it) |
| the compare step's classifier | #505 | The regression vocabulary: each diff is `accepted` (path matches the repo's acceptlist) or `regression` (blocks). No silent passes |
| [`render-drift-weekly.yml`](../.github/workflows/render-drift-weekly.yml) | #506 | Weekly scheduled compare of the full samples family rendered with `:latest` against the frozen baselines — catches image-drift-induced render changes |
| [`render-parity.yml`](../.github/workflows/render-parity.yml) | #507 | Cross-engine gate: render under both engine lines and diff the outputs per flavor |

## Usage

### Freeze a baseline (once per samples repo, and after every blessed change)

```sh
gh workflow run render-baseline-capture.yml \
  -f samples_repo=mn-samples-iso \
  -f image_tag=metanorma-metanorma-<frozen-tag>
```

The capture run commits `manifests/<repo>.ndjson` (sorted
`sha256  path` lines) plus a `.meta.yaml` provenance sidecar to the
[`render-baselines`](../../tree/render-baselines) branch.

### Compare (CI gate or manual)

Any caller workflow invokes the reusable with `mode: compare`. The
conclusion output is one of `clean`, `drift-accepted`, `regression` —
`regression` fails the run.

## The ci#505 vocabulary

There are exactly **three conclusions** and **two diff classes**:

- **Diff classes** — every changed/added/removed path is classified by
  the repo's acceptlist (`.render-acceptlist.yml` in the samples repo):

  ```yaml
  patterns:
    # exact-path or glob, with a reason; reasons are load-bearing
    - "documents/**/index.html"      # canonicalization pending (ci#505 follow-up)
    - glob: "**/*.jsonld"
      reason: "embedded build epoch — awaiting metanorma-side fix"
  ```

- **Conclusions** — `clean` (no diffs), `drift-accepted` (diffs, all
  acceptlisted), `regression` (any unacceptlisted diff → the run fails).

**Rule: an acceptlist entry without a reason is a review reject.**
Accepted entries are debt — each one documents the metanorma-side fix
that will let us remove it.

## Non-determinism policy

First-pass hashing is raw bytes. Sources of known non-determinism
(embedded epochs, generated UUIDs, locale-ordered maps) are handled by
acceptlist entries in the short term and by canonicalizers in the
harness long-term — each canonicalizer retires an acceptlist entry, and
the entry's reason names the fix (this keeps the debt auditable).

## Freezing the baseline set

The managed samples family is listed in
[`render-drift-weekly.yml`](../.github/workflows/render-drift-weekly.yml)
(keep in sync with cimas.yml's samples group). Baselines freeze per
samples repo from the pinned image tag; `:latest` is only ever used on
the compare (drift) side.

## Content parity for the two-engine gate (ci#507)

`scripts/html_parity.py --mode content` compares what the HTML says, not how
it is marked up. The isodoc and document engines use different classes,
wrappers, TOC and header chrome, so a markup diff is never empty. Content mode
reduces each file to ordered `(block type, heading level, text)` blocks and
reports `missing` (isodoc text absent from the document output), `extra`,
`retyped`, `reflowed` and `out_of_order` counts. It passes when
`missing <= --max-missing` (default 0): nothing lost against the legacy output.

### Rendering both engines

`html_parity.py` renders each engine through
[`scripts/render_engines.rb`](../scripts/render_engines.rb), which calls
metanorma-core's factory
(`Metanorma::Core::Isodoc.create(flavor, ..., presxml: false, html_engine: :isodoc|:document)`,
core PR #38). Nothing reads an engine environment variable, and
`metanorma site generate` never calls the factory, so the CLI has no engine
switch. The default render command is:

```sh
PARITY_FLAVOR={flavor} BUNDLE_GEMFILE=gemfiles/html_parity.gemfile \
  bundle exec ruby scripts/render_engines.rb \
  --flavor {flavor} --engine {engine} --input {samples} --out {out}
```

- `--input` is an `.adoc` file, a directory of `.adoc` files (a `sources/`
  subdirectory is preferred), or a directory of `*.presentation.xml` files,
  which skips the AsciiDoc and presentation steps. Output is `<out>/<name>.html`.
- Gems come from
  [`gemfiles/html_parity.gemfile`](../gemfiles/html_parity.gemfile):
  `metanorma-<flavor>` (chosen by `PARITY_FLAVOR`), `metanorma-document`, and
  `metanorma-core` from the `combine/engine-dispatch-682` branch until core#38
  is released. A taste (`iala`, `wmo`) loads its base flavor gem (`metanorma-iho`)
  plus `metanorma-taste`; set `METANORMA_TASTE_PATH` to use a local checkout. Set `METANORMA_CORE_PATH` for a local core checkout or
  `METANORMA_CORE_REF` for another ref. Run `bundle install` once with the same
  two variables set; no lockfile is committed.
- The command template accepts `{engine} {out} {flavor} {samples} {script} {gemfile}`.
  `--render-cmd` replaces it, and `--isodoc-dir/--document-dir` skip rendering.

Example (content mode):

```sh
export METANORMA_CORE_PATH=~/metanorma-core   # optional
PARITY_FLAVOR=iec BUNDLE_GEMFILE=$PWD/gemfiles/html_parity.gemfile bundle install
python3 scripts/html_parity.py iec --samples-dir ../mn-samples-iec --mode content
```
