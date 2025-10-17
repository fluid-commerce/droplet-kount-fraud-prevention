Rails.application.routes.draw do
  root "home#index"

  devise_for :users

  post "webhook", to: "webhooks#create", as: :webhook

  post "callbacks/evaluate_order_risk_kount", to: "callbacks#evaluate_order_risk_kount", as: :evaluate_order_risk_kount

  get "integration_settings/edit", to: "integration_settings#edit", as: :edit_integration_setting
  patch "integration_settings", to: "integration_settings#update"
  put "integration_settings", to: "integration_settings#update"

  namespace :admin do
    get "dashboard/index"
    resource :droplet, only: %i[ create update ]
    resources :settings, only: %i[ index edit update ]
    resources :users
    resources :callbacks, only: %i[ index show edit update ] do
      post :sync, on: :collection
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
