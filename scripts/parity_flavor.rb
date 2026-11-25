# frozen_string_literal: true

# Resolves a parity flavor name to the gem and AsciiDoc backend that serve it.
# Tastes (metanorma-taste) have no gem or Asciidoctor backend of their own:
# they ride on a base flavor and are registered by metanorma-taste. Shared by
# gemfiles/html_parity.gemfile (at Bundler time) and scripts/render_engines.rb.
module ParityFlavor
  # taste => base flavor. Keep in step with metanorma-taste data/<taste>/config.yaml
  # (`base-flavor`). Needed here because the gemfile is evaluated before any gem loads.
  TASTES = { "iala" => "iho", "wmo" => "iho" }.freeze

  # Flavors whose released gem requires metanorma-iso's document models
  # without declaring the dependency (metanorma-iho 1.4.9).
  NEEDS_ISO = %w[iho].freeze

  def self.taste?(name) = TASTES.key?(name.to_s)

  def self.base(name) = TASTES.fetch(name.to_s, name.to_s)

  # Gem names Bundler must provide for +name+.
  def self.gems(name)
    list = ["metanorma-#{base(name)}"]
    list << "metanorma-iso" if NEEDS_ISO.include?(base(name))
    list << "metanorma-taste" if taste?(name)
    list.uniq
  end
end
