#!/usr/bin/env ruby
# frozen_string_literal: true

# release-version-advisory.rb
#
# Advisory-only change detector for release-version selection.
# Per the design brief at https://github.com/metanorma/ci/issues/369.
#
# Runs in rubygems-release.yml's preflight job when `version_advisory=true`.
# Emits a markdown table to $GITHUB_STEP_SUMMARY and a ::notice:: line with the
# overall suggested bump. Never blocks — exit 0 always, even on unexpected
# exceptions (rescue clause in `run`).
#
# ---
#
# Design principles satisfied (per ci#369 acceptance criteria):
#
# P1 Advisory only. No exit non-zero. No override input. No acknowledge
#    checkbox. Rescue clause in `run` guarantees P1 even on unexpected error.
# P2 Opt-in via `version_advisory` input, default `false`. Wiring lives on the
#    caller side (rubygems-release.yml); this script is invoked only when the
#    input is true.
# P3 Preflight placement — wiring in caller. This script is fast + deterministic
#    per P6.
# P4 Public vs internal classification with per-row evidence. Composite of
#    ordered signals: annotations → contract file → namespace convention →
#    directory convention → UNKNOWN default.
# P5 Wrapper-friendly. Output only via $GITHUB_STEP_SUMMARY + ::notice:: on
#    stderr. No new inputs beyond `version_advisory` on the reusable.
# P6 Cheap and deterministic. Prism parse (Ruby 3.3+ stdlib). Git-only diff.
#    No rubygems.org calls. No network. No side effects on the working tree.
#
# ---
#
# Known limitations (Phase 2 candidates, not blockers for Phase 1):
#
# - `class << self` blocks: methods defined inside are not distinguished from
#   instance methods in the emitted namespace path. Symbol collisions between
#   `def self.foo` and `def foo` are indistinguishable in the current output.
# - `attr_accessor` / `attr_reader` / `attr_writer`: these define public
#   getter/setter methods but are not extracted. Rename / addition / removal
#   of accessors is invisible to this advisory.
# - Inheritance changes (superclass swap) and include/extend changes: not
#   detected as breaking. Undetectable behavior consequences of these changes
#   are outside the AST-diff scope.
# - Method redefinition via `define_method` / `class_eval` / `module_eval`:
#   invisible to AST parse. Metaprogrammed API is not covered.

require "prism"
require "open3"
require "json"
require "digest"

module VersionAdvisory
  # ---------- Public API surface discovery (multi-signal composite) ----------
  # Ordered signals, first-match-wins per symbol. Default = UNKNOWN.

  module ApiSurface
    ANNOTATION_PUBLIC = /^\s*#\s*@api\s+public\b/
    ANNOTATION_PRIVATE = /^\s*#\s*@api\s+private\b/
    YARD_METHOD_TAG = /^\s*#\s*@!method\b/
    NODOC = /^\s*#\s*:nodoc:/

    INTERNAL_MODULE_NAMES = %w[Internal Private].freeze
    INTERNAL_DIR_SEGMENTS = %w[internal private].freeze

    # Returns :public | :internal | :unknown + evidence string
    def self.classify(symbol_info)
      # symbol_info: { name:, file:, line:, comment_block: (array of preceding
      # comment lines), namespace_path: (e.g., "Foo::Internal::Bar") }

      # Signal 1: explicit annotations on the symbol
      if symbol_info[:comment_block].any? { |c| c =~ ANNOTATION_PUBLIC }
        return [:public, "annotation `# @api public` at #{symbol_info[:file]}:#{symbol_info[:line]}"]
      end
      if symbol_info[:comment_block].any? { |c| c =~ ANNOTATION_PRIVATE }
        return [:internal, "annotation `# @api private` at #{symbol_info[:file]}:#{symbol_info[:line]}"]
      end
      if symbol_info[:comment_block].any? { |c| c =~ NODOC }
        return [:internal, "`:nodoc:` at #{symbol_info[:file]}:#{symbol_info[:line]}"]
      end
      if symbol_info[:comment_block].any? { |c| c =~ YARD_METHOD_TAG }
        # Yard @!method marks documented (public) surface
        return [:public, "Yard `# @!method` at #{symbol_info[:file]}:#{symbol_info[:line]}"]
      end

      # Signal 2: contract file (public_api.txt allowlist, use-only-if-present)
      contract = load_contract_file
      if contract && !contract.empty?
        fqn = symbol_info[:namespace_path]
        return [:public, "listed in public_api.txt"] if contract.include?(fqn)

        return [:internal, "not listed in public_api.txt"]
      end

      # Signal 3: namespace convention (Internal::, Private::, leading _)
      if symbol_info[:namespace_path] && INTERNAL_MODULE_NAMES.any? { |m| symbol_info[:namespace_path].include?("::#{m}::") || symbol_info[:namespace_path].start_with?("#{m}::") }
        return [:internal, "in `Internal`/`Private` namespace (#{symbol_info[:namespace_path]})"]
      end
      if symbol_info[:name].start_with?("_")
        return [:internal, "leading-underscore name (#{symbol_info[:name]})"]
      end

      # Signal 4: directory convention (lib/*/internal/, lib/*/private/)
      if INTERNAL_DIR_SEGMENTS.any? { |seg| symbol_info[:file].include?("/#{seg}/") }
        return [:internal, "under lib/*/{internal,private}/ path (#{symbol_info[:file]})"]
      end

      # Signal 5: default UNKNOWN
      [:unknown, "no api-surface signal found; consider marking with `# @api`"]
    end

    def self.load_contract_file
      return @contract if defined?(@contract)

      path = "public_api.txt"
      @contract = File.exist?(path) ? File.readlines(path, chomp: true).reject { |l| l.empty? || l.start_with?("#") } : nil
    end

    # For test isolation
    def self.reset_contract_cache!
      remove_instance_variable(:@contract) if defined?(@contract)
    end
  end

  # ---------- Diff range discovery ----------

  module DiffRange
    # Returns [prev_tag_sha, head_sha, prev_tag_ref] or [nil, head_sha, nil] if
    # no prior tag / discovery fails. All values stripped of trailing whitespace.
    def self.discover
      head_sha, head_status = run_git("rev-parse", "HEAD", allow_failure: true)
      return [nil, nil, nil] unless head_status.success?

      head_sha = head_sha.strip

      prev_tag, tag_status = run_git("describe", "--tags", "--abbrev=0", allow_failure: true)
      return [nil, head_sha, nil] unless tag_status.success?

      prev_tag = prev_tag.strip
      return [nil, head_sha, nil] if prev_tag.empty?

      prev_sha, sha_status = run_git("rev-parse", "#{prev_tag}^{commit}", allow_failure: true)
      return [nil, head_sha, nil] unless sha_status.success?

      [prev_sha.strip, head_sha, prev_tag]
    end

    def self.changed_lib_files(prev_sha, head_sha)
      return [] unless prev_sha && head_sha

      out, status = run_git("diff", "--name-only", "#{prev_sha}...#{head_sha}", "--", "lib/", allow_failure: true)
      return [] unless status.success?

      out.strip.split("\n").reject(&:empty?)
    end

    def self.file_at_sha(sha, path)
      out, status = run_git("show", "#{sha}:#{path}", allow_failure: true)
      status.success? ? out : nil
    end

    def self.run_git(*args, allow_failure: false)
      out, err, status = Open3.capture3("git", *args)
      if !status.success? && !allow_failure
        warn "git #{args.join(' ')} failed: #{err}"
        # Per P1 (advisory-only), never exit non-zero. Return a failed-status
        # tuple; caller decides how to handle.
      end
      [out, status]
    end
  end

  # ---------- Symbol extraction (Prism-based) ----------
  #
  # Extracts named methods, constants, classes, modules with:
  # - name (unqualified)
  # - namespace_path (e.g., "Foo::Bar")
  # - file, line
  # - comment_block (preceding comment lines, for annotation reading)
  # - signature (for methods — arg names/kinds/defaults, so we can detect
  #   signature changes even when name is the same)

  module Extractor
    Symbol = Struct.new(:kind, :name, :namespace_path, :file, :line, :comment_block, :signature, :body_fingerprint, keyword_init: true)

    def self.extract(source, file_path)
      return [] if source.nil? || source.empty?

      parse_result = Prism.parse(source)
      return [] if parse_result.failure?

      symbols = []
      visitor = Visitor.new(file_path, source, symbols)
      visitor.visit(parse_result.value)
      symbols
    end

    class Visitor
      def initialize(file_path, source, out)
        @file_path = file_path
        @source_lines = source.split("\n")
        @out = out
        @namespace_stack = []
      end

      def visit(node)
        return unless node
        method = "visit_#{node.class.name.split("::").last.gsub(/Node$/, '').gsub(/(?<!^)([A-Z])/, '_\1').downcase}"
        if respond_to?(method, true)
          send(method, node)
        else
          visit_children(node)
        end
      end

      def visit_children(node)
        node.compact_child_nodes.each { |c| visit(c) }
      end

      def visit_class(node)
        name = node_name(node.constant_path)
        @namespace_stack.push(name)
        emit(:class, name, node)
        visit_children(node)
        @namespace_stack.pop
      end

      def visit_module(node)
        name = node_name(node.constant_path)
        @namespace_stack.push(name)
        emit(:module, name, node)
        visit_children(node)
        @namespace_stack.pop
      end

      def visit_def(node)
        name = node.name.to_s
        sig = method_signature(node)
        fp = body_fingerprint(node)
        emit(:method, name, node, signature: sig, body_fingerprint: fp)
        # Do not descend into method bodies
      end

      def visit_constant_write(node)
        emit(:constant, node.name.to_s, node)
      end

      def emit(kind, name, node, signature: nil, body_fingerprint: nil)
        line = node.location.start_line
        namespace_path = (@namespace_stack + [name]).join("::")
        @out << Symbol.new(
          kind: kind,
          name: name,
          namespace_path: namespace_path,
          file: @file_path,
          line: line,
          comment_block: preceding_comment_block(line),
          signature: signature,
          body_fingerprint: body_fingerprint,
        )
      end

      # Fingerprint the def's source (whitespace-normalised) so that two methods
      # with identical signatures but different bodies produce distinct
      # fingerprints. Whitespace + comment lines are ignored so cosmetic
      # reformatting or added doc-comments do NOT count as body changes.
      def body_fingerprint(def_node)
        loc = def_node.location
        start_line = loc.start_line
        end_line = loc.end_line
        source_lines = (start_line..end_line).map { |ln| @source_lines[ln - 1] || "" }
        normalised = source_lines
                     .map { |l| l.sub(/#.*$/, "").rstrip } # strip trailing comments
                     .reject { |l| l.strip.empty? }        # drop blank lines
                     .join("\n")
        Digest::SHA1.hexdigest(normalised)
      end

      def preceding_comment_block(target_line)
        block = []
        i = target_line - 2 # zero-index; the line above target
        while i >= 0
          l = @source_lines[i]
          break unless l&.match?(/^\s*#/)
          block.unshift(l)
          i -= 1
        end
        block
      end

      def method_signature(def_node)
        return {} unless def_node.parameters
        params = def_node.parameters
        {
          required: (params.requireds || []).map { |p| param_name(p) },
          optional: (params.optionals || []).map { |p| param_name(p) },
          rest: params.rest ? param_name(params.rest) : nil,
          keywords: (params.keywords || []).map { |p| param_name(p) },
          keyword_rest: params.keyword_rest ? param_name(params.keyword_rest) : nil,
          block: params.block ? param_name(params.block) : nil,
        }
      end

      def param_name(param_node)
        param_node.respond_to?(:name) ? param_node.name.to_s : "?"
      end

      def node_name(const_path_node)
        return "?" unless const_path_node
        # ConstantReadNode has .name; ConstantPathNode has .parent + .name
        return const_path_node.name.to_s if const_path_node.respond_to?(:name) && !const_path_node.respond_to?(:parent)

        parts = []
        current = const_path_node
        while current.respond_to?(:parent) && current.parent
          parts.unshift(current.name.to_s)
          current = current.parent
        end
        parts.unshift(current.name.to_s) if current.respond_to?(:name)
        parts.join("::")
      end
    end
  end

  # ---------- Symbol diff ----------

  module Diff
    Change = Struct.new(:kind, :symbol_before, :symbol_after, keyword_init: true)

    # kinds: :added, :removed, :signature_changed, :body_changed_maybe
    def self.compute(before_symbols, after_symbols)
      changes = []
      before_by_fqn = before_symbols.group_by { |s| [s.kind, s.namespace_path] }
      after_by_fqn = after_symbols.group_by { |s| [s.kind, s.namespace_path] }

      (before_by_fqn.keys | after_by_fqn.keys).each do |key|
        before = before_by_fqn[key]&.first
        after = after_by_fqn[key]&.first

        if before && !after
          changes << Change.new(kind: :removed, symbol_before: before, symbol_after: nil)
        elsif !before && after
          changes << Change.new(kind: :added, symbol_before: nil, symbol_after: after)
        elsif before && after && before.kind == :method
          if signature_broken?(before.signature, after.signature)
            changes << Change.new(kind: :signature_changed, symbol_before: before, symbol_after: after)
          elsif before.body_fingerprint && after.body_fingerprint &&
                before.body_fingerprint != after.body_fingerprint
            # Same signature, different body (fingerprint changed after
            # whitespace + comment normalisation). Behaviour-change potential
            # is undetectable from AST alone → flag as :body_changed_maybe.
            changes << Change.new(kind: :body_changed_maybe, symbol_before: before, symbol_after: after)
          end
        end
      end

      changes
    end

    # A "broken" signature change: removed required args, added required args,
    # reordered positional args, removed keyword arg. Adding optional keyword
    # is backward-compatible (not broken).
    def self.signature_broken?(before_sig, after_sig)
      return false unless before_sig && after_sig

      # Required positional shrunk or reordered = broken
      return true if (before_sig[:required] || []) != (after_sig[:required] || [])
      # Removed keyword arg = broken
      return true if ((before_sig[:keywords] || []) - (after_sig[:keywords] || [])).any?

      false
    end
  end

  # ---------- Bump bucketing ----------
  #
  # Classification table (per ci#369 design memo, Symbol change → suggested bump):
  # - Public API removed / signature-broken: major (or minor pre-1.0)
  # - Public API added (backward-compat): minor
  # - Internal API removed / renamed: patch
  # - Public API body changed (UNKNOWN — undetectable from AST): UNKNOWN
  # - No functional change (docs, comments, whitespace): none

  module Bucket
    Row = Struct.new(:change, :api_classification, :evidence, :suggested_bump, keyword_init: true)

    ORDER = %i[none patch minor major unknown].freeze

    def self.classify_all(changes, pre_1_0: false)
      rows = changes.map { |ch| classify_one(ch, pre_1_0: pre_1_0) }
      overall = rows.map(&:suggested_bump).max_by { |b| ORDER.index(b) || -1 } || :none
      [rows, overall]
    end

    def self.classify_one(change, pre_1_0: false)
      symbol = change.symbol_after || change.symbol_before
      api_class, evidence = ApiSurface.classify(symbol_info_for(symbol))

      bump = case [change.kind, api_class]
             when [:added, :public] then :minor
             when [:added, :internal], [:added, :unknown] then :patch
             when [:removed, :public], [:signature_changed, :public] then :major
             when [:removed, :internal], [:signature_changed, :internal] then :patch
             when [:removed, :unknown], [:signature_changed, :unknown] then :unknown
             when [:body_changed_maybe, :public], [:body_changed_maybe, :unknown] then :unknown
             when [:body_changed_maybe, :internal] then :patch
             else :none
             end

      # Pre-1.0 semver: breaking changes are conventionally minor bumps, not
      # major, until v1.0.0 stabilises the API surface (per SemVer spec §4).
      if pre_1_0 && bump == :major
        bump = :minor
        evidence = "#{evidence}; demoted major→minor per pre-1.0 SemVer convention"
      end

      Row.new(change: change, api_classification: api_class, evidence: evidence, suggested_bump: bump)
    end

    def self.symbol_info_for(symbol)
      {
        name: symbol.name,
        namespace_path: symbol.namespace_path,
        file: symbol.file,
        line: symbol.line,
        comment_block: symbol.comment_block,
      }
    end
  end

  # ---------- Output emission ----------

  module Output
    def self.emit_summary(rows, overall_bump, prev_tag, requested_bump)
      summary_path = ENV["GITHUB_STEP_SUMMARY"]
      return unless summary_path

      body = build_markdown(rows, overall_bump, prev_tag, requested_bump)
      File.open(summary_path, "a") { |f| f.write(body) }
    end

    def self.emit_notice(overall_bump, requested_bump)
      msg = if requested_bump && overall_bump != requested_bump
              "Detected changes suggest '#{overall_bump}'. You selected '#{requested_bump}'. See run summary."
            else
              "Detected changes suggest '#{overall_bump}'."
            end
      warn "::notice title=Version advisory::#{msg}"
    end

    def self.build_markdown(rows, overall_bump, prev_tag, requested_bump)
      out = String.new
      out << "\n## Version advisory\n\n"
      out << "Range: #{prev_tag || 'first release'} → HEAD\n"
      out << "Overall suggested bump: **#{overall_bump}**\n"
      out << "You selected: `#{requested_bump || 'skip/unspecified'}`.\n\n"

      if rows.empty?
        out << "_No lib/ symbol changes detected._\n"
        return out
      end

      out << "| Change | Classification | Evidence | Suggested |\n"
      out << "|---|---|---|---|\n"
      rows.each do |row|
        change = row.change
        symbol = change.symbol_after || change.symbol_before
        out << "| #{describe_change(change)} | #{row.api_classification} | #{row.evidence} | #{row.suggested_bump} |\n"
      end
      out << "\n"
      out << "_Advisory only. Maintainer selects the bump. See ci#369 for the design brief._\n"
      out
    end

    def self.describe_change(change)
      case change.kind
      when :added then "Added `#{change.symbol_after.namespace_path}`"
      when :removed then "Removed `#{change.symbol_before.namespace_path}`"
      when :signature_changed
        "Signature-changed `#{change.symbol_after.namespace_path}`"
      when :body_changed_maybe
        "Body-changed (undetectable) `#{change.symbol_after.namespace_path}`"
      end
    end
  end

  # ---------- Main orchestration ----------

  def self.run(requested_bump: ENV["ADVISORY_REQUESTED_BUMP"])
    prev_sha, head_sha, prev_tag = DiffRange.discover

    unless head_sha
      warn "::notice title=Version advisory::advisory could not resolve HEAD; skipping (advisory is non-blocking)"
      return 0
    end

    unless prev_sha
      warn "::notice title=Version advisory::first release (or no prior tag); no advisory diff available"
      return 0
    end

    changed_files = DiffRange.changed_lib_files(prev_sha, head_sha)
    if changed_files.empty?
      Output.emit_summary([], :none, prev_tag, requested_bump)
      Output.emit_notice(:none, requested_bump)
      return 0
    end

    all_before = []
    all_after = []
    changed_files.each do |path|
      before_src = DiffRange.file_at_sha(prev_sha, path)
      after_src = DiffRange.file_at_sha(head_sha, path)
      all_before.concat(Extractor.extract(before_src, path)) if before_src
      all_after.concat(Extractor.extract(after_src, path)) if after_src
    end

    changes = Diff.compute(all_before, all_after)
    pre_1_0 = pre_1_0_tag?(prev_tag)
    rows, overall_bump = Bucket.classify_all(changes, pre_1_0: pre_1_0)
    Output.emit_summary(rows, overall_bump, prev_tag, requested_bump)
    Output.emit_notice(overall_bump, requested_bump)
    0
  rescue StandardError => e
    # P1 defense-in-depth: any unexpected exception must not block the release.
    # Log the crash context to stderr for post-run inspection and return 0.
    warn "::warning title=Version advisory crashed::#{e.class}: #{e.message}"
    warn e.backtrace.first(5).join("\n")
    0
  end

  # Parse the tag as SemVer and return true if the MAJOR is 0. Accepts
  # `v0.x.y`, `0.x.y`, `v0.x.y-beta`, etc. When the tag doesn't look like
  # SemVer, default to false (treat as stable).
  def self.pre_1_0_tag?(tag)
    return false unless tag

    m = tag.to_s.match(/\Av?(\d+)\./)
    m && m[1] == "0"
  end
end

exit VersionAdvisory.run if $PROGRAM_NAME == __FILE__
