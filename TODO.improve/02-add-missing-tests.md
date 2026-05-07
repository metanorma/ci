# Fix #2: Missing test coverage for new setup actions

## Problem
`ci-test.yml` tests graphviz, inkscape, libreoffice, ghostscript, xml2rfc — but NOT:
- `exiftool-setup-action`
- `ffmpeg-setup-action`
- `imagemagick-setup-action`

## Fix
Add `test-exiftool-action`, `test-ffmpeg-action`, `test-imagemagick-action` jobs in `ci-test.yml`
covering at least ubuntu-latest, with a verification command.

## Status
- [x] Done
