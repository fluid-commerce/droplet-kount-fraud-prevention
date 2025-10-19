# frozen_string_literal: true

class IntegrationSetting < ApplicationRecord
  belongs_to :company

  validates :company_id, presence: true
  store_accessor :credentials, :kount_client_id, :kount_api_key
end
