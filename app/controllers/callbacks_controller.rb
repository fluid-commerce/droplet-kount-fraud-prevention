# frozen_string_literal: true

class CallbacksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :set_company

  def evaluate_order_risk_kount
    begin
      # Validate required parameters
      validate_required_params

      # Extract and validate the request data
      order_data = extract_order_data

      # Initialize the Kount fraud detection service
      service = KountFraudDetectionService.new(@company)

      # Evaluate the order risk
      result = service.evaluate_order(order_data)

      # Log the result for audit purposes
      Rails.logger.info(message: "Fraud evaluation completed for order #{order_data[:order_id]}: #{result[:decision]} (score: #{result[:risk_score]})")

      # Return the result to Fluid
      render json: result, status: :ok

    rescue ArgumentError => e
      Rails.logger.error(message: "Invalid parameters for order #{params[:merchantOrderId]}: #{e.message}")
      render json: { error: "Invalid parameters: #{e.message}" }, status: :bad_request
    rescue KountFraudDetectionService::AuthenticationError => e
      Rails.logger.error(message: "Kount authentication error for order #{params[:merchantOrderId]}: #{e.message}")
      # Use the JSON response from the error if available, otherwise use the message
      error_response = e.json_response || { error: "Authentication failed: #{e.message}" }
      render json: error_response, status: :unauthorized
    rescue KountFraudDetectionService::Error => e
      Rails.logger.error(message: "Kount fraud detection error for order #{params[:merchantOrderId]}: #{e.message}")
      render json: { error: "Fraud evaluation failed: #{e.message}" }, status: :unprocessable_entity

    rescue StandardError => e
      Rails.logger.error(message: "Unexpected error in fraud evaluation for order #{params[:merchantOrderId]}: #{e.message}")
      render json: { error: "Internal server error" }, status: :internal_server_error
    end
  end

private

  def set_company
    @company = Company.find_by(fluid_company_id: params[:company_id])
  end

  def validate_required_params
    # Validate required parameters based on YAML schema
    raise ArgumentError, "company_id is required" if params[:company_id].blank?
    raise ArgumentError, "merchantOrderId is required" if params[:merchantOrderId].blank?
    raise ArgumentError, "deviceSessionId is required" if params[:deviceSessionId].blank?
    raise ArgumentError, "creationDateTime is required" if params[:creationDateTime].blank?
    raise ArgumentError, "userIp is required" if params[:userIp].blank?
    raise ArgumentError, "merchantCategoryCode is required" if params[:merchantCategoryCode].blank?

    # Validate transactions array
    raise ArgumentError, "transactions array is required" if params[:transactions].blank?
    transaction = params[:transactions].first
    raise ArgumentError, "transaction must have payment information" if transaction&.dig(:payment).blank?
    raise ArgumentError, "transaction must have orderTotal" if transaction&.dig(:orderTotal).blank?
    raise ArgumentError, "transaction must have currency" if transaction&.dig(:currency).blank?

    # Validate customer information
    billing_person = transaction&.dig(:billedPerson)
    raise ArgumentError, "billedPerson is required" if billing_person.blank?
    raise ArgumentError, "customer email is required" if billing_person[:emailAddress].blank?

    # Validate items array
    raise ArgumentError, "items array is required" if params[:items].blank?

    # Validate fulfillment for shipping address
    fulfillment = params[:fulfillment]&.first
    return unless fulfillment.present?
    recipient = fulfillment[:recipientPerson]
    raise ArgumentError, "recipientPerson is required for fulfillment" if recipient.blank?
    address = recipient[:address]
    raise ArgumentError, "shipping address is required" if address.blank?
    raise ArgumentError, "shipping address line1 is required" if address[:line1].blank?
    raise ArgumentError, "shipping address country is required" if address[:countryCode].blank?
  end

  def extract_order_data
    # Extract transaction data for payment and total amount
    transaction = params[:transactions]&.first
    payment_data = transaction&.dig(:payment) || {}

    # Extract customer data from transaction billing person
    billing_person = transaction&.dig(:billedPerson) || {}
    customer_data = {
      id:                 billing_person[:emailAddress] || params[:account]&.dig(:id),
      email:              billing_person[:emailAddress],
      first_name:         billing_person.dig(:name, :first),
      last_name:          billing_person.dig(:name, :family),
      phone:              billing_person[:phoneNumber],
      ip_address:         params[:userIp],
      account_created_at: params[:account]&.dig(:creationDateTime),
    }

    # Extract shipping address from fulfillment
    fulfillment = params[:fulfillment]&.first
    shipping_address = fulfillment&.dig(:recipientPerson, :address) || {}
    shipping_data = {
      address1:    shipping_address[:line1],
      address2:    shipping_address[:line2],
      city:        shipping_address[:city],
      region:      shipping_address[:region],
      postal_code: shipping_address[:postalCode],
      country:     shipping_address[:countryCode],
    }

    # Transform items to match expected format
    items_data = params[:items]&.map do |item|
      {
        name:        item[:name],
        description: item[:description],
        sku:         item[:sku],
        quantity:    item[:quantity]&.to_i,
        price:       item[:price]&.to_f,
        is_digital:  item[:isDigital],
      }
    end || []

    # Extract payment information
    payment_info = {
      type:  payment_data[:type] == "CREDIT_CARD" ? "CARD" : "OTHER",
      token: payment_data[:paymentToken],
      last4: payment_data[:last4],
      brand: payment_data[:cardBrand],
    }

    {
      company_id:             @company&.id,
      order_id:               params[:merchantOrderId],
      session_id:             params[:deviceSessionId],
      total_amount:           transaction&.dig(:orderTotal)&.to_f,
      currency:               transaction&.dig(:currency),
      created_at:             params[:creationDateTime],
      channel:                params[:channel],
      merchant_category_code: params[:merchantCategoryCode],
      payment:                payment_info,
      customer:               customer_data,
      shipping_address:       shipping_data,
      items:                  items_data,
      mode:                   extract_options[:mode],
      risk_inquiry:           extract_options[:risk_inquiry],
      exclude_device:         extract_options[:exclude_device],
    }
  end

  def extract_options
    {
      mode:           params[:mode] || :post_auth,
      risk_inquiry:   params[:risk_inquiry] || true,
      exclude_device: params[:exclude_device] || false,
    }
  end
end
