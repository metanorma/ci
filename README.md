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
| [`native-deps-action`](native-deps-action/) | List native library dependencies |
| [`change-tmpdir-action`](change-tmpdir-action/) | Change temp directory |

## Release workflow

### Quick start

```bash
gh workflow run release.yml -f next_version=patch
```

### How it works

The release is **test-gated by default**: the gem is only published after all tests pass.

```
gh workflow run release.yml -f next_version=patch
  │
  ▼
Phase 1 — BUMP (workflow_dispatch → rubygems-release.yml)
  Bumps version, creates git tag, pushes tag + commit.
  Does NOT publish the gem.
  │
  ▼
Phase 2 — TEST (tag push → rake.yml → generic-rake.yml)
  Runs the full test matrix (Ruby versions × OSes).
  │
  ▼
Phase 3 — PUBLISH (tests pass → do-release → rubygems-release.yml)
  Checks out the tagged commit, builds gem, pushes to RubyGems.
  An idempotent guard prevents double-publish.
  Dispatches release-passed for downstream dependents.
```

### Bypassing the test gate

```bash
gh workflow run release.yml -f next_version=patch -f gated=false
```

Publishes immediately. The idempotent guard handles the second push from do-release.

### Event chain

```
workflow_dispatch ──► rubygems-release.yml ──► gem bump --tag --push
                                                       │
                                                       ▼
                                              tag push event
                                                    ┌────┴──────────────────┐
                                                    │                       │
                                              rake.yml          (gated=false: publish
                                                    │            immediately in Phase 1)
                                                    ▼
                                          generic-rake.yml
                                          (test matrix runs)
                                                    │
                                        ┌───────────┴───────────┐
                                        ▼                       ▼
                                tests-passed dispatch    do-release dispatch
                                (downstream repos        (triggers release.yml
                                 notified)                → rubygems-release.yml
                                                          as repository_dispatch)
                                                                  │
                                                                  ▼
                                                          build + push gem
                                                          (idempotent guard)
                                                                  │
                                                                  ▼
                                                          release-passed dispatch
```

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

**release.yml** — release on manual trigger or do-release event:

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

Set these repository secrets:
- `METANORMA_CI_RUBYGEMS_API_KEY` — RubyGems API key for publishing
- `METANORMA_CI_PAT_TOKEN` — GitHub PAT for cross-repo operations

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
| `generic-rake.yml` | Run test matrix, dispatch tests-passed + do-release |
| `rubygems-release.yml` | Bump+tag (workflow_dispatch) or publish (repository_dispatch) |
| `monorepo-rubygems-release.yml` | Same as rubygems-release.yml for monorepo gems |
