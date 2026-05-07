# Fix #9: Bare except: in all os_release() functions

## Problem
All 5 setup actions have:
```python
except:
    pass
```
This swallows KeyboardInterrupt, SystemExit, MemoryError.

## Fix
Handled in `_shared/tool_runner.py` — use `except (IOError, OSError):` for file reads
and `except OSError:` for freedesktop_os_release().

## Status
- [x] Done (integrated into _shared/tool_runner.py)
