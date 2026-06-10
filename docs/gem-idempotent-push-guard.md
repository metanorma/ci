# gem-idempotent-push-guard-action

Composite action that checks if a gem version already exists on rubygems.org. If it does, sets `skip_push=true` in `$GITHUB_ENV` so subsequent push steps can be skipped.

## Usage

```yaml
- uses: metanorma/ci/gem-idempotent-push-guard-action@main
  with:
    gem-name: ${{ steps.gem-identity.outputs.name }}
    gem-version: ${{ steps.gem-identity.outputs.version }}

- if: env.skip_push != 'true'
  run: gem push *.gem
```

## Inputs

| Input | Required | Description |
|--------|----------|-------------|
| `gem-name` | yes | Gem name (e.g. `metanorma`) |
| `gem-version` | yes | Gem version (e.g. `1.2.3`) |

## Outputs

Sets `$GITHUB_ENV`:
- `skip_push=true` — gem version already exists on rubygems.org
- `skip_push=false` — gem version not found, safe to push

## How it works

Queries the RubyGems REST API (`/api/v1/versions/:name.json`) and checks if the version number appears in the response. Network errors cause the guard to pass (fails open) — the subsequent `gem push` will handle the error if the version already exists.
