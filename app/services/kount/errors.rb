# frozen_string_literal: true

module Kount
  class Error < StandardError; end

  class AuthenticationError < Error
    attr_reader :json_response

    def initialize(message, json_response = nil)
      super(message)
      @json_response = json_response
    end
  end

  class APIError < Error; end
end
