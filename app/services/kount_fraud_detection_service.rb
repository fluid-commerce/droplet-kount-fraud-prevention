# frozen_string_literal: true

class KountFraudDetectionService
  include HTTParty

  Error = Class.new(StandardError)
  AuthenticationError = Class.new(Error)
  APIError = Class.new(Error)

  def initialize(company)
    @company = company
    @kount_settings = company.integration_settings.find_by("settings->>'integration_type' = ?", "kount")

    raise Error, "Kount integration not configured for company" unless @kount_settings

    self.class.base_uri kount_api_base_url
    self.class.format :json
    update_headers
  end

  def evaluate_order_risk(order_data)
    validate_order_data(order_data)

    kount_request = build_kount_request(order_data)

    Rails.logger.info("Sending fraud evaluation request to Kount for order #{order_data[:order_id]}")

    response = self.class.post("/risk/evaluate", body: kount_request.to_json)

    handle_kount_response(response, order_data[:order_id])
  rescue StandardError => e
    Rails.logger.error("Kount fraud evaluation failed for order #{order_data[:order_id]}: #{e.message}")
    raise APIError, "Fraud evaluation failed: #{e.message}"
  end

private

  attr_reader :company, :kount_settings

  def kount_api_base_url
    kount_settings.settings["api_base_url"] || "https://risk.kount.net"
  end

  def update_headers
    self.class.headers(
      "Content-Type" => "application/json",
      "Authorization" => "Bearer #{kount_settings.credentials['api_key']}"
    )
  end

  def validate_order_data(order_data)
    required_fields = %i[order_id session_id total_amount currency payment customer]
    missing_fields = required_fields - order_data.keys

    if missing_fields.any?
      raise Error, "Missing required fields: #{missing_fields.join(', ')}"
    end

    if order_data[:customer][:ip_address].blank?
      raise Error, "Customer IP address is required"
    end
  end

  def build_kount_request(order_data)
    {
      session_id: order_data[:session_id],
      order_id: order_data[:order_id],
      amount: order_data[:total_amount],
      currency: order_data[:currency],
      payment_method: map_payment_type(order_data[:payment][:type]),
      payment_token: order_data[:payment][:token],
      customer: {
        id: order_data[:customer][:id],
        email: order_data[:customer][:email],
        first_name: order_data[:customer][:first_name],
        last_name: order_data[:customer][:last_name],
        phone: order_data[:customer][:phone],
        ip_address: order_data[:customer][:ip_address],
      },
      shipping_address: build_shipping_address(order_data[:shipping_address]),
      merchant_id: kount_settings.settings["merchant_id"],
    }
  end

  def build_shipping_address(shipping_data)
    return nil unless shipping_data

    {
      address1: shipping_data[:address1],
      city: shipping_data[:city],
      postal_code: shipping_data[:postal_code],
      country: shipping_data[:country],
    }
  end

  def map_payment_type(fluid_payment_type)
    case fluid_payment_type
    when "CARD"
      "credit_card"
    when "TOKEN"
      "tokenized_card"
    when "PAYPAL"
      "paypal"
    else
      "other"
    end
  end

  def handle_kount_response(response, order_id)
    case response.code
    when 200..299
      kount_data = response.parsed_response

      {
        decision: map_decision(kount_data["decision"]),
        risk_score: kount_data["risk_score"],
        reason: kount_data["reason"],
        kount_transaction_id: kount_data["transaction_id"],
      }
    when 401
      raise AuthenticationError, "Kount API authentication failed"
    else
      raise APIError, "Kount API error: #{response.code} - #{response.body}"
    end
  end

  def map_decision(kount_decision)
    case kount_decision&.downcase
    when "approve", "approved"
      "approve"
    when "decline", "declined"
      "decline"
    else
      "review" # Default to review for unknown decisions or 'review', 'flagged'
    end
  end
end
