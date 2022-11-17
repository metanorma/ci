#!/usr/bin/env bash

# shellcheck disable=SC2034
TOKEN=${1}
OWNER=${2:-metanorma}

if [ -f "${HOME}/.gemrc" ]; then
  echo "WARNING! Overwriting ~/.gemrc."
fi
cat << EOF > "${HOME}/.gemrc"
---
:backtrace: false
:bulk_threshold: 1000
:sources:
- https://x-access-token:${TOKEN}@rubygems.pkg.github.com/${OWNER}/
- https://rubygems.org/
:update_sources: true
:verbose: true
EOF
echo "${HOME}/.gemrc generated!"
