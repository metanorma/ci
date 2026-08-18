#!/usr/bin/env ruby
# frozen_string_literal: true

# audit-actions.rb
#
# Scans metanorma/ci workflows + cimas-config templates for GitHub Actions
# pins (uses: <owner>/<action>@<ver>), compares against a hand-curated
# deprecated-actions.yml list, and creates a GitHub issue per finding.
#
# Surface-only: does not auto-bump pins or open PRs.
# Idempotent: skips issue creation if an open issue with the same title
# already exists (safe to re-run quarterly).
#
# Design: metanorma/ci#377. Ronald-approved 2026-08-07.
#
# Usage:
#   ruby .github/scripts/audit-actions.rb            # real run (creates issues)
#   ruby .github/scripts/audit-actions.rb --dry-run  # local test (no writes)

require "yaml"
require "open3"
require "json"

DRY_RUN = ARGV.include?("--dry-run")

DEPRECATED_PATH = ".github/deprecated-actions.yml"
SCAN_PATHS = [
  ".github/workflows",
  "cimas-config/gh-actions",
].freeze

REPO = ENV.fetch("GITHUB_REPOSITORY", "metanorma/ci")

# Extract "uses: <owner>/<action>@<ver>" from all YAML files under SCAN_PATHS.
# Returns Array of Hash { file:, line:, action:, version: }.
def extract_pins(paths)
  findings = []
  paths.each do |root|
    next unless Dir.exist?(root)
    Dir.glob(File.join(root, "**", "*.{yml,yaml,erb}")).each do |file|
      # Force UTF-8 encoding on read — some cimas-config templates contain
      # non-ASCII bytes (comments, examples) that trip the default US-ASCII
      # regex-match on macOS. Silently skip binary-looking lines.
      raw = File.read(file, encoding: "UTF-8")
      raw.each_line.with_index do |line, i|
        line = line.chomp
        next unless line.valid_encoding?
        m = line.match(%r{^\s*uses:\s*([\w.-]+/[\w.-]+(?:/[\w.-]+)*)\s*@\s*(\S+)\s*$})
        next unless m
        action, version = m[1], m[2]
        # Skip local reusable-workflow refs (./.github/workflows/...).
        next if action.start_with?("./")
        findings << { file: file, line: i + 1, action: action, version: version }
      end
    end
  end
  findings
end

# Check pin against deprecation list. Returns nil if not deprecated,
# else the deprecation record.
def check_deprecated(pin, deprecated_list)
  deprecated_list.each do |entry|
    next unless entry["action"] == pin[:action]
    versions = Array(entry["deprecated_versions"])
    return entry if versions.include?(pin[:version])
  end
  nil
end

def existing_audit_issue_titles
  out, _err, status = Open3.capture3(
    "gh", "issue", "list",
    "--repo", REPO,
    "--state", "open",
    "--label", "actions-audit",
    "--json", "title",
    "--limit", "100",
  )
  return [] unless status.success?
  JSON.parse(out).map { |i| i["title"] }
rescue StandardError => e
  warn "[actions-audit] issue-list query failed: #{e.class}: #{e.message}"
  []
end

def create_issue(title, body)
  cmd = ["gh", "issue", "create",
         "--repo", REPO,
         "--title", title,
         "--body", body,
         "--label", "actions-audit"]
  system(*cmd)
end

# --- main ---

unless File.exist?(DEPRECATED_PATH)
  warn "[actions-audit] no deprecation list at #{DEPRECATED_PATH}; nothing to compare"
  exit 0
end

deprecated_list = YAML.load_file(DEPRECATED_PATH) || []
if deprecated_list.empty?
  warn "[actions-audit] deprecation list is empty; nothing to check"
  exit 0
end

pins = extract_pins(SCAN_PATHS)
puts "[actions-audit] scanned #{pins.count} action pins across #{SCAN_PATHS.join(', ')}"

findings = pins.filter_map do |pin|
  record = check_deprecated(pin, deprecated_list)
  next unless record
  pin.merge(deprecation: record)
end

if findings.empty?
  puts "[actions-audit] no deprecated pins found."
  exit 0
end

puts "[actions-audit] #{findings.count} deprecated-pin instance(s) found."

# Group by (action, version) for issue-per-class shape.
by_class = findings.group_by { |f| [f[:action], f[:version]] }

existing = DRY_RUN ? [] : existing_audit_issue_titles

by_class.each do |(action, version), instances|
  title = "[actions-audit] Deprecated pin: #{action}@#{version} in #{instances.size} file(s)"
  if existing.include?(title)
    puts "[actions-audit] skipping existing open issue: #{title}"
    next
  end

  dep = instances.first[:deprecation]
  body = +"## Deprecated action pin surfaced\n\n"
  body << "- **Action**: `#{action}`\n"
  body << "- **Deprecated version pinned**: `#{version}`\n"
  body << "- **Suggested current version**: `#{dep['current_version']}`\n" if dep["current_version"]
  body << "- **Notes**: #{dep['notes']}\n" if dep["notes"]
  body << "- **Reference**: #{dep['reference']}\n" if dep["reference"]
  body << "\n## Files affected (#{instances.size})\n\n"
  instances.each do |f|
    body << "- `#{f[:file]}`:#{f[:line]}\n"
  end
  body << "\n---\n\n"
  body << "Surfaced by `.github/workflows/actions-audit.yml` (metanorma/ci#377). "
  body << "Surface-only; no auto-bump. Fix: bump the pin in each file, "
  body << "verify the reusable/template still works, then close this issue.\n\n"
  body << "🤖\n"

  if DRY_RUN
    puts "[dry-run] would create issue:"
    puts "  title: #{title}"
    puts "  body preview:\n#{body.lines.first(6).join('    ')}"
  else
    puts "[actions-audit] creating issue: #{title}"
    create_issue(title, body)
  end
end
