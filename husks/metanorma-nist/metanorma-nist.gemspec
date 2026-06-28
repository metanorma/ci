Gem::Specification.new do |spec|
  spec.name          = "metanorma-nist"
  spec.version       = "1.5.0"
  spec.authors       = ["Ribose Inc."]
  spec.email         = ["open.source@ribose.com"]

  spec.summary       = "DEPRECATED PUBLIC STUB — metanorma-nist development is private."
  spec.description   = <<~DESC
    This is a deprecation stub. Active metanorma-nist development has moved
    to a private GitHub Packages registry at the request of NIST.

    If you have authorised access, configure your Gemfile to pull from the
    private source:

      source "https://rubygems.pkg.github.com/metanorma" do
        gem "metanorma-nist"
      end

    See https://github.com/metanorma/metanorma-nist for access and migration
    information.
  DESC
  spec.homepage      = "https://github.com/metanorma/metanorma-nist"
  spec.license       = "BSD-2-Clause"

  spec.required_ruby_version = Gem::Requirement.new(">= 3.3.0")

  spec.files         = Dir["lib/**/*", "README.md"]
  spec.require_paths = ["lib"]

  # NO runtime dependencies. That is the entire point of the husk.
end
