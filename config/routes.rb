Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Dynamic endpoint replay service — consumer-facing read-only JSON API.
  # Each slug maps to a persisted, LLM-validated mruby script replayed on demand.
  # Must be declared before resources :endpoints to avoid slug/id route collision.
  get "e/:slug", to: "dynamic_endpoints#show", as: :dynamic_endpoint

  # Operator-facing generation UI (Hotwire).
  # index lists the live endpoints (the demo's "these are on the air now" view);
  # new/create drive generation; show tracks one generation attempt.
  # No edit or delete: endpoints are immutable once validated and live.
  resources :endpoints, only: %i[index new create show]

  # Root → generation form.
  root "endpoints#new"

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end
