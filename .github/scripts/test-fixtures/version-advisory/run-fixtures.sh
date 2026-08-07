#!/usr/bin/env bash
# run-fixtures.sh — drive release-version-advisory.rb against each fixture
# directory and assert the output matches expected.md.
#
# Usage:
#   bash run-fixtures.sh                    # assert all fixtures
#   bash run-fixtures.sh <fixture>          # assert one fixture
#   bash run-fixtures.sh --generate-golden  # save current output as
#                                            expected.md for each fixture
#                                            (bootstrap; commit the result)
#
# For each fixture directory:
#   1. Create a temp git repo.
#   2. Commit before.rb as lib/foo.rb; tag as v0.1.0.
#   3. Commit after.rb as lib/foo.rb.
#   4. Run advisory; capture $GITHUB_STEP_SUMMARY + the ::notice:: line.
#   5. Concatenate as: "<notice line>\n\n<step summary>" into actual.txt.
#   6. Diff actual.txt against fixture/expected.md.
#
# Exit codes:
#   0 = all fixtures passed (or --generate-golden succeeded)
#   1 = at least one fixture failed
#   2 = usage or environment error

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
ADVISORY_SCRIPT="$SCRIPT_DIR/../../release-version-advisory.rb"
FIXTURES=(a-internal-removal b-public-addition c-public-body-change d-no-change e-public-signature-broken f-public-removal g-nodoc-removal h-public-api-txt)

MODE="assert"
FIXTURE_ARG=""

for arg in "$@"; do
  case "$arg" in
    --generate-golden) MODE="generate" ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) FIXTURE_ARG="$arg" ;;
  esac
done

if [[ ! -f "$ADVISORY_SCRIPT" ]]; then
  echo "cannot find advisory script at $ADVISORY_SCRIPT" >&2
  exit 2
fi

# Capture current output for a fixture into /tmp/actual-{name}.txt.
# Format: first line is the ::notice:: line; blank line; then step summary body.
capture_fixture_output() {
  local fixture_name="$1"
  local fixture_dir="$SCRIPT_DIR/$fixture_name"
  local actual_file="$2"

  if [[ ! -f "$fixture_dir/before.rb" || ! -f "$fixture_dir/after.rb" ]]; then
    echo "fixture $fixture_name missing before.rb or after.rb" >&2
    return 1
  fi

  local scratch summary_file stderr_file
  scratch="$(mktemp -d "/tmp/advisory-fixture-$fixture_name-XXXXXX")"
  summary_file="$(mktemp "/tmp/advisory-stepsummary-$fixture_name-XXXXXX")"
  stderr_file="$(mktemp "/tmp/advisory-stderr-$fixture_name-XXXXXX")"

  # shellcheck disable=SC2064
  trap "rm -rf '$scratch' '$summary_file' '$stderr_file'" RETURN

  (
    cd "$scratch"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    mkdir -p lib
    cp "$fixture_dir/before.rb" lib/foo.rb
    # Optional contract file (public_api.txt) — present at both tags when supplied
    if [[ -f "$fixture_dir/public_api.txt" ]]; then
      cp "$fixture_dir/public_api.txt" public_api.txt
    fi
    git add . && git commit -q -m "before"
    git tag v0.1.0
    cp "$fixture_dir/after.rb" lib/foo.rb
    git add . && git commit -q -m "after"

    GITHUB_STEP_SUMMARY="$summary_file" \
      ADVISORY_REQUESTED_BUMP="patch" \
      ruby "$ADVISORY_SCRIPT" 2> "$stderr_file"
  ) >/dev/null

  local notice_line
  notice_line="$(grep -E '::notice title=Version advisory::' "$stderr_file" | head -1)"
  {
    echo "$notice_line"
    echo
    cat "$summary_file"
  } > "$actual_file"
}

pass=0
fail=0

process_fixture() {
  local fixture_name="$1"
  local fixture_dir="$SCRIPT_DIR/$fixture_name"
  local expected_file="$fixture_dir/expected.md"
  local actual_file
  actual_file="$(mktemp "/tmp/advisory-actual-$fixture_name-XXXXXX.md")"

  if ! capture_fixture_output "$fixture_name" "$actual_file"; then
    echo "  [ERROR] $fixture_name: could not capture output"
    fail=$((fail + 1))
    rm -f "$actual_file"
    return
  fi

  if [[ "$MODE" == "generate" ]]; then
    cp "$actual_file" "$expected_file"
    echo "  [WROTE] $fixture_name/expected.md ($(wc -l < "$expected_file") lines)"
    rm -f "$actual_file"
    pass=$((pass + 1))
    return
  fi

  if [[ ! -f "$expected_file" ]]; then
    echo "  [MISSING GOLDEN] $fixture_name/expected.md"
    echo "    actual output at $actual_file"
    echo "    to bootstrap: cp $actual_file $expected_file"
    fail=$((fail + 1))
    return
  fi

  if diff -u "$expected_file" "$actual_file" >/dev/null; then
    echo "  [PASS] $fixture_name"
    pass=$((pass + 1))
    rm -f "$actual_file"
  else
    echo "  [FAIL] $fixture_name"
    diff -u "$expected_file" "$actual_file" | sed 's/^/    /'
    fail=$((fail + 1))
    rm -f "$actual_file"
  fi
}

if [[ -n "$FIXTURE_ARG" ]]; then
  echo "Running fixture: $FIXTURE_ARG (mode=$MODE)"
  process_fixture "$FIXTURE_ARG"
else
  echo "Running all fixtures (mode=$MODE)"
  for f in "${FIXTURES[@]}"; do
    process_fixture "$f"
  done
fi

echo
echo "Summary: $pass passed, $fail failed"
exit $((fail > 0 ? 1 : 0))
