# Fix #7: contains() substring matching is fragile

## Problem
`contains(inputs.setup-tools, 'ffmpeg')` does substring matching. If someone adds `ffmpegaux`,
`contains('ffmpegaux','ffmpeg')` = true.

## Fix
Use comma-wrapped exact matching:
```yaml
contains(format(',{0},', replace(inputs.setup-tools, ' ', '')), ',ffmpeg,')
```
This is handled as part of the `tool-setup-action` in fix #3.

## Status
- [x] Done (integrated into tool-setup-action)
