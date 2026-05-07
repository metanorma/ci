# Fix #13: setup-tools description strings diverge across workflows

## Problem
| Workflow | setup-tools description |
|---|---|
| generic-rake.yml | inkscape, ghostscript, graphviz, libreoffice, xml2rfc |
| dependent-rake.yml | inkscape, ghostscript, graphviz, libreoffice, xml2rfc, exiftool, ffmpeg, imagemagick |
| monorepo-rake.yml | inkscape, ghostscript, graphviz, libreoffice, xml2rfc |

## Fix
Handled by `tool-setup-action` — single source of truth for the description.
All workflows reference the same composite action.

## Status
- [x] Done (integrated into tool-setup-action)
