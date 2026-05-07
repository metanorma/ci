# Fix #10: Ghostscript action has hardcoded Windows paths pinned to version 10.00.0

## Problem
```python
win_bin_prefix = "C:\\Program Files\\gs\\gs10.00.0\\bin"
win_lib_prefix = "C:\\Program Files\\gs\\gs10.00.0\\lib"
```
When ghostscript updates, this breaks silently. Chocolatey also pins `10.0.0.20230317`.

## Fix
After `choco install`, use `glob.glob("C:\\Program Files\\gs\\gs*\\bin")` to find the
installed version dynamically.

## Status
- [x] Done
