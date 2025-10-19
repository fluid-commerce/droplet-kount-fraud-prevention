# frozen_string_literal: true

require "httparty"

class KountFraudDetectionService
  class Error < StandardError; end
  class AuthenticationError < Error
    attr_reader :json_response

    def initialize(message, json_response = nil)
      super(message)
      @json_response = json_response
    end
  end
  class APIError < Error; end

  # These come from Kount’s documentation for v2.0
  AUTH_URLS = {
    sandbox: "https://login.kount.com/oauth2/ausdppkujzCPQuIrY357/v1/token",
    production: "https://login.kount.com/oauth2/ausdppksgrbyM0abp357/v1/token",
  }.freeze

  API_BASE_URLS = {
    sandbox: "https://api-sandbox.kount.com/commerce/v2",
    production: "https://api.kount.com/commerce/v2",
  }.freeze

  TOKEN_BUFFER_SECONDS = 30 # renew token slightly before expiration

  def initialize(company)
    @company = company
    @environment = Rails.env.production? ? :production : :sandbox
    @client_id = company.integration_setting.kount_client_id
    @client_secret = company.integration_setting.kount_api_key
    @merchant_id = @client_id # In Kount, merchant_id is typically the same as client_id
  end

  # Submit a risk inquiry for an order.
  # order_data: hash with required fields according to Kount's schema
  # options: hash with optional parameters
  #   - mode: :pre_auth or :post_auth (default: :post_auth)
  #   - risk_inquiry: boolean (default: true)
  #   - exclude_device: boolean (default: false)
  # Returns: hash with keys like :decision, :risk_score, :transaction_id, etc.
  def evaluate_order(order_data, options = {})
    validate_order_data!(order_data)

    # Set default options
    options = {
      mode: :post_auth,
      risk_inquiry: true,
      exclude_device: false,
    }.merge(options)

    url = build_orders_url(options)
    headers = {
      "Authorization" => "Bearer #{bearer_token}",
      "Content-Type" => "application/json",
    }
    body = build_orders_request(order_data, options).to_json

    Rails.logger.info("[Kount] Sending order risk inquiry: #{order_data[:order_id]}")

    response = HTTParty.post(url, headers: headers, body: body)

    # If token expired or invalid, try once to refresh
    if response.code == 401
      @access_token = nil
      response = HTTParty.post(url, headers: headers.merge("Authorization" => "Bearer #{bearer_token}"), body: body)
    end

    handle_response(response)
  rescue AuthenticationError => e
    Rails.logger.error("[Kount] Auth error: #{e.message}")
    raise
  rescue => e
    Rails.logger.error("[Kount] API error: #{e.class} #{e.message} | response #{response&.body}")
    raise APIError, e.message
  end

private

  attr_reader :company, :client_id, :client_secret, :merchant_id, :environment

  def api_base_url
    API_BASE_URLS[environment]
  end

  def auth_url
    AUTH_URLS[environment]
  end

  def build_orders_url(options)
    base_url = "#{api_base_url}/orders"
    query_params = []

    query_params << "riskInquiry=#{options[:risk_inquiry]}" if options[:risk_inquiry]
    query_params << "excludeDevice=#{options[:exclude_device]}" if options[:exclude_device]

    if query_params.any?
      "#{base_url}?#{query_params.join('&')}"
    else
      base_url
    end
  end

  # Token logic
  def bearer_token
    token_data = Rails.cache.read("kount_bearer_token")

    if token_data && Time.now < token_data[:expires_at]
      return token_data[:token]
    end

    # Otherwise, fetch a new token
    resp = HTTParty.post(
      auth_url,
      headers: { "Content-Type" => "application/x-www-form-urlencoded" },
      body: { grant_type: "client_credentials", scope: "k1_integration_api" },
      basic_auth: { username: client_id, password: client_secret }
    )

    unless resp.success?
      error_message = "Failed to obtain Kount token: #{resp.code} #{resp["errorSummary"]}"
      error_data = {
        error: "Authentication failed",
        message: error_message,
        code: resp.code,
        details: resp.parsed_response,
      }
      raise AuthenticationError.new(error_message, error_data)
    end

    body = resp.parsed_response
    token = body["access_token"]
    expires_in = body["expires_in"].to_i

    Rails.cache.write(
      "kount_bearer_token",
      { token: token, expires_at: Time.now + expires_in },
      expires_in: expires_in.seconds
    )

    token
  end

  def validate_order_data!(data)
    required = %i[order_id session_id customer]
    missing = required - data.keys
    if missing.any?
      raise Error, "Missing required order fields: #{missing.join(', ')}"
    end

    # Validate customer has required fields
    if data[:customer] && !data[:customer][:ip_address]
      raise Error, "Customer IP address is required"
    end

    # Validate items if provided
    if data[:items] && data[:items].any?
      data[:items].each_with_index do |item, index|
        item_required = %i[price quantity]
        item_missing = item_required - item.keys
        if item_missing.any?
          raise Error, "Missing required item fields at index #{index}: #{item_missing.join(', ')}"
        end
      end
    end
  end

  # Build the request body per Kount v2 Orders API spec
  def build_orders_request(order_data, options)
    req = {
      merchantOrderId: order_data[:order_id],
      channel: order_data[:channel] || "WEB",
      deviceSessionId: order_data[:session_id],
      creationDateTime: order_data[:creation_date_time] || Time.current.iso8601,
      userIp: order_data[:customer][:ip_address],
      account: build_account(order_data[:account]),
      items: build_items(order_data[:items]),
      fulfillment: build_fulfillment(order_data[:fulfillment]),
      transactions: build_transactions(order_data[:transactions]),
      promotions: build_promotions(order_data[:promotions]),
      loyalty: build_loyalty(order_data[:loyalty]),
      customFields: order_data[:custom_fields],
      merchantCategoryCode: order_data[:merchant_category_code],
    }

    # Remove nil values to keep payload clean
    req.compact
  end

  def build_account(account_data)
    return nil unless account_data
    {
      id: account_data[:id],
      type: account_data[:type],
      creationDateTime: account_data[:creation_date_time],
      username: account_data[:username],
      accountIsActive: account_data[:account_is_active],
    }
  end

  def build_items(items_data)
    return [] unless items_data&.any?
    items_data.map do |item|
      {
        price: item[:price],
        description: item[:description],
        name: item[:name],
        quantity: item[:quantity],
        category: item[:category],
        subCategory: item[:sub_category],
        isDigital: item[:is_digital],
        sku: item[:sku],
        upc: item[:upc],
        brand: item[:brand],
        url: item[:url],
        imageUrl: item[:image_url],
        physicalAttributes: build_physical_attributes(item[:physical_attributes]),
        descriptors: item[:descriptors],
        id: item[:id],
        isService: item[:is_service],
      }.compact
    end
  end

  def build_physical_attributes(attrs)
    return nil unless attrs
    {
      color: attrs[:color],
      size: attrs[:size],
      weight: attrs[:weight],
      height: attrs[:height],
      width: attrs[:width],
      depth: attrs[:depth],
    }.compact
  end

  def build_fulfillment(fulfillment_data)
    return [] unless fulfillment_data&.any?
    fulfillment_data.map do |fulfillment|
      {
        type: fulfillment[:type],
        shipping: build_shipping_info(fulfillment[:shipping]),
        recipientPerson: build_person(fulfillment[:recipient_person]),
        items: build_fulfillment_items(fulfillment[:items]),
        status: fulfillment[:status],
        accessUrl: fulfillment[:access_url],
        store: build_store(fulfillment[:store]),
        merchantFulfillmentId: fulfillment[:merchant_fulfillment_id],
        digitalDownloaded: fulfillment[:digital_downloaded],
        downloadDeviceIp: fulfillment[:download_device_ip],
      }.compact
    end
  end

  def build_shipping_info(shipping)
    return nil unless shipping
    {
      amount: shipping[:amount],
      provider: shipping[:provider],
      trackingNumber: shipping[:tracking_number],
      method: shipping[:method],
    }.compact
  end

  def build_person(person_data)
    return nil unless person_data
    {
      name: build_person_name(person_data[:name]),
      phoneNumber: person_data[:phone_number],
      emailAddress: person_data[:email_address],
      address: build_address(person_data[:address]),
      dateOfBirth: person_data[:date_of_birth],
    }.compact
  end

  def build_person_name(name_data)
    return nil unless name_data
    {
      first: name_data[:first],
      preferred: name_data[:preferred],
      family: name_data[:family],
      middle: name_data[:middle],
      prefix: name_data[:prefix],
      suffix: name_data[:suffix],
    }.compact
  end

  def build_address(address_data)
    return nil unless address_data
    {
      line1: address_data[:line1],
      line2: address_data[:line2],
      city: address_data[:city],
      region: address_data[:region],
      countryCode: address_data[:country_code],
      postalCode: address_data[:postal_code],
    }.compact
  end

  def build_fulfillment_items(items)
    return [] unless items&.any?
    items.map do |item|
      {
        id: item[:id],
        quantity: item[:quantity],
      }
    end
  end

  def build_store(store_data)
    return nil unless store_data
    {
      id: store_data[:id],
      name: store_data[:name],
      address: build_address(store_data[:address]),
    }.compact
  end

  def build_transactions(transactions_data)
    return [] unless transactions_data&.any?
    transactions_data.map do |transaction|
      {
        processor: transaction[:processor],
        processorMerchantId: transaction[:processor_merchant_id],
        payment: build_payment_info(transaction[:payment]),
        subtotal: transaction[:subtotal],
        orderTotal: transaction[:order_total],
        currency: transaction[:currency],
        tax: build_tax_info(transaction[:tax]),
        billedPerson: build_person(transaction[:billed_person]),
        transactionStatus: transaction[:transaction_status],
        authorizationStatus: build_authorization_status(transaction[:authorization_status]),
        merchantTransactionId: transaction[:merchant_transaction_id],
        items: build_fulfillment_items(transaction[:items]),
      }.compact
    end
  end

  def build_payment_info(payment_data)
    return nil unless payment_data
    {
      type: payment_data[:type],
      paymentToken: payment_data[:payment_token],
      bin: payment_data[:bin],
      last4: payment_data[:last4],
      cardBrand: payment_data[:card_brand],
    }.compact
  end

  def build_tax_info(tax_data)
    return nil unless tax_data
    {
      isTaxable: tax_data[:is_taxable],
      taxableCountryCode: tax_data[:taxable_country_code],
      taxAmount: tax_data[:tax_amount],
      outOfStateTaxAmount: tax_data[:out_of_state_tax_amount],
    }.compact
  end

  def build_authorization_status(auth_data)
    return nil unless auth_data
    {
      authResult: auth_data[:auth_result],
      dateTime: auth_data[:date_time],
      verificationResponse: build_verification_response(auth_data[:verification_response]),
      declineCode: auth_data[:decline_code],
      processorAuthCode: auth_data[:processor_auth_code],
      processorTransactionId: auth_data[:processor_transaction_id],
      acquirerReferenceNumber: auth_data[:acquirer_reference_number],
    }.compact
  end

  def build_verification_response(verification_data)
    return nil unless verification_data
    {
      cvvStatus: verification_data[:cvv_status],
      avsStatus: verification_data[:avs_status],
    }.compact
  end

  def build_promotions(promotions_data)
    return [] unless promotions_data&.any?
    promotions_data.map do |promotion|
      {
        id: promotion[:id],
        description: promotion[:description],
        status: promotion[:status],
        statusReason: promotion[:status_reason],
        discount: build_discount(promotion[:discount]),
        credit: build_credit(promotion[:credit]),
      }.compact
    end
  end

  def build_discount(discount_data)
    return nil unless discount_data
    {
      percentage: discount_data[:percentage],
      amount: discount_data[:amount],
      currency: discount_data[:currency],
    }.compact
  end

  def build_credit(credit_data)
    return nil unless credit_data
    {
      creditType: credit_data[:credit_type],
      amount: credit_data[:amount],
      currency: credit_data[:currency],
    }.compact
  end

  def build_loyalty(loyalty_data)
    return nil unless loyalty_data
    {
      id: loyalty_data[:id],
      description: loyalty_data[:description],
      credit: build_credit(loyalty_data[:credit]),
    }.compact
  end

  # Handle the HTTP response from Kount
  def handle_response(response)
    code = response.code.to_i
    if code >= 200 && code < 300
      body = response.parsed_response
      {
        decision: body["decision"],
        risk_score: body["riskScore"],
        reason_codes: body["reasonCodes"],
        transaction_id: body["transactionId"],
        raw: body,
      }
    else
      raise APIError, "Kount API error: #{code} | #{response.body}"
    end
  end
end
