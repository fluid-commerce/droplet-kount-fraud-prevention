# frozen_string_literal: true

class CallbacksController < ApplicationController
  skip_before_action :verify_authenticity_token

  def evaluate_order_risk_kount
    begin
      # Extract and validate the request data
      order_data = extract_order_data

      # Initialize the Kount fraud detection service
      fraud_service = KountFraudDetectionService.new(@company)

      # Evaluate the order risk
      result = fraud_service.evaluate_order_risk(order_data)

      # Log the result for audit purposes
      Rails.logger.info("Fraud evaluation completed for order#{order_data[:order_id]}: #{result[:decision]}
       (score: #{result[:risk_score]})")

      # Return the result to Fluid
      render json: result, status: :ok

    rescue KountFraudDetectionService::Error => e
      Rails.logger.error("Kount fraud detection error for order #{params[:order_id]}: #{e.message}")
      render json: { error: "Fraud evaluation failed: #{e.message}" }, status: :unprocessable_entity

    rescue StandardError => e
      Rails.logger.error("Unexpected error in fraud evaluation for order #{params[:order_id]}: #{e.message}")
      render json: { error: "Internal server error" }, status: :internal_server_error
    end
  end

private

  def extract_order_data
    {
      order_id: params[:order_id],
      session_id: params[:session_id],
      total_amount: params[:total_amount],
      currency: params[:currency],
      payment: params[:payment],
      customer: params[:customer],
      shipping_address: params[:shipping_address],
    }
  end
end
