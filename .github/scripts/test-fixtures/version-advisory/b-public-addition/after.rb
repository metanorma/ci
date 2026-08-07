# frozen_string_literal: true

module Foo
  # @api public
  def self.existing_method(x)
    x
  end

  # @api public
  def self.new_public_method(x, y)
    x + y
  end
end
