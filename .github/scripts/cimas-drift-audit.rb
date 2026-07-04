#!/usr/bin/env ruby
# frozen_string_literal: true

# cimas-drift-audit.rb
#
# metanorma/ci#300 Gap 3 — drift-audit MVP.
#
# Walks cimas-config/cimas.yml, probes each repo's live state on GitHub,
# and produces a structured drift report grouped by severity. Detects
# seven failure-mode classes (per the sharpened acceptance criteria
# in metanorma/ci#300):
#
#   (a) error   — repo deleted (404)
#   (b) warning — repo archived
#   (c) error   — repo transferred out of listed org (redirected)
#   (d) error   — default-branch renamed
#   (e.1) error   — stale commented-out entry (rationale contradicted by live file)
#   (e.2) warning — silent drift from cimas-managed template (no opt-out marker)
#   (e.3) flag    — documented opt-out (valid-looking rationale)
#
# Usage (from a cimas-config/-carrying repo root, typically metanorma/ci):
#
#   ruby .github/scripts/cimas-drift-audit.rb
#
# Requires `gh` on PATH (uses `gh api` for GitHub calls); inherits
# authentication from the invoking shell. See metanorma/ci#300 for
# design rationale.

require "yaml"
require "json"
require "open3"

CIMAS_YML_PATH = "cimas-config/cimas.yml"
CIMAS_CONFIG_DIR = "cimas-config"

# ---------- Data model ----------

# One `repositories:` entry parsed from cimas.yml.
CimasEntry = Struct.new(
  :name,          # e.g. "metanorma-cli"
  :org,           # e.g. "metanorma"
  :branch,        # e.g. "main"
  :remote_url,    # e.g. "ssh://git@github.com/metanorma/metanorma-cli"
  :files_synced,  # { local_path => template_path } (uncommented file lines)
  :opt_outs,      # [OptOut]
  keyword_init: true,
)

# A commented-out file-mapping line + the rationale comment block preceding it.
# Both (e.1) stale rationale and (e.3) valid rationale sub-classes live here;
# classification happens later against live-file state.
OptOut = Struct.new(
  :local_path,          # e.g. ".rubocop.yml"
  :template_path,       # e.g. "gh-actions/master/.rubocop.yml"
  :rationale_lines,     # [String] the preceding # ... comment block, verbatim
  keyword_init: true,
)

# One drift finding.
Finding = Struct.new(
  :severity,      # :error | :warning | :flag
  :klass,         # :a | :b | :c | :d | :e1 | :e2 | :e3
  :repo_name,     # e.g. "metanorma-cli"
  :file,          # e.g. ".rubocop.yml" (nil for repo-level classes a-d)
  :detail,        # Free-form finding text
  :recommendation, # Free-form recommended action
  keyword_init: true,
)

# ---------- cimas.yml parsing ----------

# The cimas.yml file has a well-formed shape but comments (needed to detect
# opt-outs) are stripped by YAML.load. Two-pass strategy:
#
#   1. YAML.load_file for the structured `repositories:` hash.
#   2. Line-oriented raw scan to associate each repo's commented-out file
#      lines with their preceding rationale comment blocks.
#
# The raw scan is a small state machine: it tracks entry boundaries via
# indent, buffers pending comment lines, and flushes the buffer into an
# OptOut whenever the next non-blank line is a commented-out file mapping.
REPO_KEY_RE       = /^  ([a-zA-Z][a-zA-Z0-9_.-]*):\s*$/
COMMENTED_FILE_RE = %r{^      \#\s*([\w./-]+):\s*(\S.*?)\s*$}
COMMENT_LINE_RE   = /^      \#/
INDENTED_LINE_RE  = /^\s+\S/
# Coradoc-shape: narrative comment mentions a file (e.g. "rake.yml removed")
# without a following commented-out mapping. Extract the first file-shape
# token to use as the anchor local_path.
NARRATIVE_FILE_RE = %r{([\w./-]*[\w-]+\.(?:yml|rb|md|erb|rubocop\.yml)|Gemfile|Makefile|Rakefile)}

# Extract per-repo opt-outs (commented-out file mappings + rationale) via
# a raw-line scan. Detects two shapes:
#
#   - glossarist-shape: rationale block + a commented-out file-mapping line
#     "      # <path>: <template>"
#   - coradoc-shape: rationale block WITHOUT a following commented mapping,
#     where the rationale text mentions a file name (e.g. "rake.yml removed")
def scan_opt_outs(path, repos_data)
  opt_outs_by_repo = {}
  current_repo = nil
  pending_comments = []

  File.foreach(path, encoding: "UTF-8") do |raw_line|
    line = raw_line.chomp
    boundary = detect_repo_boundary(line, repos_data)
    if boundary != :no_change
      # Flush any pending narrative-shape opt-out before leaving the current repo.
      flush_narrative_opt_out(current_repo, opt_outs_by_repo, pending_comments)
      current_repo = boundary == :leave ? nil : boundary
      opt_outs_by_repo[current_repo] ||= [] if current_repo
      pending_comments = []
      next
    end

    next unless current_repo

    pending_comments = scan_opt_out_line(
      line, current_repo, opt_outs_by_repo, pending_comments
    )
  end
  flush_narrative_opt_out(current_repo, opt_outs_by_repo, pending_comments)

  opt_outs_by_repo
end

# If the pending comments describe a narrative-shape opt-out (mention a
# filename), emit an OptOut with template_path=nil. Called at repo boundaries.
def flush_narrative_opt_out(current_repo, opt_outs_by_repo, pending_comments)
  return unless current_repo && !pending_comments.empty?

  joined = pending_comments.join(" ")
  return unless (m = NARRATIVE_FILE_RE.match(joined))

  opt_outs_by_repo[current_repo] << OptOut.new(
    local_path: m[1],
    template_path: nil,
    rationale_lines: pending_comments.dup,
  )
end

# Returns :leave (dropped out of a repo), :no_change (nothing to do), or
# a repo name (entered a repo entry).
def detect_repo_boundary(line, repos_data)
  if (m = REPO_KEY_RE.match(line))
    candidate = m[1]
    return repos_data.key?(candidate) ? candidate : :leave
  end
  # A non-indented, non-blank, non-comment line means we've left the
  # `repositories:` section (or moved to a sibling top-level key).
  return :leave if !line.empty? && line !~ /^\s/ && !line.start_with?("#")

  :no_change
end

# Process one line inside a repo entry. Returns the updated
# pending_comments buffer.
def scan_opt_out_line(line, current_repo, opt_outs_by_repo, pending_comments)
  if (m = COMMENTED_FILE_RE.match(line))
    opt_outs_by_repo[current_repo] << OptOut.new(
      local_path: m[1],
      template_path: m[2],
      rationale_lines: pending_comments.dup,
    )
    []
  elsif COMMENT_LINE_RE.match?(line)
    # Buffer rationale — flushed if the next commented line is a file mapping.
    pending_comments + [line]
  elsif INDENTED_LINE_RE.match?(line)
    # A substantive non-comment line resets the buffer. If pending_comments
    # was a narrative-shape opt-out (mentioned a file), flush it before reset.
    flush_narrative_opt_out(current_repo, opt_outs_by_repo, pending_comments)
    []
  else
    # Blank line: preserve pending_comments across it.
    pending_comments
  end
end

def parse_cimas_yml(path)
  yaml = YAML.load_file(path, aliases: false)
  repos_data = yaml.fetch("repositories") { {} }
  opt_outs_by_repo = scan_opt_outs(path, repos_data)

  # Assemble the CimasEntry objects.
  repos_data.map do |name, data|
    remote = data["remote"].to_s
    org = extract_org(remote)

    files_hash = data["files"] || {}
    opt_outs = filter_false_positive_opt_outs(
      opt_outs_by_repo[name] || [], files_hash
    )

    CimasEntry.new(
      name: name,
      org: org,
      branch: data["branch"] || "main",
      remote_url: remote,
      files_synced: files_hash,
      opt_outs: opt_outs,
    )
  end
end

# Filter out false-positive narrative opt-outs where the mentioned file is
# already actively synced. Restoration comments (e.g. "was opted-out but
# restored to gated") that mention the same filename would otherwise trip
# the narrative-shape detector; they're documentation of the RESTORATION,
# not an opt-out. Glossarist-shape opt-outs are always kept (template_path
# non-nil is an authoritative signal).
def filter_false_positive_opt_outs(opt_outs, files_synced)
  synced_paths = files_synced.respond_to?(:keys) ? files_synced.keys.map(&:to_s) : []
  opt_outs.reject do |opt_out|
    next false unless opt_out.template_path.nil? # only filter narrative-shape

    synced_paths.any? { |sp| sp.include?(opt_out.local_path) }
  end
end

def extract_org(remote_url)
  # Handles both ssh://git@github.com/<org>/<repo> and
  # git@github.com:<org>/<repo>.git shapes.
  if (m = remote_url.match(%r{github\.com[/:]([^/]+)/}))
    m[1]
  else
    "metanorma"
  end
end

# ---------- Reporting helpers (shared across harnesses) ----------

def print_findings_short(name, findings)
  if findings.empty?
    puts "  #{name}: clean"
  else
    findings.each do |f|
      puts "  #{name}: [#{f.severity} #{f.klass}] #{f.detail}"
    end
  end
end

# ---------- Phase 2: per-repo API probe + URL-drift classification ----------

# Probes `gh api repos/<org>/<name>` for a single entry. Returns:
#   { status: :ok, data: <api_hash> }         — 200 with data
#   { status: :not_found }                    — 404 (class (a))
#   { status: :error, message: <string> }     — network/auth/other error
#
# The `gh api` command follows redirects transparently; class (c) detection
# happens against the returned `.full_name` field (which reflects the
# post-redirect canonical location, per the atmospheric investigation).
def probe_repo(entry)
  cmd = ["gh", "api", "repos/#{entry.org}/#{entry.name}"]
  out, err, status = Open3.capture3(*cmd)
  # `capture3` returns byte-encoded strings; force UTF-8 so `include?` and
  # `JSON.parse` don't blow up on non-ASCII repo content (e.g. Japanese
  # names in mn-samples-plateau, mn-samples-mlit).
  out = out.force_encoding("UTF-8")
  err = err.force_encoding("UTF-8")

  if status.success?
    { status: :ok, data: JSON.parse(out) }
  elsif err.include?("HTTP 404") || err.include?("Not Found")
    { status: :not_found }
  else
    { status: :error, message: err.strip[0, 200] }
  end
rescue StandardError => e
  { status: :error, message: "#{e.class}: #{e.message}" }
end

# Given a CimasEntry and the API probe result, emit findings for classes
# (a)-(d). No findings emitted means the URL-drift check is clean.
def classify_url_drift(entry, probe)
  case probe[:status]
  when :not_found then return [finding_not_found(entry)]
  when :error     then return [finding_probe_error(entry, probe[:message])]
  end

  data = probe[:data]
  [
    *check_archived(entry, data),
    *check_transferred(entry, data),
    *check_branch(entry, data),
  ]
end

def finding_not_found(entry)
  Finding.new(
    severity: :error, klass: :a, repo_name: entry.name,
    detail: "Repo `#{entry.org}/#{entry.name}` returns 404.",
    recommendation: "Remove from cimas.yml or restore the repo."
  )
end

def finding_probe_error(entry, message)
  Finding.new(
    severity: :warning, klass: :d, repo_name: entry.name,
    detail: "Probe failed for `#{entry.org}/#{entry.name}`: #{message}",
    recommendation: "Rerun the audit; check `gh` auth if persistent."
  )
end

def check_archived(entry, data)
  return [] unless data["archived"]

  [Finding.new(
    severity: :warning, klass: :b, repo_name: entry.name,
    detail: "Repo `#{entry.org}/#{entry.name}` is archived on GitHub.",
    recommendation: "Consider removing from cimas.yml — archived repos " \
                    "still accept pushes but CI runs there are useless."
  )]
end

def check_transferred(entry, data)
  expected = "#{entry.org}/#{entry.name}"
  actual = data["full_name"]
  return [] if actual.nil? || actual == expected

  actual_org, actual_name = actual.split("/", 2)
  same_org = actual_org == entry.org

  # Split class (c) into two severity bands:
  #   same-org rename  → warning (update cimas.yml name, but not urgent)
  #   cross-org transfer → error   (out of scope of the listed org)
  if same_org
    [Finding.new(
      severity: :warning, klass: :c, repo_name: entry.name,
      detail: "Repo renamed within `#{entry.org}`: " \
              "`#{expected}` → `#{actual}`.",
      recommendation: "Update cimas.yml `#{entry.name}:` key and " \
                      "`remote:` URL to `#{actual_name}`."
    )]
  else
    [Finding.new(
      severity: :error, klass: :c, repo_name: entry.name,
      detail: "Repo `#{expected}` transferred to a DIFFERENT org: " \
              "`#{actual}` (cimas.yml following pre-transfer redirect).",
      recommendation: "Remove from cimas.yml (repo now outside " \
                      "`#{entry.org}` scope), or update `remote:` if " \
                      "you're deliberately tracking cross-org."
    )]
  end
end

def check_branch(entry, data)
  expected = entry.branch
  actual = data["default_branch"]
  return [] if actual.nil? || actual == expected

  slug = "#{entry.org}/#{entry.name}"
  [Finding.new(
    severity: :error, klass: :d, repo_name: entry.name,
    detail: "cimas.yml `branch: #{expected}` no longer matches " \
            "the GitHub default branch `#{actual}` for `#{slug}`.",
    recommendation: "Update cimas.yml `branch:` to `#{actual}`."
  )]
end

# ---------- Phase 3: opt-out classification (e.2 silent drift, e.3 documented) ----------

# Fetches the live file at `origin/<branch>:<local_path>` from GitHub via
# `gh api`. Returns the decoded content string, or nil if the file doesn't
# exist / can't be fetched.
def probe_file(entry, local_path)
  cmd = ["gh", "api",
         "repos/#{entry.org}/#{entry.name}/contents/#{local_path}",
         "--jq", ".content"]
  out, _err, status = Open3.capture3(*cmd)
  return nil unless status.success? && !out.strip.empty?

  require "base64"
  Base64.decode64(out).force_encoding("UTF-8")
rescue StandardError
  nil
end

# Reads a template file from the local ci checkout's cimas-config directory.
# Returns the raw content string, or nil if the template doesn't exist.
def read_template(template_path)
  full = File.join(CIMAS_CONFIG_DIR, template_path)
  return nil unless File.exist?(full)

  File.read(full, encoding: "UTF-8")
rescue StandardError
  nil
end

# For (e.2): compare live file content vs template. Returns a Finding if
# they differ meaningfully. Auto-generated Cimas banner comments are
# normalized before comparison since the cimas sync process may or may
# not preserve them across cycles.
def classify_file_drift(entry, local_path, template_path)
  live_content = probe_file(entry, local_path)
  template_content = read_template(template_path)

  return [] if live_content.nil? || template_content.nil?

  return [] if normalize_for_compare(live_content) ==
               normalize_for_compare(template_content)

  [Finding.new(
    severity: :warning, klass: :e2, repo_name: entry.name,
    file: local_path,
    detail: "`#{local_path}` on `#{entry.org}/#{entry.name}` differs " \
            "from cimas-config template `#{template_path}` — " \
            "silent drift from the syncable template.",
    recommendation: "Rerun `cimas sync` to restore the template, " \
                    "or document the divergence as an opt-out in cimas.yml."
  )]
end

# Strips whitespace-only differences + trailing whitespace + the
# "Auto-generated by Cimas: Do not edit it manually!" banner (which
# is added by cimas sync, so the template file itself won't have it).
CIMAS_BANNER_RE = /\A(?:#[^\n]*\n){0,3}/

def normalize_for_compare(content)
  # Drop leading comment-only lines (Cimas banner), collapse trailing whitespace.
  without_banner = content.sub(CIMAS_BANNER_RE, "")
  without_banner.gsub(/[ \t]+$/, "").strip
end

# For each documented opt-out, decide between (e.1) stale-rationale
# (the rationale claims opt-out but the live file matches the referenced
# template — so the opt-out is contradicted by live state) and (e.3)
# documented opt-out (live file differs from template — the opt-out is
# real, flagged for maintainer affirmation).
#
# Narrative-shape opt-outs (template_path == nil) always surface as (e.3)
# because we have no template to compare against — no way to falsify
# their rationale from live state alone.
def classify_opt_outs(entry)
  entry.opt_outs.map do |opt_out|
    rationale = format_rationale(opt_out.rationale_lines)
    stale = stale_opt_out?(entry, opt_out)

    if stale
      finding_e1(entry, opt_out, rationale)
    else
      finding_e3(entry, opt_out, rationale)
    end
  end
end

def format_rationale(rationale_lines)
  rationale_lines.map { |l| l.strip.sub(/\A#\s?/, "") }
                 .reject(&:empty?)
                 .join(" ")
end

# Returns true when the opt-out's rationale is contradicted by live state
# — i.e. the live file at local_path matches the referenced template.
# Only fires for glossarist-shape (template_path present); narrative-shape
# opt-outs are treated as unverifiable → not stale.
def stale_opt_out?(entry, opt_out)
  return false if opt_out.template_path.nil?

  live_content = probe_file(entry, opt_out.local_path)
  template_content = read_template(opt_out.template_path)
  return false if live_content.nil? || template_content.nil?

  normalize_for_compare(live_content) == normalize_for_compare(template_content)
end

def finding_e1(entry, opt_out, rationale)
  Finding.new(
    severity: :error, klass: :e1, repo_name: entry.name,
    file: opt_out.local_path,
    detail: "Stale opt-out: `#{opt_out.local_path}` claims opt-out from " \
            "`#{opt_out.template_path}` but the live file on " \
            "`#{entry.org}/#{entry.name}` currently MATCHES the template. " \
            "Rationale is contradicted by live state. " \
            "Rationale: #{rationale.empty? ? '(none inline)' : rationale}",
    recommendation: "Restore the sync line (remove the # from the file " \
                    "mapping in cimas.yml) and delete the rationale block."
  )
end

def finding_e3(entry, opt_out, rationale)
  template_hint = opt_out.template_path ? "would template from `#{opt_out.template_path}`" : "narrative-shape (no template reference)"
  Finding.new(
    severity: :flag, klass: :e3, repo_name: entry.name,
    file: opt_out.local_path,
    detail: "Documented opt-out from cimas sync of `#{opt_out.local_path}` " \
            "(#{template_hint}). " \
            "Rationale: #{rationale.empty? ? '(none inline)' : rationale}",
    recommendation: "Affirm this cycle if still valid; " \
                    "otherwise resolve by restoring sync or expanding " \
                    "the rationale."
  )
end

# ---------- Phase 3 harness ----------

if ENV["PHASE_3_OPTOUT_ONLY"] == "1"
  entries = parse_cimas_yml(CIMAS_YML_PATH)
  limit = (ENV["LIMIT"] || entries.size).to_i
  target = entries.first(limit)
  puts "phase-3 opt-out + drift audit on #{target.size} of #{entries.size}..."
  target.each do |entry|
    findings = []
    entry.files_synced.each do |local_path, template_path|
      findings.concat(classify_file_drift(entry, local_path, template_path))
    end
    findings.concat(classify_opt_outs(entry))
    print_findings_short(entry.name, findings)
  end
  exit 0
end

# ---------- Phase 4: full audit + markdown report ----------

SEVERITY_ORDER = %i[error warning flag].freeze

CLASS_HEADINGS = {
  a: "(a) Repo deleted",
  b: "(b) Repo archived",
  c: "(c) Repo transferred / renamed",
  d: "(d) Default branch drift",
  e1: "(e.1) Stale commented-out opt-out (deferred to phase 4+)",
  e2: "(e.2) Silent drift from cimas-managed template",
  e3: "(e.3) Documented opt-out (flag for maintainer affirmation)",
}.freeze

def audit_entry(entry)
  probe = probe_repo(entry)
  findings = classify_url_drift(entry, probe)
  # File-level checks skipped for entries whose repo probe failed / redirected —
  # they'd chase 404s on live files. URL-drift is the actionable class first.
  return findings unless probe[:status] == :ok

  entry.files_synced.each do |local_path, template_path|
    findings.concat(classify_file_drift(entry, local_path, template_path))
  end
  findings.concat(classify_opt_outs(entry))
  findings
end

def emit_markdown_report(all_findings)
  by_severity = all_findings.group_by(&:severity)
  lines = report_header(by_severity)
  SEVERITY_ORDER.each do |sev|
    findings = by_severity[sev] || []
    lines.concat(emit_severity_section(sev, findings)) unless findings.empty?
  end
  lines.join("\n")
end

def report_header(by_severity)
  [
    "# cimas-config drift audit report",
    "",
    "Generated by `.github/scripts/cimas-drift-audit.rb`. " \
      "See metanorma/ci#300 for spec.",
    "",
    "**Totals**: " \
      "#{by_severity[:error]&.size || 0} errors, " \
      "#{by_severity[:warning]&.size || 0} warnings, " \
      "#{by_severity[:flag]&.size || 0} flags.",
    "",
  ]
end

def emit_severity_section(sev, findings)
  lines = ["## #{sev.to_s.capitalize} findings (#{findings.size})", ""]
  findings.group_by(&:klass).each do |klass, group|
    lines << "### #{CLASS_HEADINGS[klass] || klass}"
    lines << ""
    group.each { |f| lines.concat(emit_finding_lines(f)) }
    lines << ""
  end
  lines
end

def emit_finding_lines(finding)
  anchor = finding.file ? "`#{finding.repo_name}:#{finding.file}`" : "`#{finding.repo_name}`"
  [
    "- **#{anchor}** — #{finding.detail}",
    "  - _Recommendation_: #{finding.recommendation}",
  ]
end

if ENV["PHASE_4_FULL_REPORT"] == "1"
  entries = parse_cimas_yml(CIMAS_YML_PATH)
  limit = (ENV["LIMIT"] || entries.size).to_i
  target = entries.first(limit)
  $stderr.puts "auditing #{target.size} of #{entries.size} entries..."
  all_findings = []
  target.each_with_index do |entry, idx|
    $stderr.print "\r  [#{idx + 1}/#{target.size}] #{entry.name.ljust(40)}"
    all_findings.concat(audit_entry(entry))
  end
  $stderr.puts "\ndone. #{all_findings.size} findings across #{target.size} entries."
  puts emit_markdown_report(all_findings)
  exit 0
end

# ---------- Phase 1 harness: parse + print ----------
# Phase 1 target is the parser. Phases 2-4 (probe, classify, report) add
# the actual audit. This harness lets me verify parser correctness before
# wiring up API calls.


if ENV["PHASE_2_URL_DRIFT_ONLY"] == "1"
  entries = parse_cimas_yml(CIMAS_YML_PATH)
  limit = (ENV["LIMIT"] || entries.size).to_i
  target = entries.first(limit)
  puts "probing #{target.size} of #{entries.size} entries..."
  target.each do |entry|
    probe = probe_repo(entry)
    findings = classify_url_drift(entry, probe)
    print_findings_short(entry.name, findings)
  end
  exit 0
end

if ENV["PHASE_1_PARSER_ONLY"] == "1"
  entries = parse_cimas_yml(CIMAS_YML_PATH)
  puts "parsed #{entries.size} entries from #{CIMAS_YML_PATH}"

  # Spot-check a few known-shape entries.
  spot_check = %w[metanorma-cli coradoc metanorma-plugin-glossarist
                  metanorma-standoc isodoc]
  spot_check.each do |name|
    entry = entries.find { |e| e.name == name }
    unless entry
      puts "  [MISS] #{name} not in parsed entries"
      next
    end

    puts "  [OK] #{entry.name} " \
         "org=#{entry.org} branch=#{entry.branch} " \
         "files_synced=#{entry.files_synced.size} " \
         "opt_outs=#{entry.opt_outs.size}"
    entry.opt_outs.each do |oo|
      rationale_first = oo.rationale_lines.first
      rationale_hint = rationale_first ? rationale_first.strip[0, 60] : "(no rationale)"
      puts "        opt-out: #{oo.local_path} → #{oo.template_path}"
      puts "        rationale-hint: #{rationale_hint}"
    end
  end

  exit 0
end

# Placeholder for phases 2-4 (probe, classify, report).
puts "cimas-drift-audit: phases 2-4 not yet wired. Set PHASE_1_PARSER_ONLY=1 to run the parser harness."
