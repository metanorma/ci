#!/usr/bin/env ruby
# frozen_string_literal: true

# release-breaking-check.rb
#
# metanorma/ci#278 — patch-release breaking-change heuristic guard.
#
# Runs three heuristics comparing the previous release tag against HEAD;
# short-circuits on the first hit. Only invoked from rubygems-release.yml
# when `github.event_name == 'workflow_dispatch'` and
# `inputs.next_version == 'patch'` and the per-run override is not set.
#
# Exit codes:
#   0 — no breaking change detected, release proceeds
#   1 — breaking change detected, release halted (writes to $GITHUB_STEP_SUMMARY)
#   2 — script error (missing tag, no gemspec, etc.); release proceeds with
#       a warning since the guard must not itself become a CI reliability
#       problem.

require "open3"
require "prism"

def sh(*cmd)
  out, status = Open3.capture2(*cmd)
  [out, status.success?]
end

def latest_release_tag
  out, ok = sh("git", "describe", "--tags", "--abbrev=0",
               "--match", "v[0-9]*", "HEAD^")
  return nil unless ok

  tag = out.strip
  tag.empty? ? nil : tag
end

def gemspec_path
  Dir.glob("*.gemspec").first
end

def gem_name
  path = gemspec_path
  return nil unless path

  File.basename(path, ".gemspec")
end

# --- Heuristic (a) — file deletion in gem-shipped paths ---
#
# Compare git tree between prev tag and HEAD, filtering to paths a
# well-formed gemspec would typically ship (lib/, exe/, bin/, sig/,
# top-level .rb/README/LICENSE). This is a proxy for
# `Gem::Specification#files` diff — evaluating a gemspec at a specific
# ref is unreliable (many gemspecs `require "./lib/.../version"` which
# breaks under git-show), so we work off the file tree. A file
# present at the previous tag under one of the shipping paths and
# absent at HEAD is a "surface deletion."
def deleted_shipping_files(prev_tag)
  out, ok = sh("git", "diff", "--name-status", "--diff-filter=D",
               "#{prev_tag}..HEAD", "--",
               "lib/", "exe/", "bin/", "sig/")
  return [] unless ok

  out.each_line.map { |line| line.split("\t", 2)[1].to_s.chomp }
    .reject(&:empty?)
end

# --- Heuristic (d) — Prism AST symbol diff ---
#
# Extract top-level defined names (module/class/def) from each Ruby file
# at prev tag AND HEAD. A name present at prev tag and absent at HEAD is
# a "symbol deletion." Uses Prism (stdlib since Ruby 3.2). Only scans
# lib/**/*.rb to avoid noise from tests/specs/fixtures.
def collect_defined_names(source)
  return [] if source.nil? || source.empty?

  parsed = Prism.parse(source)
  return [] if parsed.failure?

  names = []
  visit = lambda do |node, prefix|
    case node
    when Prism::ModuleNode, Prism::ClassNode
      full = [prefix, node.constant_path.slice].compact.join("::")
      names << full
      node.body&.child_nodes&.each { |c| visit.call(c, full) }
    when Prism::DefNode
      receiver = node.receiver ? "#{node.receiver.slice}." : "#"
      names << "#{prefix}#{receiver}#{node.name}"
    when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
      target = node.respond_to?(:target) ? node.target.slice : node.name.to_s
      names << "#{prefix}::#{target}"
    else
      node.child_nodes&.each { |c| visit.call(c, prefix) if c }
    end
  end
  parsed.value.statements.body.each { |n| visit.call(n, "") }
  names.uniq
end

def files_at_ref(ref, glob)
  out, ok = sh("git", "ls-tree", "-r", "--name-only", ref, "--", glob)
  return [] unless ok

  out.each_line.map(&:chomp).select { |f| f.end_with?(".rb") }
end

def source_at_ref(ref, path)
  out, ok = sh("git", "show", "#{ref}:#{path}")
  ok ? out : nil
end

def deleted_top_level_symbols(prev_tag)
  prev_files = files_at_ref(prev_tag, "lib/")
  head_files = files_at_ref("HEAD", "lib/")

  prev_names = prev_files.flat_map do |f|
    collect_defined_names(source_at_ref(prev_tag, f))
  end.uniq

  head_names = head_files.flat_map do |f|
    collect_defined_names(source_at_ref("HEAD", f))
  end.uniq

  # Exclude names known to be private-by-convention (leading underscore).
  removed = (prev_names - head_names).reject { |n| n.split("::").last.to_s.start_with?("_") }
  removed.sort.first(20) # cap list length in the summary
rescue StandardError => e
  warn "Prism AST diff failed: #{e.class}: #{e.message}"
  []
end

# --- Heuristic (e) — gem-compare against previously-published rubygems ---
#
# Uses gem-compare (installed at CI setup time). Advisory only —
# unlike heuristics (a) and (d), a failure here does NOT halt release
# (it's captured in the summary as informational). Rationale: this
# depends on rubygems.org being reachable and the previously-published
# gem being present in a form gem-compare can diff; a rubygems outage
# should not itself block a legitimate release.
def gem_compare_summary
  name = gem_name
  return "gem-compare skipped: no gemspec found in repo root" unless name

  out, _ok = sh("gem", "compare", "--brief", name, "prev")
  return "gem-compare returned no output for #{name}" if out.strip.empty?

  # Trim to first 40 lines to keep the step summary readable.
  lines = out.split("\n").first(40)
  lines.join("\n")
rescue StandardError => e
  "gem-compare threw #{e.class}: #{e.message}"
end

# --- Summary emission ---

def emit_summary(prev_tag, deleted_files, removed_symbols, gem_compare_notes)
  summary_path = ENV["GITHUB_STEP_SUMMARY"]
  return unless summary_path

  File.open(summary_path, "a") do |io|
    io.puts <<~MD
      ## ❌ Release halted: breaking-change heuristics tripped on a `patch` release

      Compared `#{prev_tag}` (prev tag) → HEAD.

    MD

    unless deleted_files.empty?
      io.puts "### Files deleted from gem-shipping paths"
      io.puts
      deleted_files.each { |f| io.puts "- `#{f}`" }
      io.puts
    end

    unless removed_symbols.empty?
      io.puts "### Top-level symbols present at prev tag, absent at HEAD"
      io.puts
      removed_symbols.each { |s| io.puts "- `#{s}`" }
      io.puts "_(list capped at 20)_" if removed_symbols.size == 20
      io.puts
    end

    io.puts "### gem-compare output (advisory)"
    io.puts
    io.puts "```"
    io.puts gem_compare_notes
    io.puts "```"
    io.puts

    io.puts <<~MD
      ### What to do

      A `patch` release should not remove publicly-accessible files or top-level symbols. Two recommended paths:

      1. **Rerun with `next_version: minor` (or `major`)** — appropriate when the deletion is genuine API surface removal.
      2. **Bump locally and push the tag**: `bundle exec rake release` (or `gem bump --version patch --tag --push` from your workstation). The `push: tags: v*` trigger of this same workflow publishes without the guard, putting responsibility for the bump magnitude squarely on the developer.

      **Override (use sparingly):** rerun this workflow with `acknowledge_breaking_in_patch: true`. This is recorded in the run inputs and visible in the audit trail. Use only for non-API reasons (e.g. removing an accidentally-shipped fixture).

      Guard mechanism: [metanorma/ci#278](https://github.com/metanorma/ci/issues/278).
    MD
  end
end

# --- Main ---

prev_tag = latest_release_tag
if prev_tag.nil?
  warn "release-breaking-check: no previous release tag found; " \
       "cannot compute diff. Release proceeds."
  exit 2
end

deleted_files = deleted_shipping_files(prev_tag)
removed_symbols = deleted_files.any? ? [] : deleted_top_level_symbols(prev_tag)
gem_compare_notes = gem_compare_summary

tripped = !deleted_files.empty? || !removed_symbols.empty?

if tripped
  emit_summary(prev_tag, deleted_files, removed_symbols, gem_compare_notes)
  warn "release-breaking-check: guard tripped; see step summary."
  exit 1
else
  puts "release-breaking-check: no surface deletion detected between " \
       "#{prev_tag} and HEAD. Release proceeds."
  puts "gem-compare (advisory):"
  puts gem_compare_notes
  exit 0
end
