#!/usr/bin/env ruby
# frozen_string_literal: true

require "rubygems"
require "optparse"

module TargetVersion
  SEM_VER = 1
  CHOCOLATEY = 2
end

defaults = {
  strip_prefix: false,
  target_version: TargetVersion::SEM_VER,
  self_test: false,
  keep_first: -1,
}

options = defaults.dup

OptionParser.new do |opts|
  opts.banner = <<~HELP
    Utility to convert gem version to other version formats

    Usage: gemver-to-semver.rb [options] <version>"
  HELP

  opts.on("-d", "--strip-prefix", "String non numeric prefix before version") do
    options[:strip_prefix] = true
  end
  opts.on("-s", "--SEM_VER-org",
          "Target version will conform with semver.org specification") do
    options[:target_version] = TargetVersion::SEM_VER
  end
  opts.on(
    "-c",
    "--CHOCOLATEY",
    "Target version will conform with" \
    "https://docs.chocolatey.org/en-us/create/create-packages#versioning-recommendations",
  ) do
    options[:target_version] = TargetVersion::CHOCOLATEY
    options[:strip_prefix] = true
  end
  opts.on(
    "-k",
    "--keep N",
    "Keep only first N sections of version string",
  ) do |val|
    options[:keep_first] = val.to_i
  end
  opts.on("-t", "--self-test", "Run utility's self-test") do
    options[:self_test] = true
  end
end.parse!

def fix_prelease(gem_ver, is_chocolatey)
  pre_found = false
  r = gem_ver.segments.inject("") do |result, segment|
    next result if segment == "pre" && pre_found

    pre_found = true if segment == "pre"
    if is_chocolatey && segment.is_a?(String)
      result += "-pre"
      break result
    end
    result + "#{segment.is_a?(Numeric) ? '.' : '-'}#{segment}"
  end

  r[1..-1]
end

def convert(verstr, is_chocolatey, strip_prefix, keep_head)
  prefix = verstr[/\b[a-zA-Z\/]*/]

  gem_ver = Gem::Version.new(verstr.to_s.sub(prefix, ""))
  if keep_head.positive?
    gem_ver = Gem::Version.new(gem_ver.segments.first(keep_head).join("."))
  end

  if gem_ver.prerelease?
    result = fix_prelease(gem_ver, is_chocolatey)
    return strip_prefix ? result : prefix + result
  end

  strip_prefix ? gem_ver.to_s : prefix + gem_ver.to_s
end

input = ARGV[0]

unless options[:self_test]
  is_chocolatey = options[:target_version] == TargetVersion::CHOCOLATEY
  strip_prefix = options[:strip_prefix] || is_chocolatey
  keep_first = options[:keep_first]
  puts(convert(input, is_chocolatey, strip_prefix, keep_first))
  return
end

DEFAULTS = [false, false, -1].freeze
CHOCOLATEY = [true, true, -1].freeze
STRIP = [false, true, -1].freeze

test_suite = {
  "1": [{ expected: "1", options: [STRIP, CHOCOLATEY, DEFAULTS] }],
  "1.2": [{ expected: "1.2", options: [DEFAULTS, CHOCOLATEY, STRIP] }],
  "1.2.3": [{ expected: "1.2.3", options: [STRIP, CHOCOLATEY, DEFAULTS] }],
  "1.2.3rc": [{ expected: "1.2.3-rc", options: [DEFAULTS] }],
  "1.2.3rc1": [{ expected: "1.2.3-rc.1", options: [DEFAULTS] }],
  v1: [
    { expected: "v1", options: [DEFAULTS] },
    { expected: "1", options: [CHOCOLATEY, STRIP] },
  ],
  "v1.2": [
    { expected: "v1.2", options: [DEFAULTS] },
    { expected: "1.2", options: [CHOCOLATEY, STRIP] },
  ],
  "v1.2.3": [
    { expected: "v1.2.3", options: [DEFAULTS] },
    { expected: "1.2.3", options: [CHOCOLATEY, STRIP] },
  ],
  "refs/tags/v1.2.3": [
    { expected: "refs/tags/v1.2.3", options: [DEFAULTS] },
    { expected: "1.2.3", options: [CHOCOLATEY, STRIP] },
  ],
  "v1.2.3rc": [
    { expected: "v1.2.3-rc", options: [DEFAULTS] },
    { expected: "1.2.3-pre", options: [CHOCOLATEY] },
    { expected: "1.2.3-rc", options: [STRIP] },
  ],
  "v1.2.3rc1": [
    { expected: "v1.2.3-rc.1", options: [DEFAULTS] },
    { expected: "1.2.3-pre", options: [CHOCOLATEY] },
    { expected: "1.2.3-rc.1", options: [STRIP] },
  ],
  "v1.2.3pre": [
    { expected: "v1.2.3-pre", options: [DEFAULTS] },
    { expected: "1.2.3-pre", options: [CHOCOLATEY] },
    { expected: "1.2.3-pre", options: [STRIP] },
  ],
  "v10.02.53pre.15": [
    { expected: "v10.2.53-pre.15", options: [DEFAULTS] },
    { expected: "10.2.53-pre", options: [CHOCOLATEY] },
    { expected: "10.2.53-pre.15", options: [STRIP] },
  ],
  "v1.2.3-pre": [
    { expected: "v1.2.3-pre", options: [DEFAULTS] },
    { expected: "1.2.3-pre", options: [CHOCOLATEY] },
    { expected: "1.2.3-pre", options: [STRIP] },
  ],
  "1.6.0.1": [
    { expected: "1.6.0-rc.1", options: [DEFAULTS] },
    { expected: "1.6.0.1", options: [CHOCOLATEY] },
    { expected: "1.6.0-rc.1", options: [STRIP] },
  ]
}
succeed = true
test_suite.each do |inver, test_cases|
  test_cases.each do |tc|
    tc[:options].each do |opts|
      result = convert(inver, *opts)
      expected = tc[:expected].to_s
      if result != expected
        succeed = false
        puts("Failed for #{inver}: expected:#{expected} actual:#{result}")
      end
    end
  end
end
puts("Self-test passed\n") if succeed
exit(succeed ? 0 : 2)
