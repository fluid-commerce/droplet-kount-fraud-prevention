# frozen_string_literal: true

module Kount
  class ResponseParser
    def initialize(response)
      @response = response
    end

    def parse
      code = response.code.to_i
      raise APIError, "Kount API error: #{code} #{response.body}" unless code.between?(200, 299)

      body = response.parsed_response
      order = body["order"] || {}
      risk = order["riskInquiry"] || {}

      {
        decision: risk["decision"],
        risk_score: risk["omniscore"],
        reason_codes: risk["reasonCode"],
        transaction_id: order.dig("transactions", 0, "transactionId"),
        order_id: order["orderId"],
        merchant_order_id: order["merchantOrderId"],
        persona: risk["persona"],
        raw: body,
      }
    end

  private

    attr_reader :response
  end
end
