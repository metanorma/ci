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
