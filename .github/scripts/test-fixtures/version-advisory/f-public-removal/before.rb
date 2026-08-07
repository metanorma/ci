# frozen_string_literal: true

module Foo
  # @api public
  def self.public_thing(x)
    x + 1
  end

  # @api public
  def self.doomed(x)
    x
  end
end
