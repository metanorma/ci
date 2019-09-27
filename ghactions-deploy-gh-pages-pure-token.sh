#!/bin/bash
# shellcheck disable=SC2016
# TODO: replace this script when https://github.com/travis-ci/dpl/issues/694 is fixed
# Taken from https://raw.githubusercontent.com/w3c/permissions/master/deploy.sh
set -e # Exit with nonzero exit code if anything fails

errx() {
  # readonly __progname=$(basename ${BASH_SOURCE})
  echo -e "[ghactions-deploy-gh-pages.sh] $*" >&2
  exit 1
}

SOURCE_BRANCH="master"
TARGET_BRANCH="gh-pages"

main() {

  [ -z "$GITHUB_TOKEN" ] && \
    errx "No GITHUB_TOKEN provided; it must be set."

  # Save some useful information
  REPO="https://${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  SHA=$(git rev-parse --verify HEAD)
  DEST_DIR=out

  # Clone the existing $TARGET_BRANCH for this repo into $DEST_DIR/
  # Create a new empty branch if gh-pages doesn't exist yet (should only happen on first deploy)
  mkdir -p "$DEST_DIR"
  pushd "$DEST_DIR"
  git init .
  git checkout -b "$TARGET_BRANCH" || errx "Unable to checkout git."

  # Adding contents within published/ to $DEST_DIR.
  cp -a ../published/* ./ || exit 0

  # Now let's go have some fun with the cloned repo
  git config user.name "${GITHUB_ACTOR}"
  git config user.email "${GITHUB_ACTOR}@users.noreply.github.com"

  # Commit the "changes", i.e. the new version.
  # The delta will show diffs between new and old versions.
  git add .
  git status
  git commit -m "Deploy to GitHub Pages: ${SHA}"

  printf "\n\e[37m"
  echo "git ls-files:"
  git ls-files
  printf "\e[0m\n"

  printf "\n\e[37m"
  echo "ls -a:"
  ls -a
  printf "\e[0m\n"

  # echo ".gitignore:"
  # cat .gitignore || true
  # echo

  # Now that we're all set up, we can push.
  echo "git push $REPO $TARGET_BRANCH -f"
  git push "$REPO" "$TARGET_BRANCH" -f || errx "Unable to push to git."
  popd
}

main "$@"

exit 0
