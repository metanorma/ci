# Fix #1: Temporary branch references (BLOCKER)

## Problem
`dependent-rake.yml:155-162` references `@setup-tools-in-dependent-rake` (the current feature branch) instead of `@main`:

```yaml
# TODO: Revert to main branch of exiftool-setup-action when merging to main branch
- uses: metanorma/ci/exiftool-setup-action@setup-tools-in-dependent-rake
- uses: metanorma/ci/ffmpeg-setup-action@setup-tools-in-dependent-rake
- uses: metanorma/ci/imagemagick-setup-action@setup-tools-in-dependent-rake
```

These will create a broken reference once merged — the branch won't exist anymore.

## Fix
Change all three to `@main` and remove the TODO comment.

## Status
- [x] Done
