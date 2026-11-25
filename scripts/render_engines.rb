#!/usr/bin/env ruby
# frozen_string_literal: true

# Render a flavor's sources to HTML through one chosen HTML engine, using
# metanorma-core's engine factory (Metanorma::Core::Isodoc.create with
# html_engine:). This is the render step of scripts/html_parity.py (ci#507).
#
# `metanorma site generate` never calls the factory, so there is no switch
# on the CLI; this script calls it directly.
#
# Usage (run under gemfiles/html_parity.gemfile, see docs/render-baseline.md):
#   BUNDLE_GEMFILE=gemfiles/html_parity.gemfile PARITY_FLAVOR=iec \
#     bundle exec ruby scripts/render_engines.rb \
#       --flavor iec --engine document --input mn-samples-iec --out out/document
#
# --input  an .adoc file, a directory of .adoc files (a "sources" subdirectory
#          is preferred when present), or a directory of *.presentation.xml
#          files (these skip the AsciiDoc and presentation steps).
# --engine isodoc | document
# Writes <out>/<name>.html per input. Exit 0 only if every input rendered.

require "optparse"
require "fileutils"

opts = { engine: "isodoc" }
OptionParser.new do |o|
  o.on("--flavor F") { |v| opts[:flavor] = v }
  o.on("--engine E", %w[isodoc document]) { |v| opts[:engine] = v }
  o.on("--input PATH") { |v| opts[:input] = v }
  o.on("--out DIR") { |v| opts[:out] = v }
end.parse!
%i[flavor input out].each { |k| abort "missing --#{k}" unless opts[k] }

require "asciidoctor"
require "nokogiri"
require "metanorma-#{opts[:flavor]}"
require "metanorma-core"

flavor = opts[:flavor].to_sym
input = File.expand_path(opts[:input])
out = File.expand_path(opts[:out])
FileUtils.mkdir_p(out)

# Returns [[path, kind]] where kind is :adoc or :presxml.
def inputs(path)
  return [[path, :adoc]] if File.file?(path)

  dir = File.directory?(File.join(path, "sources")) ? File.join(path, "sources") : path
  pres = Dir[File.join(dir, "*.presentation.xml")].sort
  return pres.map { |f| [f, :presxml] } unless pres.empty?

  Dir[File.join(dir, "*.adoc")].sort.map { |f| [f, :adoc] }
end

def presentation_xml(file, kind, flavor, out)
  return File.read(file) if kind == :presxml

  xml = Dir.chdir(File.dirname(file)) do
    Asciidoctor.convert(File.read(file), backend: flavor, safe: :unsafe,
                                          header_footer: true, attributes: ["nodoc"],
                                          base_dir: File.dirname(file))
  end
  name = File.basename(file, ".adoc")
  semantic = File.join(out, "#{name}.xml")
  File.write(semantic, xml)
  # Presentation XML comes from the engine-independent legacy converter:
  # only the HTML stage differs between engines.
  Dir.chdir(File.dirname(file)) do
    Metanorma::Core::Isodoc.create(flavor, lang: lang_of(xml), script: script_of(xml),
                                           xml: Nokogiri::XML(xml), presxml: true)
      .convert(semantic, xml, true)
  end
end

def lang_of(xml)
  Nokogiri::XML(xml).remove_namespaces!.at("//bibdata/language")&.text || "en"
end

def script_of(xml)
  Nokogiri::XML(xml).remove_namespaces!.at("//bibdata/script")&.text || "Latn"
end

list = inputs(input)
abort "no .adoc or .presentation.xml inputs under #{input}" if list.empty?
failed = 0
list.each do |file, kind|
  name = File.basename(file).sub(/(\.presentation\.xml|\.adoc)\z/, "")
  begin
    pres = presentation_xml(file, kind, flavor, out)
    conv = Metanorma::Core::Isodoc.create(flavor, lang: lang_of(pres), script: script_of(pres),
                                                  xml: Nokogiri::XML(pres), presxml: false,
                                                  html_engine: opts[:engine].to_sym)
    conv.convert(File.join(out, "#{name}.presentation.xml"), pres, false,
                 File.join(out, "#{name}.html"))
    abort "no output for #{name}" unless File.exist?(File.join(out, "#{name}.html"))
    puts "#{opts[:engine]}: #{name}.html"
  rescue StandardError => e
    failed += 1
    warn "#{opts[:engine]}: #{name} failed: #{e.class}: #{e.message[0, 300]}"
  end
end
exit(failed.zero? ? 0 : 1)
