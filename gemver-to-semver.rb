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
  opts.on("-s", "--SEM_VER-org", "Target version will conform with https://SEM_VER.org specification") do
    options[:target_version] = TargetVersion::SEM_VER
  end
  opts.on("-c", "--CHOCOLATEY", "Target version will conform with https://docs.CHOCOLATEY.org/en-us/create/create-packages#versioning-recommendations") do
    options[:target_version] = TargetVersion::CHOCOLATEY
    options[:strip_prefix] = true
  end
  opts.on("-t", "--self-test", "Run utility's self-test") do
    options[:self_test] = true
  end
end.parse!

def convert(verstr, options)
  prefix = verstr[/\b[a-zA-Z\/]*/]
  clean_ver = verstr.to_s.sub(prefix, "")
  gem_ver = Gem::Version.new(clean_ver)
  strip_prefix = options[:strip_prefix] || options[:target_version] == TargetVersion::CHOCOLATEY

  result = ""
  pre_found = false
  if gem_ver.prerelease?
    for segment in gem_ver.segments
      next if segment == "pre" && pre_found
      pre_found = true if segment == "pre"

      separator = segment.is_a?(Numeric) ? "." : "-"
      if options[:target_version] == TargetVersion::CHOCOLATEY && segment.is_a?(String)
        result += "-pre"
        break
      end
      result += "#{separator}#{segment}"
    end
    result = result[1..-1] # remove leading dot

    if strip_prefix
      return result
    end

    return prefix + result
  end

  if strip_prefix
    return clean_ver
  end

  verstr.to_s
end

input = ARGV[0]

unless options[:self_test]
  print(convert(input, options))
  return
end

CHOCOLATEY = defaults.dup.merge!({ target_version: TargetVersion::CHOCOLATEY })
strip = defaults.dup.merge!({ strip_prefix: true })

test_suite = {
  "1": [{ expected: "1", options: [strip, CHOCOLATEY, defaults] }],
  "1.2": [{ expected: "1.2", options: [defaults, CHOCOLATEY, strip] }],
  "1.2.3": [{ expected: "1.2.3", options: [strip, CHOCOLATEY, defaults] }],
  "1.2.3rc": [{ expected: "1.2.3-rc", options: [defaults] }],
  "1.2.3rc1": [{ expected: "1.2.3-rc.1", options: [defaults] }],
  "v1": [
    { expected: "v1", options: [defaults] },
    { expected: "1", options: [CHOCOLATEY, strip] },
  ],
  "v1.2": [
    { expected: "v1.2", options: [defaults] },
    { expected: "1.2", options: [CHOCOLATEY, strip] },
  ],
  "v1.2.3": [
    { expected: "v1.2.3", options: [defaults] },
    { expected: "1.2.3", options: [CHOCOLATEY, strip] },
  ],
  "refs/tags/v1.2.3": [
    { expected: "refs/tags/v1.2.3", options: [defaults] },
    { expected: "1.2.3", options: [CHOCOLATEY, strip] },
  ],
  "v1.2.3rc": [
    { expected: "v1.2.3-rc", options: [defaults] },
    { expected: "1.2.3-pre", options: [CHOCOLATEY] },
    { expected: "1.2.3-rc", options: [strip] }
  ],
  "v1.2.3rc1": [
    { expected: "v1.2.3-rc.1", options: [defaults] },
    { expected: "1.2.3-pre", options: [CHOCOLATEY] },
    { expected: "1.2.3-rc.1", options: [strip] },
  ],
  "v1.2.3pre": [
    { expected: "v1.2.3-pre", options: [defaults] },
    { expected: "1.2.3-pre", options: [CHOCOLATEY] },
    { expected: "1.2.3-pre", options: [strip] },
  ],
  "v10.02.53pre.15": [
    { expected: "v10.2.53-pre.15", options: [defaults] },
    { expected: "10.2.53-pre", options: [CHOCOLATEY] },
    { expected: "10.2.53-pre.15", options: [strip] },
  ],
  "v1.2.3-pre": [
    { expected: "v1.2.3-pre", options: [defaults] },
    { expected: "1.2.3-pre", options: [CHOCOLATEY] },
    { expected: "1.2.3-pre", options: [strip] },
  ]
}
succeed = true
for input, test_cases in test_suite
  for tc in test_cases
    for opts in tc[:options]
      result = convert(input, opts)
      expected = tc[:expected].to_s
        if result != expected
        succeed = false
        print("Test failed for #{input}: expected:#{expected} actual:#{result}\n")
      end
    end
  end
end
print("Self-test passed\n") if succeed
exit(succeed ? 0 : 2)
