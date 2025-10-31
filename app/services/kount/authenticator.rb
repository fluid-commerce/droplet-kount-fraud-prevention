# frozen_string_literal: true

module Kount
  class Authenticator
    AUTH_URLS = {
      sandbox: "https://login.kount.com/oauth2/ausdppkujzCPQuIrY357/v1/token",
      production: "https://login.kount.com/oauth2/ausdppksgrbyM0abp357/v1/token",
    }.freeze

    API_BASE_URLS = {
      sandbox: "https://api-sandbox.kount.com/commerce/v2",
      production: "https://api.kount.com/commerce/v2",
    }.freeze

    TOKEN_BUFFER_SECONDS = 30

    def initialize(api_key, environment)
      @api_key = api_key
      @environment = environment
    end

    def bearer_token
      cached = Rails.cache.read(cache_key)
      return cached[:token] if cached && Time.now < cached[:expires_at]

      refresh_token
    end

  private

    attr_reader :api_key, :environment

    def refresh_token
      response = HTTParty.post(
        AUTH_URLS[environment],
        headers: {
          "Content-Type" => "application/x-www-form-urlencoded",
          "Authorization" => "Basic #{api_key}",
        },
        body: { grant_type: "client_credentials", scope: "k1_integration_api" }
      )

      raise AuthenticationError.new("Failed to authenticate with Kount",
                                    response.parsed_response) unless response.success?

      body = response.parsed_response
      expires_in = body["expires_in"].to_i
      token = body["access_token"]
      expires_at = Time.now + expires_in - TOKEN_BUFFER_SECONDS

      Rails.cache.write(cache_key, { token:, expires_at: }, expires_in:)
      token
    end

    def cache_key
      "kount_bearer_token_#{environment}"
    end
  end
end
