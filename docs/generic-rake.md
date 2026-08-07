# generic-rake.yml

Reusable workflow for running `bundle exec rake` across a Ruby version × OS test matrix.

## Usage

```yaml
# .github/workflows/rake.yml
name: rake
on:
  push:
    branches: [ master, main ]
    tags: [ v* ]
  pull_request:

jobs:
  rake:
    uses: metanorma/ci/.github/workflows/generic-rake.yml@main
    with:
      setup-tools: inkscape,ghostscript
    secrets:
      pat_token: ${{ secrets.METANORMA_CI_PAT_TOKEN }}
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `cascade` | no | `true` | When true, fire `tests-passed` / `do-release` repository_dispatch after the matrix. When false, skip the cascade job so callers can declare `permissions: contents: read` |
| `tests-passed-event` | no | `tests-passed` | Event name dispatched after tests pass (only when `cascade: true`) |
| `release-event` | no | `do-release` | Event name dispatched when tests pass on a tag ref (only when `cascade: true`) |
| `before-setup-ruby` | no | `''` | Command to run before Ruby setup |
| `after-setup-ruby` | no | `''` | Command to run after Ruby setup |
| `shell` | no | `bash` | Shell for running commands |
| `setup-inkscape` | no | `false` | Legacy — use `setup-tools` instead |
| `setup-tools` | no | `''` | Comma-separated tools: `inkscape,ghostscript,graphviz,libreoffice,xml2rfc,exiftool,ffmpeg,imagemagick,yq` |
| `submodules` | no | `recursive` | Checkout submodules: `true`, `false`, or `recursive` |
| `private-fonts` | no | `false` | Enable private fonts via fontist-repo-setup |
| `private-fonts-username` | no | `metanorma-ci` | Username for private fonts repository |
| `choco-cache` | no | `false` | Cache Chocolatey on Windows |

## Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `pat_token` | no | GitHub PAT for checkout and repository dispatch |

## Behavior

1. Calls `prepare-rake.yml` to resolve the test matrix.
2. Runs `bundle exec rake` across all Ruby versions and OSes.
3. When `cascade: true` (default): on success, dispatches `tests-passed` event; if the ref is a tag (`refs/tags/v*`), also dispatches `do-release` (triggers the release pipeline).
4. When `cascade: false`: matrix only — no repository_dispatch. Callers may declare `permissions: contents: read`.

The test matrix is defined in [ruby-matrix.json](../.github/workflows/ruby-matrix.json).

## Least-privilege caller (cascade off)

One reusable. One concern. Extended via the `cascade` input — no sibling reusable.

Cimas template: [`cimas-config/gh-actions/master/rake_test_only.yml`](../cimas-config/gh-actions/master/rake_test_only.yml)

```yaml
# master/rake_test_only.yml (thin caller)
permissions:
  contents: read
jobs:
  rake:
    uses: metanorma/ci/.github/workflows/generic-rake.yml@main
    with:
      cascade: false
```

### When to use cascade: false

- Sample repositories (`mn-samples-*`) that CI but do not gem-release.
- Model repositories (`metanorma-model-*`) that validate grammar/schema but do not gem-release.
- Any gem whose release is triggered externally rather than via `do-release`.

### When NOT to use cascade: false

Any gem mapped to a release template (`master/release.yml`, `master/release_manual_notes.yml`, etc.). Those consume the `do-release` event that only fires when `cascade: true`. Switching a release-participating repo to cascade-off silently breaks its release chain.

### How to switch

In the target repo's `cimas.yml` entry, replace the `master/rake.yml` mapping with `master/rake_test_only.yml`, then run the cimas sync wave. Reverse to restore cascade.
