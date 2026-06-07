Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  devise_for :users, controllers: {
    omniauth_callbacks: "users/omniauth_callbacks",
    registrations: "users/registrations"
  }

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
    end
    resources :messages, only: :create do
      member { post :fork }
    end
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
    resource :profile, only: %i[show update]

    post  "profile/detect_timezone", to: "profiles#detect_timezone", as: :detect_timezone_profile
    patch "profile/theme",           to: "profiles#update_theme",    as: :update_theme_profile
    patch "profile/avatar",          to: "profiles#update_avatar",   as: :update_avatar_profile

    resources :connectors, except: :show
    get  "connectors/oauth/callback",     to: "connectors/oauth#callback", as: :connector_oauth_callback
    post "connectors/oauth/:catalog_key", to: "connectors/oauth#start",    as: :connector_oauth_start

    resources :projects, except: :show

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

  root "conversations#index"
end
