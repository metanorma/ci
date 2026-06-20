# monorepo-rubygems-release.yml

Reusable workflow for building and publishing a single gem from a monorepo to RubyGems.org.

Same architecture as `rubygems-release.yml` but with `gem_name` and `gem_directory` inputs for working directory support.

## Usage

```yaml
jobs:
  release:
    uses: metanorma/ci/.github/workflows/monorepo-rubygems-release.yml@main
    with:
      gem_name: coradoc        # sub-directory containing the gem
      gem_directory: .          # parent directory (default: '.')
      next_version: patch
    secrets:
      rubygems-api-key: ${{ secrets.METANORMA_CI_RUBYGEMS_API_KEY }}
      pat_token: ${{ secrets.METANORMA_CI_PAT_TOKEN }}
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `gem_name` | yes | — | Directory name of the gem relative to `gem_directory`. Use `.` for the root gem. |
| `gem_directory` | no | `.` | Parent directory containing gem directories |
| `next_version` | yes | — | Version bump type or `skip` |
| `gated` | no | `true` | Defer publish until tests pass |
| `release_command` | no | `gem build *.gemspec && gem push *.gem` | Build and publish command (API key path only) |
| `version_file` | no | — | Path to version file (relative to gem dir) when non-standard; bypass with empty for `lib/<gem>/version.rb` |
| `bundler_cache` | no | `true` | Run `bundle install` |
| `post_install` | no | `''` | Command to run after `bundle install` |
| `submodules` | no | `true` | Checkout submodules |
| `role_to_assume` | no | — | OIDC Role ID for RubyGems Trusted Publishing (auto-discovered if omitted) |
| `environment` | no | `''` | GitHub environment name |

See [rubygems-release.md](rubygems-release.md) for details on `gated`, authentication, and behavior.
