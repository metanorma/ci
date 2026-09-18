#!/usr/bin/env bash

GEMRC="${GEM_HOME:-${HOME}}/.gemrc"

if [ -f "${GEMRC}" ]; then
  echo "WARNING! Overwriting ${GEMRC}"
fi
# Do NOT register the GitHub Packages registry as a gem-level source.
# Private gems are resolved by bundler via `bundle config` / BUNDLE_* env
# (see gen-bundle-config-for-gh-packages.sh). A gem source entry here makes
# every `gem` command query the registry, and the 403 it returns aborts
# `gem update --system` during ruby/setup-ruby.
cat << EOF > "${GEMRC}"
---
:backtrace: false
:bulk_threshold: 1000
:sources:
- https://rubygems.org/
:update_sources: true
:verbose: true
EOF
echo "${GEMRC} generated!"
