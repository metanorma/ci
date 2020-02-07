#!/bin/sh -f

# Trigger GitHub Actions workflow.
# The trigger-gh-actions.sh script provides a programmatic
# way to trigger a new run.

# Usage:
#   trigger-gh-actions.sh GITHUBID GITHUBPROJECT GITHUB_USERNAME GITHUB_ACCESS_TOKEN [EVENT_TYPE]
# For example:
#   trigger-gh-actions.sh metanorma metanorma-cli CAMOBAP795 xxxxx build_master
#
# where GITHUB_ACCESS_TOKEN is personal access token that you created (it needs repo level access).

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
  if [ "$1" = "--help" ] ; then
    echo "Example:"
  else
    echo "Wrong number of arguments $# to trigger-gh-actions.sh; run like:"
  fi
  echo " trigger-gh-actions.sh GITHUBID GITHUBPROJECT GITHUB_USERNAME GITHUB_ACCESS_TOKEN" >&2
  exit 1
fi

GITHUBID=$1
REPO=$2
USER=$3
ACCESS_TOKEN=$4
EVENT_TYPE=${5:-build_application}

body="{ \"event_type\": \"${EVENT_TYPE}\" }"

curl -s -X POST \
  -u "${USER}:${ACCESS_TOKEN}" \
  -H "Accept: application/vnd.github.everest-preview+json" \
  -H "Content-Type: application/json" \
  -d "$body" \
  https://api.github.com/repos/${GITHUBID}/${REPO}/dispatches