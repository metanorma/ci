#!/usr/bin/env ruby
# frozen_string_literal: true

# release-version-advisory.rb
#
# Advisory-only change detector for release-version selection.
# Design brief: https://github.com/metanorma/ci/issues/369
#
# Invoked by the version-advisory-action composite (never curl'd from main).
# Emits a markdown table to $GITHUB_STEP_SUMMARY and a ::notice:: with the
# overall suggested bump. Never blocks — exit 0 always.
#
# Principles (ci#369 AC):
#   P1 Advisory only. Rescue clause guarantees exit 0.
#   P2 Opt-in via version_advisory input on rubygems-release.yml.
#   P4 Public vs internal classification with per-row evidence.
#   P5 Wrapper-friendly. Output only via $GITHUB_STEP_SUMMARY + ::notice::.
#   P6 Cheap and deterministic. Prism + git. No network.
#
# Phase-2 limitations (documented, not blockers):
#   - class << self blocks not distinguished from instance methods
#   - attr_accessor / attr_reader / attr_writer not extracted
#   - Inheritance / include / extend changes not detected
#   - define_method / class_eval metaprogramming not covered
#   - public_api.txt is read at HEAD (not at prev_tag)

require "prism"
require "open3"
require "digest"

module VersionAdvisory
  # Ordered signals, first-match-wins. Default = :unknown.
  module ApiSurface
    ANNOTATION_PUBLIC  = /^\s*#\s*@api\s+public\b/
    ANNOTATION_PRIVATE = /^\s*#\s*@api\s+private\b/
    YARD_METHOD_TAG    = /^\s*#\s*@!method\b/
    NODOC              = /^\s*#\s*:nodoc:/

    INTERNAL_MODULE_NAMES = %w[Internal Private].freeze
    INTERNAL_DIR_SEGMENTS = %w[internal private].freeze

    def self.classify(symbol_info)
      comments = symbol_info[:comment_block] || []

      if comments.any? { |c| c.match?(ANNOTATION_PUBLIC) }
        return [:public, "annotation `# @api public` at #{symbol_info[:file]}:#{symbol_info[:line]}"]
      end
      if comments.any? { |c| c.match?(ANNOTATION_PRIVATE) }
        return [:internal, "annotation `# @api private` at #{symbol_info[:file]}:#{symbol_info[:line]}"]
      end
      if comments.any? { |c| c.match?(NODOC) }
        return [:internal, "`:nodoc:` at #{symbol_info[:file]}:#{symbol_info[:line]}"]
      end
      if comments.any? { |c| c.match?(YARD_METHOD_TAG) }
        return [:public, "Yard `# @!method` at #{symbol_info[:file]}:#{symbol_info[:line]}"]
      end

      contract = load_contract_file
      if contract && !contract.empty?
        fqn = symbol_info[:namespace_path]
        return [:public, "listed in public_api.txt"] if contract.include?(fqn)

        return [:internal, "not listed in public_api.txt"]
      end

      ns = symbol_info[:namespace_path]
      if ns && INTERNAL_MODULE_NAMES.any? { |m| ns.include?("::#{m}::") || ns.start_with?("#{m}::") }
        return [:internal, "in `Internal`/`Private` namespace (#{ns})"]
      end
      if symbol_info[:name].to_s.start_with?("_")
        return [:internal, "leading-underscore name (#{symbol_info[:name]})"]
      end
      if INTERNAL_DIR_SEGMENTS.any? { |seg| symbol_info[:file].to_s.include?("/#{seg}/") }
        return [:internal, "under lib/*/{internal,private}/ path (#{symbol_info[:file]})"]
      end

      [:unknown, "no api-surface signal found; consider marking with `# @api`"]
    end

    def self.load_contract_file
      return @contract if defined?(@contract)

      path = "public_api.txt"
      @contract = if File.exist?(path)
                    File.readlines(path, chomp: true).reject { |l| l.empty? || l.start_with?("#") }
                  end
    end

    def self.reset_contract_cache!
      remove_instance_variable(:@contract) if defined?(@contract)
    end
  end

  module DiffRange
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
      warn "git #{args.join(' ')} failed: #{err}" if !status.success? && !allow_failure
      [out, status]
    end
  end

  module Extractor
    SymbolInfo = Struct.new(
      :kind, :name, :namespace_path, :file, :line,
      :comment_block, :signature, :body_fingerprint,
      keyword_init: true,
    )

    def self.extract(source, file_path)
      return [] if source.nil? || source.empty?

      parse_result = Prism.parse(source)
      return [] if parse_result.failure?

      symbols = []
      visitor = Visitor.new(file_path, source, symbols)
      visitor.visit(parse_result.value)
      symbols
    end

    # Proper Prism::Visitor subclass — no string-mangled send/respond_to? dispatch.
    class Visitor < Prism::Visitor
      def initialize(file_path, source, out)
        super()
        @file_path = file_path
        @source_lines = source.split("\n")
        @out = out
        @namespace_stack = []
      end

      def visit_class_node(node)
        name = node_name(node.constant_path)
        @namespace_stack.push(name)
        emit(:class, name, node)
        super
        @namespace_stack.pop
      end

      def visit_module_node(node)
        name = node_name(node.constant_path)
        @namespace_stack.push(name)
        emit(:module, name, node)
        super
        @namespace_stack.pop
      end

      def visit_def_node(node)
        name = node.name.to_s
        emit(:method, name, node,
             signature: method_signature(node),
             body_fingerprint: body_fingerprint(node))
        # Do not descend into method bodies
      end

      def visit_constant_write_node(node)
        emit(:constant, node.name.to_s, node)
      end

      private

      def emit(kind, name, node, signature: nil, body_fingerprint: nil)
        line = node.location.start_line
        @out << SymbolInfo.new(
          kind: kind,
          name: name,
          namespace_path: (@namespace_stack + [name]).join("::"),
          file: @file_path,
          line: line,
          comment_block: preceding_comment_block(line),
          signature: signature,
          body_fingerprint: body_fingerprint,
        )
      end

      # Fingerprint ignores trailing comments and blank lines. Leading
      # whitespace is preserved (re-indent of a method body is a real change
      # for heredocs / %w[] etc. and is intentionally detected).
      def body_fingerprint(def_node)
        loc = def_node.location
        source_lines = (loc.start_line..loc.end_line).map { |ln| @source_lines[ln - 1] || "" }
        normalised = source_lines
                     .map { |l| l.sub(/#.*$/, "").rstrip }
                     .reject { |l| l.strip.empty? }
                     .join("\n")
        Digest::SHA1.hexdigest(normalised)
      end

      def preceding_comment_block(target_line)
        block = []
        i = target_line - 2
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

  module Diff
    Change = Struct.new(:kind, :symbol_before, :symbol_after, keyword_init: true)

    def self.compute(before_symbols, after_symbols)
      changes = []
      # .last wins for reopened-class redefinitions (the active definition).
      before_by_fqn = before_symbols.group_by { |s| [s.kind, s.namespace_path] }
                                    .transform_values(&:last)
      after_by_fqn  = after_symbols.group_by { |s| [s.kind, s.namespace_path] }
                                   .transform_values(&:last)

      (before_by_fqn.keys | after_by_fqn.keys).each do |key|
        before = before_by_fqn[key]
        after  = after_by_fqn[key]

        if before && !after
          changes << Change.new(kind: :removed, symbol_before: before, symbol_after: nil)
        elsif !before && after
          changes << Change.new(kind: :added, symbol_before: nil, symbol_after: after)
        elsif before && after && before.kind == :method
          if signature_broken?(before.signature, after.signature)
            changes << Change.new(kind: :signature_changed, symbol_before: before, symbol_after: after)
          elsif before.body_fingerprint && after.body_fingerprint &&
                before.body_fingerprint != after.body_fingerprint
            changes << Change.new(kind: :body_changed_maybe, symbol_before: before, symbol_after: after)
          end
        end
      end

      changes
    end

    def self.signature_broken?(before_sig, after_sig)
      return false unless before_sig && after_sig
      return true if (before_sig[:required] || []) != (after_sig[:required] || [])
      return true if ((before_sig[:keywords] || []) - (after_sig[:keywords] || [])).any?

      false
    end
  end

  module Bucket
    Row = Struct.new(:change, :api_classification, :evidence, :suggested_bump, keyword_init: true)

    ORDER = %i[none patch minor major unknown].freeze

    # OCP lookup: [change.kind, api_class] → bump. Exhaustive for known pairs.
    BUMP_TABLE = {
      [:added, :public] => :minor,
      [:added, :internal] => :patch,
      [:added, :unknown] => :patch,
      [:removed, :public] => :major,
      [:removed, :internal] => :patch,
      [:removed, :unknown] => :unknown,
      [:signature_changed, :public] => :major,
      [:signature_changed, :internal] => :patch,
      [:signature_changed, :unknown] => :unknown,
      [:body_changed_maybe, :public] => :unknown,
      [:body_changed_maybe, :internal] => :patch,
      [:body_changed_maybe, :unknown] => :unknown,
    }.freeze

    def self.classify_all(changes, pre_1_0: false)
      rows = changes.map { |ch| classify_one(ch, pre_1_0: pre_1_0) }
      overall = rows.map(&:suggested_bump).max_by { |b| ORDER.index(b) || -1 } || :none
      [rows, overall]
    end

    def self.classify_one(change, pre_1_0: false)
      symbol = change.symbol_after || change.symbol_before
      api_class, evidence = ApiSurface.classify(symbol_info_for(symbol))
      bump = BUMP_TABLE[[change.kind, api_class]] || :none

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

  module Output
    def self.emit_summary(rows, overall_bump, prev_tag, requested_bump)
      summary_path = ENV["GITHUB_STEP_SUMMARY"]
      return unless summary_path

      File.open(summary_path, "a") { |f| f.write(build_markdown(rows, overall_bump, prev_tag, requested_bump)) }
    end

    def self.emit_notice(overall_bump, requested_bump)
      msg = if requested_bump && overall_bump.to_s != requested_bump.to_s
              "Detected changes suggest '#{overall_bump}'. You selected '#{requested_bump}'. See run summary."
            else
              "Detected changes suggest '#{overall_bump}'."
            end
      warn "::notice title=Version advisory::#{msg}"
    end

    def self.build_markdown(rows, overall_bump, prev_tag, requested_bump)
      out = +"\n## Version advisory\n\n"
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
        out << "| #{describe_change(row.change)} | #{row.api_classification} | #{row.evidence} | #{row.suggested_bump} |\n"
      end
      out << "\n_Advisory only. Maintainer selects the bump. See ci#369 for the design brief._\n"
      out
    end

    def self.describe_change(change)
      case change.kind
      when :added then "Added `#{change.symbol_after.namespace_path}`"
      when :removed then "Removed `#{change.symbol_before.namespace_path}`"
      when :signature_changed then "Signature-changed `#{change.symbol_after.namespace_path}`"
      when :body_changed_maybe then "Body-changed (undetectable) `#{change.symbol_after.namespace_path}`"
      end
    end
  end

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
    rows, overall_bump = Bucket.classify_all(changes, pre_1_0: pre_1_0_tag?(prev_tag))
    Output.emit_summary(rows, overall_bump, prev_tag, requested_bump)
    Output.emit_notice(overall_bump, requested_bump)
    0
  rescue StandardError => e
    warn "::warning title=Version advisory crashed::#{e.class}: #{e.message}"
    warn e.backtrace.first(5).join("\n")
    0
  end

  def self.pre_1_0_tag?(tag)
    return false unless tag

    m = tag.to_s.match(/\Av?(\d+)\./)
    m && m[1] == "0"
  end
end

exit VersionAdvisory.run if $PROGRAM_NAME == __FILE__
