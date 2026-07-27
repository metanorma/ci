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
| `tests-passed-event` | no | `tests-passed` | Event name dispatched after tests pass |
| `release-event` | no | `do-release` | Event name dispatched when tests pass on a tag ref |
| `before-setup-ruby` | no | `''` | Command to run before Ruby setup |
| `after-setup-ruby` | no | `''` | Command to run after Ruby setup |
| `shell` | no | `bash` | Shell for running commands |
| `setup-inkscape` | no | `false` | Legacy — use `setup-tools` instead |
| `setup-tools` | no | `''` | Comma-separated tools: `inkscape,ghostscript,graphviz,libreoffice,xml2rfc,exiftool,ffmpeg,imagemagick` |
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
3. On success, dispatches `tests-passed` event.
4. If the ref is a tag (`refs/tags/v*`), also dispatches `do-release` event (triggers the release pipeline).

The test matrix is defined in [ruby-matrix.json](../.github/workflows/ruby-matrix.json).

## Test-only variant (opt-in, least-privilege)

For repositories that run `bundle exec rake` for CI but do **not** publish a gem on tag push and do **not** participate in the `tests-passed` downstream cascade, an opt-in variant is available:

- Reusable: [`generic-rake-test-only.yml`](../.github/workflows/generic-rake-test-only.yml)
- Cimas template: [`cimas-config/gh-actions/master/rake_test_only.yml`](../cimas-config/gh-actions/master/rake_test_only.yml)

### What the variant drops

The `tests-passed` job (both `tests-passed` and `do-release` `repository_dispatch` events) is removed entirely. The `tests-passed-event` and `release-event` inputs are also removed since they are no longer consumed.

### What the variant gains

The caller can declare `permissions: contents: read` at the workflow level — the least-privilege ceiling that GitHub Actions permits for a reusable-workflow-caller pair. `generic-rake.yml`'s `tests-passed` job requires `contents: write` (to fire the `peter-evans/repository-dispatch` action), which forces its callers to declare `contents: write` at the workflow level; the test-only variant has no such requirement.

### When to use it

- **Sample repositories** (`mn-samples-*`) that run `bundle exec rake` for CI but are not gem-releasing.
- **Model repositories** (`metanorma-model-*`) that run `bundle exec rake` for grammar / schema validation but are not gem-releasing.
- Any gem whose release is triggered by an external mechanism (external dispatcher, manual `rake release`, etc.) rather than the `do-release` `repository_dispatch` event.

### When NOT to use it

Any gem that participates in the release cascade — i.e. any gem mapped in cimas.yml to `master/release.yml`, `master/release_manual_notes.yml`, `master/release_wo_bundle_install_manual_notes.yml`, `master/release_github_packages.yml`, or `master/release_wo_bundle_install.yml`. Those templates consume the `do-release` event that only `generic-rake.yml` fires; switching a release-participating repo to the test-only variant will silently break its release chain (the `do-release` dispatch will no longer fire from CI).

### How to switch

In the target repo's `cimas.yml` entry, replace the `master/rake.yml` mapping with `master/rake_test_only.yml`, then run the cimas sync wave to propagate the change. To switch back, replace in the other direction and re-sync.
