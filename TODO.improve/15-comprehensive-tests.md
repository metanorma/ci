# Fix #15: Add comprehensive tests for the new architecture

## Problem
The new `_shared/tool_runner.py` + `tool-setup-action` architecture needs thorough
test coverage beyond just "does the tool install." Missing tests:

1. `_shared/tool_runner.py` — no unit test for `get_platform_name()` / `run_commands()`
2. `tool-setup-action` edge cases:
   - Empty `setup-tools` (should be a no-op)
   - `setup-inkscape: true` legacy flag
   - Spaces in `setup-tools` (e.g., `'graphviz, exiftool'`)
   - Single tool vs multi-tool
3. All new actions (`exiftool`, `ffmpeg`, `imagemagick`) on all 3 OSes (already added)

## Fix
Add test jobs to `ci-test.yml` covering all the above scenarios.

## Status
- [x] Done
