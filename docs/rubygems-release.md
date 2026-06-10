# rubygems-release.yml

Reusable workflow for building and publishing a single Ruby gem to RubyGems.org.

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

jobs:
  release:
    uses: metanorma/ci/.github/workflows/rubygems-release.yml@main
    with:
      next_version: ${{ github.event.inputs.next_version }}
    secrets:
      rubygems-api-key: ${{ secrets.METANORMA_CI_RUBYGEMS_API_KEY }}
      pat_token: ${{ secrets.METANORMA_CI_PAT_TOKEN }}
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `next_version` | yes | — | Version bump type (`patch`, `minor`, `major`, `x.y.z`) or `skip` to release the current gemspec version |
| `gated` | no | `true` | Defer publish until tests pass via do-release chain. Set `false` to publish immediately. |
| `release_command` | no | `bundle exec rake release` | Command to build and publish (API key auth only) |
| `bundler_cache` | no | `true` | Run `bundle install` |
| `post_install` | no | `''` | Command to run after `bundle install` |
| `submodules` | no | `true` | Checkout submodules |
| `role_to_assume` | no | — | OIDC Role ID for RubyGems Trusted Publishing |
| `environment` | no | `''` | GitHub environment name (e.g., for required approvers) |

## Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `rubygems-api-key` | no | RubyGems API key. If omitted, uses OIDC Trusted Publishing. |
| `pat_token` | no | GitHub PAT for cross-repo operations and pushing tags. |

## Authentication

Two authentication paths:

1. **API Key** (default when `rubygems-api-key` secret is set): Uses the API key to authenticate with RubyGems.
2. **OIDC Trusted Publishing** (when no API key): Uses `rubygems/configure-rubygems-credentials` for keyless authentication.

## Behavior

### `gated: true` (default)

```
workflow_dispatch → bump + tag + push (no publish)
  → tag push triggers rake.yml → tests → do-release → publish
```

### `gated: false`

```
workflow_dispatch → bump + tag + push + publish immediately
  → tag push triggers rake.yml → tests → do-release → idempotent skip
```

### `next_version=skip`

No version bump. Creates and pushes a tag from the current gemspec version so the test chain fires.

## Events dispatched

- `release-passed`: Dispatched after successful publish, for downstream notification.
