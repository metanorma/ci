Gem::Specification.new do |spec|
  spec.name          = "metanorma-bsi"
  spec.version       = "0.7.0"
  spec.authors       = ["Ribose Inc."]
  spec.email         = ["open.source@ribose.com"]

  spec.summary       = "DEPRECATED PUBLIC STUB — metanorma-bsi development is private."
  spec.description   = <<~DESC
    This is a deprecation stub. Active metanorma-bsi development has moved
    to a private GitHub Packages registry at the request of BSI.

    If you have authorised access, configure your Gemfile to pull from the
    private source:

      source "https://rubygems.pkg.github.com/metanorma" do
        gem "metanorma-bsi"
      end

    See https://github.com/metanorma/metanorma-bsi for access and migration
    information.
  DESC
  spec.homepage      = "https://github.com/metanorma/metanorma-bsi"
  spec.license       = "BSD-2-Clause"

  spec.required_ruby_version = Gem::Requirement.new(">= 3.3.0")

  spec.files         = Dir["lib/**/*", "README.md"]
  spec.require_paths = ["lib"]

  # NO runtime dependencies. That is the entire point of the husk.
end
