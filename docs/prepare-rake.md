# prepare-rake.yml

Reusable workflow that prepares the test environment: detects tags, foreign PRs, resolves the test matrix, and checks repository visibility.

Called internally by `generic-rake.yml`. You should not need to call this directly.

## Outputs

| Output | Description |
|--------|-------------|
| `head-tag` | The tag on HEAD, or empty if none. Set for both branch pushes (via `git tag --points-at HEAD`) and tag pushes (via `github.ref_name`). |
| `foreign-pr` | `"yes"` if this is a PR from a fork, `"no"` otherwise. |
| `matrix` | JSON string for `job.strategy.matrix` (Ruby versions × OSes). |
| `default-ruby-version` | Default Ruby version from [config.json](../.github/workflows/config.json). |
| `public` | `"true"` if the repository is public. |
