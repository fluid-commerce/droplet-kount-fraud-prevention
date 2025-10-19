# frozen_string_literal: true

class IntegrationSettingsController < ApplicationController
  before_action :set_company
  before_action :set_integration_setting

  def edit;end

  def update
    if @integration_setting.update(integration_setting_params)
      flash[:notice] = "Integration settings have been successfully updated!"
      redirect_to edit_integration_setting_path(token: params[:token])
    else
      flash[:alert] = "There was an error saving your settings. Please try again."
      render :edit, status: :unprocessable_entity
    end
  end

private

  def set_company
    droplet_installation_uuid = params[:dri] || params[:integration_setting]&.dig(:dri)
    if droplet_installation_uuid.present?
      @dri = droplet_installation_uuid
      @company = Company.find_by(droplet_installation_uuid:)
    else
      render json: { error: "Invalid droplet installation UUID" }, status: :unauthorized
      return
    end

    unless @company
      render json: { error: "Company not found" }, status: :not_found
      nil
    end
  end

  def set_integration_setting
    @integration_setting = @company.integration_setting || @company.build_integration_setting
  end

  def integration_setting_params
    params.require(:integration_setting).permit(:enabled, :kount_client_id, :kount_api_key)
  end
end
