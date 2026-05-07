# Fix #12: Tool-specific rake workflows still reference individual setup actions

## Problem
These workflows bypass the unified `tool-setup-action` dispatcher:
- `graphviz-rake.yml` → `graphviz-setup-action`
- `xml2rfc-rake.yml` → `xml2rfc-setup-action`
- `libreoffice-rake.yml` → `libreoffice-setup-action`
- `inkscape-rake.yml` → `inkscape-setup-action` + `ghostscript-setup-action`
- `model-make.yml` → `graphviz-setup-action`
- `mn-processor-rake.yml` → `xml2rfc-setup-action` + `inkscape-setup-action`

These should use `tool-setup-action` for consistency and to benefit from the shared
module improvements. However, some of these (e.g., graphviz-rake) always install
exactly one tool and are intentionally narrow.

## Fix
Update each to use `tool-setup-action` with the appropriate `setup-tools` input.
Where a workflow always installs the same tools, hardcode the `setup-tools` value.

## Status
- [x] Done
