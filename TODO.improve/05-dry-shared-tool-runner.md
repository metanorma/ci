# Fix #5/6: DRY — os_release() duplicated in 5 actions, identical action structure

## Problem
1. `os_release()` function (~15 lines) copy-pasted in exiftool, ffmpeg, ghostscript, imagemagick, inkscape.
2. All setup actions have identical platform-detect + command-run boilerplate, differing only in the `cmds` dict.

## Fix
1. Create `_shared/tool_runner.py` with `os_release()`, `get_platform_name()`, `run_commands()`.
2. Each action imports from shared module via `GITHUB_ACTION_PATH`.
3. Use `subprocess.run(cmd, shell=True)` instead of `os.system()` for better error handling.

## Status
- [x] Done
