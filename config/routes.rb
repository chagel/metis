Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "configurations/ios_v1" => "hotwire/path_configurations#ios", as: :hotwire_ios_path_configuration

  devise_for :users, controllers: {
    omniauth_callbacks: "users/omniauth_callbacks",
    registrations: "users/registrations"
  }
  # Native Google sign-in: Google blocks OAuth inside webviews, so the
  # iOS app runs Google Sign-In natively and posts the ID token here.
  post "users/auth/google/native", to: "users/native_auth#google", as: :google_native_auth

  resources :conversations, only: %i[index create show update] do
    collection do
      get :archived
    end
    member do
      post :cancel
      post :archive
      post :unarchive
      post :star
      delete :star, action: :unstar
      post :share
      delete :share, action: :unshare
      patch :visibility, action: :toggle_visibility
    end
    resources :messages, only: :create do
      member { post :fork }
    end
  end

  get "board", to: "board#index"
  get "board/actors", to: "board#actors", as: :board_actors

  # Top-level workspace surface (promoted out of /settings): index + a
  # read-only project dashboard are team-visible; create/edit/destroy
  # stay admin-gated in the controller.
  resources :projects do
    # On-demand list of the team's Linear projects (via the operator's
    # connector token) to populate the project-form picker.
    get :linear_projects, on: :collection
  end

  resources :workflow_runs, only: %i[create] do
    member do
      post :start
      post :approve
      post :reject
      post :request_changes
    end
    post "tasks/:id/claim", to: "workflow_runs#claim", as: :claim_run_task
  end

  resources :teams, only: %i[new create] do
    member { post :switch }
  end

  resources :invitations, only: %i[show], param: :token do
    member { post :accept }
  end

  get "/share/:token", to: "shared_conversations#show", as: :shared_conversation
  get "/artifacts/:signed_id/preview", to: "artifact_previews#show", as: :artifact_preview

  get "/settings", to: redirect("/settings/profile")
  scope "/settings", as: nil do
    resource :team, only: %i[show update destroy], controller: "settings/teams" do
      resources :invitations, only: %i[create destroy], controller: "settings/invitations" do
        member { post :resend }
      end

      resources :memberships, only: %i[update destroy], controller: "settings/memberships" do
        member { post :transfer }
        collection { delete :leave }
      end
    end

    resource :account, only: %i[show update destroy], controller: "settings/accounts"
    resource :developer, only: %i[show], controller: "settings/developer"
    post  "developer/bridge_token", to: "settings/developer#bridge_token", as: :developer_bridge_token
    patch "developer/bridge_prefs", to: "settings/developer#bridge_prefs", as: :developer_bridge_prefs
    resource :profile, only: %i[show update]

    post  "profile/detect_timezone", to: "profiles#detect_timezone", as: :detect_timezone_profile
    patch "profile/theme",           to: "profiles#update_theme",    as: :update_theme_profile
    patch "profile/avatar",          to: "profiles#update_avatar",   as: :update_avatar_profile

    resources :connectors, except: :show
    get  "connectors/oauth/callback",     to: "connectors/oauth#callback", as: :connector_oauth_callback
    post "connectors/oauth/:catalog_key", to: "connectors/oauth#start",    as: :connector_oauth_start
    # Direct Linear OAuth — an api.linear.app token for the project picker,
    # distinct from the connector's MCP-OAuth.
    post "connectors/linear/authorize",   to: "connectors/linear_oauth#start",    as: :connector_linear_authorize
    get  "connectors/linear/callback",    to: "connectors/linear_oauth#callback", as: :connector_linear_callback

    resources :workflows, except: :show

    resources :routines, except: :show do
      member do
        patch :toggle
        post  :run
      end
    end

    get   "models",                   to: "models#index",           as: :models
    post  "models/refresh",           to: "models#refresh",         as: :refresh_models
    patch "models/providers/:id",     to: "models#update_provider", as: :model_provider
    patch "models/items/:id",         to: "models#update_model",    as: :model_item

    resources :skills, except: :show do
      collection do
        get  "import", action: :import_form, as: :import_form
        post "import", action: :import,       as: :import
      end
      member do
        post   "files",                   action: :add_file,      as: :add_file
        delete "files/:file_id",          action: :destroy_file,  as: :destroy_file
        get    "files/:file_id/download", action: :download_file, as: :download_file
      end
    end
  end

  # Bridge pull API — a local agent claims delegated workflow steps and
  # reports results (docs/local-bridge.md). Authed by the user's bridge
  # token, not a session.
  namespace :api do
    namespace :bridge do
      get  "tasks",            to: "tasks#index"
      get  "tasks/next",       to: "tasks#claim"
      get  "tasks/:id",        to: "tasks#show"
      post "tasks/:id/events", to: "tasks#events"
      post "tasks/:id/result", to: "tasks#result"
      post "mcp",              to: "mcp#handle"
      get  "skill",            to: "skill#show"
    end
  end

  # Single inbound endpoint per provider for the deployment's GitHub App /
  # Linear connector. HMAC-authed, session-less (docs/workflows.md Phase 4).
  namespace :webhooks do
    post "github", to: "github#create"
    # One endpoint for the deployment's Linear OAuth app; the app's signing
    # secret authes, the payload's organizationId resolves the team.
    post "linear", to: "linear#create"
  end

  root "conversations#index"
end
