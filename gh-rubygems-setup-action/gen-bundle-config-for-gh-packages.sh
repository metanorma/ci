#!/usr/bin/env bash
# shellcheck disable=SC2086

OWNER=${1:-metanorma}
TOKEN=${2}
LOCALITY_FLAG=${3:---local}

if command -v bundle &> /dev/null; then
  bundle config ${LOCALITY_FLAG} https://rubygems.pkg.github.com/${OWNER} x-access-token:${TOKEN}
  bundle config ${LOCALITY_FLAG} GITHUB__COM x-access-token:${TOKEN}
  echo "https://rubygems.pkg.github.com/${OWNER} added to bundler's config"
else
  echo "bundler not installed. so defining BUNDLE_RUBYGEMS__PKG__GITHUB__COM ..."
  echo "BUNDLE_RUBYGEMS__PKG__GITHUB__COM=x-access-token:${TOKEN}" >> $GITHUB_ENV

  BUNDLE_PATH=$([ "${LOCALITY_FLAG}" == "--global" ] && echo "${HOME}/.bundle" || echo "./.bundle");

  echo "generating ${BUNDLE_PATH}/config ..."
  if [ -f "${BUNDLE_PATH}/config" ]
  then
    echo "WARNING! Overwriting ${BUNDLE_PATH}/config"
  fi
  mkdir -p "${BUNDLE_PATH}"
  # shellcheck disable=SC2034
  OWNER_UPPER=$(echo "${OWNER}" | tr '[:lower:]' '[:upper:]')
  cat > "${BUNDLE_PATH}/config" << 'EOF'
---
BUNDLE_HTTPS://RUBYGEMS__PKG__GITHUB__COM/${OWNER_UPPER}/: "x-access-token:${TOKEN}"
BUNDLE_RUBYGEMS__PKG__GITHUB__COM: "x-access-token:${TOKEN}"
BUNDLE_GITHUB__COM: "x-access-token:${TOKEN}"
EOF
fi
