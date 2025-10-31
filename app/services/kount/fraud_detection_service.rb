# frozen_string_literal: true

require "httparty"

module Kount
  class FraudDetectionService
    def initialize(company)
      @company = company
      @environment = Rails.env.production? ? :production : :sandbox
      @api_key = company.integration_setting.kount_api_key
    end

    def evaluate_order(raw_params, options = {})
      validate_raw_params!(raw_params)

      options.reverse_merge!(
        mode: :post_auth,
        risk_inquiry: true,
        exclude_device: false
      )

      payload = Kount::RequestBuilder.new(raw_params).build
      url = build_orders_url(options)
      headers = {
        "Authorization" => "Bearer #{authenticator.bearer_token}",
        "Content-Type" => "application/json",
      }

      Rails.logger.info("[Kount] Sending order risk inquiry: #{raw_params[:order_id]}")
      response = HTTParty.post(url, headers:, body: payload.to_json)
      Kount::ResponseParser.new(response).parse
    rescue Kount::AuthenticationError, Kount::APIError => e
      Rails.logger.error("[Kount] #{e.class}: #{e.message}")
      raise
    rescue => e
      Rails.logger.error("[Kount] Unexpected error: #{e.class} #{e.message}")
      raise Kount::APIError, e.message
    end

  private

    attr_reader :company, :api_key, :environment

    def authenticator
      @authenticator ||= Kount::Authenticator.new(api_key, environment)
    end

    def build_orders_url(options)
      base = Kount::Authenticator::API_BASE_URLS[environment] + "/orders"
      params = []
      params << "riskInquiry=#{options[:risk_inquiry]}" if options[:risk_inquiry]
      params << "excludeDevice=#{options[:exclude_device]}" if options[:exclude_device]
      params.any? ? "#{base}?#{params.join('&')}" : base
    end

    def validate_raw_params!(params)
      %i[company_id order_id session_id total_amount currency created_at channel payment customer].each do |key|
        raise ArgumentError, "#{key} is required" if params[key].blank?
      end
    end
  end
end
