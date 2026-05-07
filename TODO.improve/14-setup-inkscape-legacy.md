# Fix #14: setup-inkscape legacy input inconsistency

## Problem
`generic-rake.yml` has `setup-inkscape: boolean` (legacy) + `setup-tools: string`.
`dependent-rake.yml` also has `setup-inkscape`.
`monorepo-rake.yml` does NOT have `setup-inkscape`.

## Fix
Handled by `tool-setup-action` which accepts both `setup-inkscape` (legacy) and `setup-tools`.
All workflows pass through `setup-inkscape` to the tool-setup-action uniformly.

## Status
- [x] Done (integrated into tool-setup-action)
