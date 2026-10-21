#!/usr/bin/env bash
#
# release-rehearsal — prove that the whole metanorma gem chain can be
# released, without releasing anything.
#
# One implementation for two runners: run it locally against a manifest,
# or let .github/workflows/release-rehearsal.yml drive it on GHA. It
# mirrors the preflight of rubygems-release.yml gem by gem (fresh bundle
# resolve, `bundle exec rake` resolves, `gem build`, version-vs-rubygems
# awareness), then proves the chain as a whole: the built gems are
# installed into an isolated GEM_HOME, every chain-internal runtime
# constraint is checked against the built set, and a bundler run pinned
# to the exact built versions must require every gem and load the
# metanorma flavor registry.
#
# Usage:
#   script/release-rehearsal.sh <manifest.json> [workdir]
#     --build-only   stop after the per-gem phase
#     --chain-only   skip the per-gem phase (expects gems/*.gem in workdir)
#
# Manifest: JSON array of {"repo": "org/name", "ref": "main"}. "ref" is
# optional and defaults to $REHEARSAL_REF (default: main).
#
# Env:
#   REHEARSAL_REF       default ref for manifest entries        (main)
#   REHEARSAL_DIR       skip the clone; rehearse this checkout

set -euo pipefail

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

MANIFEST=""
WORKDIR=""
BUILD_ONLY=0
CHAIN_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --build-only) BUILD_ONLY=1 ;;
    --chain-only) CHAIN_ONLY=1 ;;
    *) if [ -z "$MANIFEST" ]; then MANIFEST=$1; else WORKDIR=$1; fi ;;
  esac
  shift
done
if [ -z "$MANIFEST" ] && [ "$CHAIN_ONLY" = 0 ]; then usage 1; fi

REF=${REHEARSAL_REF:-main}
WORKDIR=${WORKDIR:-$PWD/.release-rehearsal}
# absolutize: the per-gem subshell cd's into each checkout, so a
# relative WORKDIR would resolve identity/log paths there and fail
mkdir -p "$WORKDIR"
WORKDIR=$(cd "$WORKDIR" && pwd)
GEMS_DIR=$WORKDIR/gems
SRC_DIR=$WORKDIR/src
LOG_DIR=$WORKDIR/logs
GEMHOME=$WORKDIR/gemhome
RESULTS=$WORKDIR/results.tsv
mkdir -p "$GEMS_DIR" "$SRC_DIR" "$LOG_DIR"

note() { printf '\n=== %s ===\n' "$*"; }
fail_list=""

record() { # record <status> <name> <detail>
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RESULTS"
  [ "$1" = FAIL ] && fail_list="$fail_list $2"
  printf '%s %s (%s)\n' "$1" "$2" "$3"
}

gem_identity() { # prints "name version" for a gemspec path
  ruby -e 'require "rubygems/specification"
    s = Gem::Specification.load(ARGV[0])
    abort "bad gemspec #{ARGV[0]}" unless s
    puts "#{s.name} #{s.version}"' "$1"
}

gem_file_identity() { # prints "name version" for a .gem path
  ruby -e 'require "rubygems/package"
    s = Gem::Package.new(ARGV[0]).spec
    puts "#{s.name} #{s.version}"' "$1"
}

# ---------------------------------------------------------------- build
build_phase() {
  : > "$RESULTS"
  while IFS= read -r entry; do
    repo=$(jq -r '.repo' <<< "$entry")
    [ "$repo" != "null" ] || continue
    entry_ref=$(jq -r '.ref // "null"' <<< "$entry")
    [ "$entry_ref" = "null" ] && entry_ref=$REF
    name=${repo#*/}

    note "$name ($repo @ $entry_ref)"

    dir=$SRC_DIR/$name
    if [ -n "${REHEARSAL_DIR:-}" ]; then
      dir=$REHEARSAL_DIR
    elif [ -d "$dir/.git" ]; then
      git -C "$dir" fetch -q origin "$entry_ref"
      git -C "$dir" checkout -q FETCH_HEAD
    else
      git clone -q --depth 1 -b "$entry_ref" "https://github.com/$repo" "$dir"
    fi

    log=$LOG_DIR/$name.log
    identity=$WORKDIR/$name.identity
    if (
      cd "$dir" &&
      rm -f Gemfile.lock &&
      bundle config set --local without test &&
      bundle install --jobs 4 --retry 3 &&
      bundle exec rake --version >/dev/null &&
      gemspec=$(ls *.gemspec | head -1) &&
      read -r gname gver <<< "$(gem_identity "$gemspec")" &&
      printf '%s %s\n' "$gname" "$gver" > "$identity" &&
      gem build "$gemspec" &&
      mv ./*.gem "$GEMS_DIR/" &&
      {
        if gem list --remote --exact --version "$gver" "$gname" 2>/dev/null | grep -qF "$gname ($gver)"; then
          echo "ℹ $gname $gver is already on rubygems.org — a release needs a version bump."
        else
          echo "ℹ $gname $gver is not on rubygems.org yet."
        fi
      }
    ) > "$log" 2>&1; then
      record PASS "$name" "$(cat "$identity")"
    else
      record FAIL "$name" "see $log (tail:)"
      tail -20 "$log" || true
    fi
  done < <(jq -c '.[]' "$MANIFEST")
}

# ---------------------------------------------------------------- chain
chain_phase() {
  note "chain phase"
  export GEM_HOME=$GEMHOME
  unset BUNDLE_GEMFILE BUNDLE_BIN_PATH RUBYOPT || true
  mkdir -p "$GEMHOME" "$WORKDIR/chain"

  if gem install --ignore-dependencies --no-document "$GEMS_DIR"/*.gem \
      > "$LOG_DIR/chain-install.log" 2>&1; then
    record PASS chain-install "$(ls "$GEMS_DIR"/*.gem | wc -l | tr -d ' ') gems installed"
  else
    record FAIL chain-install "gem install of the built set failed (see $LOG_DIR/chain-install.log)"
    tail -20 "$LOG_DIR/chain-install.log"
    return 1
  fi

  # Every chain-internal runtime dependency must be satisfiable by the
  # built set — this is the "can we cut the chain together" proof.
  cat > "$WORKDIR/chain/constraint_check.rb" <<'RUBY'
    require "rubygems/package"
    gems = Dir[File.join(ARGV[0], "*.gem")].map { |f| Gem::Package.new(f).spec }
    built = gems.to_h { |s| [s.name, s.version] }
    dupes = gems.group_by(&:name).select { |_, v| v.size > 1 }
    abort "duplicate gems built: #{dupes.keys.join(', ')}" unless dupes.empty?
    bad = []
    gems.each do |s|
      s.dependencies.select(&:runtime?).each do |d|
        next unless built[d.name]
        unless d.requirement.satisfied_by?(built[d.name])
          bad << "#{s.name} #{s.version} needs #{d.name} #{d.requirement}, built #{built[d.name]}"
        end
      end
    end
    if bad.empty?
      puts "✓ all #{gems.size} built gems' chain-internal constraints satisfied"
    else
      abort bad.map { |b| "✗ #{b}" }.join("\n")
    end
RUBY
  if ruby "$WORKDIR/chain/constraint_check.rb" "$GEMS_DIR" \
      > "$LOG_DIR/chain-constraints.log" 2>&1; then
    record PASS chain-constraints "$(tail -1 "$LOG_DIR/chain-constraints.log")"
  else
    record FAIL chain-constraints "constraint violations (see $LOG_DIR/chain-constraints.log)"
    cat "$LOG_DIR/chain-constraints.log"
    return 1
  fi

  # Bundler, pinned to the exact built versions: the chain must resolve
  # and load together, with everything non-chain pulled from rubygems.
  # Chain gems enter as path gems (unpacked artifacts): when a built
  # version equals its released number, bundler reads dependency
  # metadata from the remote index, not the local install — only a path
  # source guarantees the built gemspec is the one under test.
  (
    cd "$WORKDIR/chain"
    {
      echo 'source "https://rubygems.org"'
      for f in "$GEMS_DIR"/*.gem; do
        read -r n v <<< "$(gem_file_identity "$f")"
        gem unpack "$f" --target vendor > /dev/null
        # gem unpack does not emit the .gemspec (it is generated at
        # install time); serialize the built spec for bundler's path
        # source --ruby form is fully literal, no git needed
        gem specification "$f" --ruby > "vendor/$n-$v/$n.gemspec"
        printf 'gem "%s", path: "vendor/%s-%s"\n' "$n" "$n" "$v"
      done
    } > Gemfile
    # No --path: the bundle must see GEM_HOME, so the exact-pinned chain
    # gems resolve from the scratch install instead of rubygems.org.
    if ! bundle install --jobs 4 --retry 3 > "$LOG_DIR/chain-bundle.log" 2>&1; then
      echo "chain bundle resolve failed (see $LOG_DIR/chain-bundle.log)"
      tail -30 "$LOG_DIR/chain-bundle.log"
      exit 1
    fi
    # Full chain: the CLI's startup path — require metanorma/cli and
    # assert the flavor registry loads. Partial manifest: require every
    # built gem instead.
    if compgen -G "$GEMS_DIR/metanorma-cli-*.gem" > /dev/null; then
      # Require every built gem explicitly: the CLI's SUPPORTED_GEMS
      # list deliberately excludes flavors whose *released* gems predate
      # the current engine (m3aawg, un) — the built set here is exactly
      # what a coordinated cut would ship, so load it whole and then
      # assert the registry (metanorma-core) saw the flavors.
      smoke='require "metanorma/cli"
        require "rubygems/package"
        names = ARGV.map { |f| Gem::Package.new(f).spec.name }
        names.each do |n|
          begin
            require n
          rescue LoadError
            # the post-flavor-refactor entry convention: metanorma/document
            require n.tr("-", "/")
          end
        end
        regs = Metanorma::Registry.instance.processors
        puts "flavors: #{regs.keys.sort.join(" ")}"
        abort "no flavors registered" if regs.empty?'
      set -- "$GEMS_DIR"/*.gem
    else
      smoke='require "rubygems/package"
        names = ARGV.map { |f| Gem::Package.new(f).spec.name }
        names.each { |n| require n }
        puts "required: #{names.sort.join(" ")}"'
      set -- "$GEMS_DIR"/*.gem
    fi
    if ! bundle exec ruby -e "$smoke" "$@" \
        > "$LOG_DIR/chain-smoke.log" 2>&1; then
      echo "chain smoke failed (see $LOG_DIR/chain-smoke.log)"
      tail -30 "$LOG_DIR/chain-smoke.log"
      exit 1
    fi
    cat "$LOG_DIR/chain-smoke.log"
  ) || { record FAIL chain-smoke "see $WORKDIR/chain"; return 1; }
  record PASS chain-smoke "full chain resolves and loads under the built versions"
}

# ----------------------------------------------------------------- main
if [ "$CHAIN_ONLY" = 0 ]; then
  build_phase
  if [ -n "$fail_list" ] && [ "$BUILD_ONLY" = 0 ]; then
    echo
    echo "Build failures: $fail_list"
    echo "Fix these before the chain phase; aborting (use --build-only to iterate)."
    exit 1
  fi
fi

if [ "$BUILD_ONLY" = 0 ]; then
  chain_phase
fi

echo
echo "==== rehearsal summary ===="
if [ -f "$RESULTS" ]; then
  column -t -s $'\t' "$RESULTS" 2>/dev/null || cat "$RESULTS"
fi
[ -z "$fail_list" ]
