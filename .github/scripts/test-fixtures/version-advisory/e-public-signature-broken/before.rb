# frozen_string_literal: true

module Foo
  # @api public
  def self.transform(x, mode)
    mode == :double ? x * 2 : x
  end
end
