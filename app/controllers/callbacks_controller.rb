# frozen_string_literal: true

class CallbacksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :set_company

  def evaluate_order_risk_kount
    service = Kount::FraudDetectionService.new(@company)
    result = service.evaluate_order(kount_order_params.to_h)

    Rails.logger.info(
      "Fraud evaluation completed for order #{params[:order_id]}: " \
      "#{result[:decision]} (score: #{result[:risk_score]})"
    )

    render json: result, status: :ok

  rescue Kount::AuthenticationError => e
    Rails.logger.error("Kount authentication error for order #{params[:order_id]}: #{e.message}")
    render json: e.json_response || { error: "Authentication failed: #{e.message}" }, status: :unauthorized

  rescue Kount::APIError => e
    Rails.logger.error("Kount API error for order #{params[:order_id]}: #{e.message}")
    render json: { error: "Fraud evaluation failed: #{e.message}" }, status: :unprocessable_entity

  rescue StandardError => e
    Rails.logger.error("Unexpected error in fraud evaluation for order #{params[:order_id]}: #{e.message}")
    render json: { error: "Internal server error" }, status: :internal_server_error
  end

private

  def set_company
    @company = Company.find_by(fluid_company_id: params[:company_id])
    raise ArgumentError, "Company not found" if @company.nil?
  end

  def kount_order_params
    params.permit(
      :company_id, :order_id, :session_id, :total_amount, :currency, :created_at, :channel,
      :merchant_category_code, :mode, :risk_inquiry, :exclude_device,
      payment: %i[type token last4 brand],
      customer: %i[id email first_name last_name phone ip_address account_created_at],
      shipping_address: %i[address1 address2 city region postal_code country],
      items: %i[name description sku quantity price is_digital]
    )
  end
end
