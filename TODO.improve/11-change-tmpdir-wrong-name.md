# Fix #11: change-tmpdir-action has wrong action name

## Problem
`change-tmpdir-action/action.yml:1` says `name: 'graphviz-setup-action'` — this is a
copy-paste bug from the original file creation. The name should be `'change-tmpdir-action'`.

## Fix
Change line 1 to `name: 'change-tmpdir-action'`.

## Status
- [x] Done
