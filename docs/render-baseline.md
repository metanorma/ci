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
| [`render-parity.yml`](../.github/workflows/render-parity.yml) | #507 | Cross-engine gate: render under both engine lines and upload a sha256 manifest per engine. It does not yet diff them: the parity job only checks that both manifests exist (else reports N/A for single-engine flavors) and prints a notice; the per-file diff and the blocking rule follow once the ci#505 parity vocabulary is ratified |

## Usage

### Freeze a baseline (once per samples repo, and after every blessed change)

Baselines live on the `render-baselines` branch of this repository (not
in a separate repository). Capture is a manual dispatch of
[`render-baseline-capture.yml`](../.github/workflows/render-baseline-capture.yml),
which calls the reusable `render-baseline.yml` with `mode: capture`:

```sh
gh workflow run render-baseline-capture.yml \
  -f samples_repo=mn-samples-iso \
  -f image_tag=metanorma-metanorma-<frozen-tag>
```

The optional `baseline_key` input overrides the file stem (default: the
samples repo name). The capture run commits `manifests/<key>.ndjson`
(sorted `sha256  path` lines) plus a `manifests/<key>.meta.yaml`
provenance sidecar to the
[`render-baselines`](https://github.com/metanorma/ci/tree/render-baselines)
branch.

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
    # exact-path or glob, with a reason; reasons are load-bearing.
    # An entry is either a bare string, or a one-key map of
    # "<pattern>": "<reason>" (the compare step reads the map's first key
    # as the pattern, so the pattern must be the key).
    - "documents/**/index.html"      # canonicalization pending (ci#505 follow-up)
    - "**/*.jsonld": "embedded build epoch — awaiting metanorma-side fix"
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
