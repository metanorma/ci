#!/usr/bin/env bash

# shellcheck disable=SC2034
TOKEN=${1}
OWNER=${2:-metanorma}

GEMRC="${GEM_HOME:-${HOME}}/.gemrc"

if [ -f "${GEMRC}" ]; then
  echo "WARNING! Overwriting ${GEMRC}"
fi
cat << EOF > "${GEMRC}"
---
:backtrace: false
:bulk_threshold: 1000
:sources:
- https://x-access-token:${TOKEN}@rubygems.pkg.github.com/${OWNER}/
- https://rubygems.org/
:update_sources: true
:verbose: true
EOF
echo "${GEMRC} generated!"
