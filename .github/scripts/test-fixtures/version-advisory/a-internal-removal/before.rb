# frozen_string_literal: true

module Foo
  # @api private
  def self.internal_helper(x)
    x * 2
  end

  # @api public
  def self.public_thing(x)
    x + 1
  end
end
