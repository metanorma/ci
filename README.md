# Metanorma CI

Shared GitHub Actions workflows and composite actions for building, testing, and releasing [Metanorma](https://metanorma.org) Ruby gems.

## Reusable workflows

### Testing

| Workflow | Purpose |
|----------|---------|
| [`generic-rake.yml`](docs/generic-rake.md) | Run `bundle exec rake` across a Ruby version × OS matrix |
| [`prepare-rake.yml`](docs/prepare-rake.md) | Tag detection, foreign-PR detection, test matrix resolution |
| [`dependent-rake.yml`](.github/workflows/dependent-rake.yml) | Test downstream gems against the current gem |
| [`monorepo-rake.yml`](.github/workflows/monorepo-rake.yml) | Test matrix for monorepo gems |
| [`mn-processor-rake.yml`](.github/workflows/mn-processor-rake.yml) | Rake for Metanorma processor repos |
| [`graphviz-rake.yml`](.github/workflows/graphviz-rake.yml) | Rake with Graphviz pre-installed |
| [`inkscape-rake.yml`](.github/workflows/inkscape-rake.yml) | Rake with Inkscape pre-installed |
| [`libreoffice-rake.yml`](.github/workflows/libreoffice-rake.yml) | Rake with LibreOffice pre-installed |
| [`xml2rfc-rake.yml`](.github/workflows/xml2rfc-rake.yml) | Rake with xml2rfc pre-installed |

### Releasing

| Workflow | Purpose |
|----------|---------|
| [`rubygems-release.yml`](docs/rubygems-release.md) | Build and publish a gem to RubyGems.org |
| [`monorepo-rubygems-release.yml`](docs/monorepo-rubygems-release.md) | Build and publish a monorepo gem to RubyGems.org |
| [`ghpkg-release.yml`](.github/workflows/ghpkg-release.yml) | Publish a gem to GitHub Packages |

### Other

| Workflow | Purpose |
|----------|---------|
| [`sample-test.yml`](.github/workflows/sample-test.yml) | Test generated samples |
| [`template-test.yml`](.github/workflows/template-test.yml) | Test template rendering |
| [`sample-docker.yml`](.github/workflows/sample-docker.yml) | Generate samples in Docker |
| [`build-sample-matrix.yml`](.github/workflows/build-sample-matrix.yml) | Build sample test matrix |
| [`mn-processor-notify.yml`](.github/workflows/mn-processor-notify.yml) | Notify downstream processors |

## Composite actions

| Action | Purpose |
|--------|---------|
| [`tool-setup-action`](tool-setup-action/) | Install optional tools (inkscape, ghostscript, graphviz, etc.) |
| [`gem-idempotent-push-guard-action`](docs/gem-idempotent-push-guard.md) | Skip gem push if version already exists on rubygems.org |
| [`gh-rubygems-setup-action`](gh-rubygems-setup-action/) | Configure private GitHub Packages for RubyGems |
| [`gh-repo-status-action`](gh-repo-status-action/) | Check if a repository is public or private |
| [`gh-pages-status-action`](gh-pages-status-action/) | Check GitHub Pages deployment status |
| [`choco-cache-action`](choco-cache-action/) | Cache Chocolatey packages on Windows |
| [`inkscape-setup-action`](inkscape-setup-action/) | Install Inkscape |
| [`ghostscript-setup-action`](ghostscript-setup-action/) | Install Ghostscript |
| [`graphviz-setup-action`](graphviz-setup-action/) | Install Graphviz |
| [`imagemagick-setup-action`](imagemagick-setup-action/) | Install ImageMagick |
| [`libreoffice-setup-action`](libreoffice-setup-action/) | Install LibreOffice |
| [`ffmpeg-setup-action`](ffmpeg-setup-action/) | Install FFmpeg |
| [`exiftool-setup-action`](exiftool-setup-action/) | Install ExifTool |
| [`xml2rfc-setup-action`](xml2rfc-setup-action/) | Install xml2rfc |
| [`yq-setup-action`](yq-setup-action/) | Install yq |
| [`native-deps-action`](native-deps-action/) | List native library dependencies |
| [`change-tmpdir-action`](change-tmpdir-action/) | Change temp directory |

## Release workflow

### Quick start

```bash
gh workflow run release.yml -f next_version=patch
```

### How it works

A release is **atomic**: a maintainer dispatches `release.yml` with a version bump, and the workflow bumps, tags, and publishes in one job. A green run means the gem is on rubygems.org — there is no deferred state, no second phase gated on tests.

```
gh workflow run release.yml -f next_version=patch
  │
  ▼
workflow_dispatch → rubygems-release.yml
  │
  ├─ preflight (bundle install, gem build, credentials check — fail-fast)
  │
  ├─ bump version + push tag
  │
  ├─ idempotent push guard (skip if already published)
  │
  ├─ gem build + gem push
  │
  ├─ verify gem live on rubygems.org (poll)
  │
  └─ dispatch release-passed → downstream cascade
```

Tests still run on tag push via the consumer repo's `rake.yml`, but they no longer gate publication. Branch protection with required status checks is the right tool for gating merges on test passage; release-time gating is the wrong layer.

### Setting up a new repo

Create two workflow files in `.github/workflows/`:

**rake.yml** — test on every push, PR, and tag:

```yaml
name: rake
on:
  push:
    branches: [ master, main ]
    tags: [ v* ]
  pull_request:
jobs:
  rake:
    uses: metanorma/ci/.github/workflows/generic-rake.yml@main
    secrets:
      pat_token: ${{ secrets.METANORMA_CI_PAT_TOKEN }}
```

**release.yml** — release on manual trigger:

```yaml
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
jobs:
  release:
    uses: metanorma/ci/.github/workflows/rubygems-release.yml@main
    with:
      next_version: ${{ github.event.inputs.next_version }}
    secrets:
      rubygems-api-key: ${{ secrets.METANORMA_CI_RUBYGEMS_API_KEY }}
      pat_token: ${{ secrets.METANORMA_CI_PAT_TOKEN }}
```

The `repository_dispatch: do-release` listener is optional — kept for backward compatibility with consumer rake.yml files that still dispatch it. In the new model the gem is already published by the time do-release fires; the idempotent guard handles the duplicate push.

Any GitHub secret works for authentication. The `METANORMA_CI_*` naming convention is used by [cimas](https://github.com/metanorma/cimas)-managed repos; standalone consumers can name their secrets however they like.

Set these repository secrets:
- `METANORMA_CI_RUBYGEMS_API_KEY` — RubyGems API key for publishing (or any name you choose)
- `METANORMA_CI_PAT_TOKEN` — GitHub PAT for cross-repo operations (or any name you choose)

### Monorepo releases

For repos containing multiple gems:

```yaml
jobs:
  release:
    uses: metanorma/ci/.github/workflows/monorepo-rubygems-release.yml@main
    with:
      gem_name: coradoc
      next_version: patch
    secrets:
      rubygems-api-key: ${{ secrets.METANORMA_CI_RUBYGEMS_API_KEY }}
      pat_token: ${{ secrets.METANORMA_CI_PAT_TOKEN }}
```

### Workflow responsibilities

| File | Responsibility |
|------|---------------|
| `prepare-rake.yml` | Detect tags, foreign PRs, resolve test matrix |
| `generic-rake.yml` | Run test matrix |
| `rubygems-release.yml` | Bump + tag + publish (atomic) |
| `monorepo-rubygems-release.yml` | Same as rubygems-release.yml for monorepo gems |
