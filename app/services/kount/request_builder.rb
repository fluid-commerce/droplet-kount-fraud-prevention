# frozen_string_literal: true

module Kount
  class RequestBuilder
    def initialize(raw_params)
      @raw = raw_params.deep_symbolize_keys
    end

    def build
      {
        merchantOrderId: raw[:order_id],
        channel: raw[:channel] || "WEB",
        deviceSessionId: raw[:session_id],
        creationDateTime: format_time(raw[:created_at]),
        userIp: raw.dig(:customer, :ip_address),
        account: build_account,
        items: build_items,
        fulfillment: build_fulfillment,
        transactions: build_transactions,
        promotions: raw[:promotions],
        loyalty: raw[:loyalty],
        customFields: raw[:custom_fields],
        merchantCategoryCode: raw[:merchant_category_code],
      }.compact
    end

  private

    attr_reader :raw

    def build_account
      cust = raw[:customer] || {}
      {
        id: cust[:id],
        type: cust[:account_type] || "PRO_ACCOUNT",
        creationDateTime: cust[:account_created_at],
        username: cust[:email],
        accountIsActive: cust.fetch(:account_is_active, true),
      }.compact
    end

    def build_items
      (raw[:items] || []).map do |item|
        {
          id: item[:sku] || item[:id] || SecureRandom.uuid,
          name: item[:name],
          description: item[:description],
          quantity: item[:quantity].to_i,
          price: item[:price].to_f,
        }.compact
      end
    end

    def build_fulfillment
      shipping = raw[:shipping_address] || {}
      [ {
        type: raw[:fulfillment_type] || "DIGITAL",
        recipientPerson: {
          name: { first: raw.dig(:customer, :first_name), family: raw.dig(:customer, :last_name) },
          address: {
            line1: shipping[:address1],
            city: shipping[:city],
            countryCode: shipping[:country],
            postalCode: shipping[:postal_code],
          }.compact,
        }.compact,
        status: raw[:fulfillment_status] || "PENDING",
      }.compact ]
    end

    def build_transactions
      payment = raw[:payment] || {}
      [ {
        processor: raw[:processor] || "FLUID_DEFAULT",
        payment: {
          type: payment[:type],
          last4: payment[:last4],
          cardBrand: payment[:brand],
        }.compact,
        subtotal: raw[:total_amount].to_f,
        currency: raw[:currency],
        merchantTransactionId: raw[:order_id],
      }.compact ]
    end

    def format_time(val)
      return Time.current.utc.iso8601 if val.blank?
      time = Time.zone.parse(val.to_s) rescue Time.current
      [ time, Time.current ].min.utc.iso8601
    end
  end
end
