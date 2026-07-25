# Release workflow reference

This document previously described an 11-layer "gated-direct" relay architecture in which a `workflow_dispatch` run bumped and tagged the gem, then waited for a tag push → rake.yml → `repository_dispatch: do-release` chain to publish. That architecture was reverted in [ci#370](https://github.com/metanorma/ci/issues/370) / [PR #371](https://github.com/metanorma/ci/pull/371).

A release is now atomic: `workflow_dispatch` bumps + tags + publishes in one job. A green run means the gem is on rubygems.org. The idempotent push guard handles duplicate pushes (re-runs, stale `do-release` listeners).

For the current release workflow reference, see [`docs/rubygems-release.md`](docs/rubygems-release.md).

The old content of this file (the 11-layer per-layer failure-mode taxonomy) is preserved in git history at the commit before #371 merged, if a future postmortem needs to reference it.
