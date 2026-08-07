# frozen_string_literal: true

module Foo
  # :nodoc:
  def self.hidden_helper(x)
    x * 2
  end

  # @api public
  def self.public_thing(x)
    x + 1
  end
end
