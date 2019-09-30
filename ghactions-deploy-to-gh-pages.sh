#!/bin/bash
# shellcheck disable=SC2016
# TODO: replace this script when https://github.com/travis-ci/dpl/issues/694 is fixed
# Taken from https://raw.githubusercontent.com/w3c/permissions/master/deploy.sh
set -e # Exit with nonzero exit code if anything fails

errx() {
  # readonly __progname=$(basename ${BASH_SOURCE})
  echo -e "[ghactions-deploy-to-gh-pages.sh] $*" >&2
  exit 1
}

SOURCE_BRANCH="master"
TARGET_BRANCH="gh-pages"
GH_PAGES_SOURCE=${1:-published}

main() {

  [ -z "${GH_DEPLOY_KEY}" ] &&
    errx 'No `GH_DEPLOY_KEY` provided; it must be set.'

  # Read in the DEPLOY KEY
  eval "$(ssh-agent -s)"
  ssh-add - <<< "${GH_DEPLOY_KEY}"

  SSH_REPO=git@github.com:${GITHUB_REPOSITORY}
  DEST_DIR=$(mktemp -d)

  echo "GITHUB_RESPOSITORY: ${GITHUB_REPOSITORY}" >&2
  echo "SSH_REPO: ${SSH_REPO}" >&2

  # Clone the existing $TARGET_BRANCH for this repo into $DEST_DIR/
  # Create a new empty branch if gh-pages doesn't exist yet (should only happen on first deploy)
  git clone --depth 1 -b ${TARGET_BRANCH} ${SSH_REPO} ${DEST_DIR} || \
    git init ${DEST_DIR}

  # Adding contents within published/ to $DEST_DIR.
  cd ${GITHUB_WORKSPACE}
  cp -a ${GH_PAGES_SOURCE}/* ${DEST_DIR}/ || exit 0

  pushd ${DEST_DIR}
  git config user.name "${GITHUB_ACTOR}"
  git config user.email "${GITHUB_ACTOR}@users.noreply.github.com"

  # If there are no changes to the compiled out (e.g. this is a README update) then just bail.
  if [[ -z $(git status -s) ]]; then
    echo "No changes to the output on this push; exiting." >&2
    exit 0
  fi

  # Commit the "changes", i.e. the new version.
  # The delta will show diffs between new and old versions.
  git add .
  git status
  git commit -m "Deploy to GitHub Pages: ${GITHUB_SHA}"

  printf "\n\e[37m" >&2
  echo "git ls-files:" >&2
  git ls-files >&2
  printf "\e[0m\n" >&2

  printf "\n\e[37m" >&2
  echo "ls -a:" >&2
  ls -a >&2
  printf "\e[0m\n" >&2

  # Now that we're all set up, we can push.
  git push "$SSH_REPO" "$TARGET_BRANCH" -f || errx "Unable to push to git."
  popd
}

main $@

exit 0
