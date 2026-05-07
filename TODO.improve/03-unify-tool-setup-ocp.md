# Fix #3/4: Open/Closed Principle — tool setup blocks copy-pasted across 3 workflows

## Problem
The identical `if: contains(inputs.setup-tools, '<tool>')` + `uses: metanorma/ci/<tool>-setup-action@main`
block is repeated verbatim in:
- `generic-rake.yml` (5 tools: inkscape, ghostscript, graphviz, libreoffice, xml2rfc)
- `dependent-rake.yml` (8 tools: above + exiftool, ffmpeg, imagemagick)
- `monorepo-rake.yml` (5 tools)

Adding a new tool requires editing every workflow. Also, tool lists are inconsistent.

## Fix
1. Create `tool-setup-action/action.yml` — a single composite action that takes `setup-tools` as input
   and dispatches to all individual setup actions.
2. Use `contains(format(',{0},', replace(inputs.setup-tools, ' ', '')), ',inkscape,')` for exact
   comma-separated matching (fixes substring collision risk too).
3. Update all 3 workflows to use `./tool-setup-action` (local) or `metanorma/ci/tool-setup-action@main` (remote).
4. All 3 workflows get the same `setup-tools` description string.

## Status
- [x] Done
