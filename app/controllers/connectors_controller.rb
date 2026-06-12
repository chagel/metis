class ConnectorsController < ApplicationController
  layout "settings"

  before_action :set_connector, only: %i[edit update destroy]
  # Members connect their own account to a team connector (OAuth, handled
  # outside this controller); only admins add, configure, or remove the
  # team's connectors.
  before_action :require_team_admin!, only: %i[new create edit update destroy]

  def index
    @apps = ConnectorCatalog.all
    @connected = team.connectors.where.not(catalog_key: nil).index_by(&:catalog_key)
  end

  # ?app=<key> opens the catalog connect form.
  def new
    @app = ConnectorCatalog.find(params[:app])
    return redirect_to connectors_path unless @app

    existing = team.connectors.find_by(catalog_key: @app.key)
    # mcp_oauth re-renders the connect form even when already connected,
    # so a reconnect can re-run the OAuth flow; others jump to manage.
    return redirect_to edit_connector_path(existing) if existing && !@app.mcp_oauth?
    return redirect_to connectors_path if @app.oauth? # handled by Devise omniauth

    render :connect
  end

  def create
    app = ConnectorCatalog.find(params[:catalog_key])
    return redirect_to connectors_path unless app

    connect_app(app)
  end

  def edit
    @app = @connector.catalog_app
    @credential = @connector.credential_for(current_user)
    @installations = bot_installations
  end

  def update
    apply_bot_setting
    if @connector.save
      save_credential
      redirect_to edit_connector_path(@connector), notice: "Connector saved."
    else
      @app = @connector.catalog_app
      @installations = bot_installations
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    app = @connector.catalog_app
    @connector.destroy
    prune_or_revoke_oauth_grant(app) if app&.oauth?
    redirect_to connectors_path, notice: "#{@connector.name} disconnected."
  end

  private

  def team
    current_team
  end

  def set_connector
    @connector = team.connectors.find(params[:id])
  end

  def connect_app(app)
    return redirect_to(connectors_path) if app.oauth?

    connector = team.connectors.find_or_initialize_by(catalog_key: app.key)
    connector.update!(
      name: app.key, transport: app.transport,
      definition: app.resolved_definition(input_params(app))
    )
    save_app_credential(connector, app)
    redirect_to edit_connector_path(connector), notice: "#{app.name} connected."
  end

  def input_params(app)
    params.fetch(:inputs, {}).permit(*app.inputs.map { |input| input["key"] }).to_h
  end

  def save_app_credential(connector, app)
    secret = params[:credential]
    return if secret.blank? || app.credential.blank?

    credential = connector.connector_credentials.find_or_initialize_by(user: current_user)
    credential.update!(credential_map: app.credential_map_for(secret))
  end

  # Admin toggle for the github_bot token (github connector only; no
  # param elsewhere). require_team_admin! already gates this action.
  # The installation choice rides along: absent or blank clears it, so
  # the bot falls back to the deployment default.
  def apply_bot_setting
    return unless params[:connector]&.key?(:bot_enabled)

    @connector.bot_enabled = ActiveModel::Type::Boolean.new.cast(params[:connector][:bot_enabled])
    @connector.bot_installation_id = params[:connector][:bot_installation_id].presence
  end

  # Installations for the manage page's bot picker. A GitHub blip hides
  # the picker rather than breaking the page.
  def bot_installations
    return [] unless @connector.catalog_app&.oauth_provider == "github"
    return [] unless GithubApp::Config.app_auth_configured?

    GithubApp::InstallationToken.installations
  rescue GithubApp::InstallationToken::Error
    []
  end

  # OAuth-shaped apps own credentials through the connect flow — never accept
  # a typed-in secret for them.
  def save_credential
    app = @connector.catalog_app
    return unless app && app.token_auth? && params[:credential].present?

    credential = @connector.connector_credentials.find_or_initialize_by(user: current_user)
    credential.update!(credential_map: app.credential_map_for(params[:credential]))
  end

  # Revoke + destroy only when the user's last OAuth connector for this provider
  # is gone — otherwise the next connect would silently skip the consent screen
  # (Google downgrades prompt=consent to prompt=none when a grant exists). We
  # don't prune scopes either: Google's revoke is all-or-nothing, so the local
  # scope set must mirror what they actually hold.
  def prune_or_revoke_oauth_grant(app)
    grant = current_user.oauth_grants.find_by(provider: app.oauth_provider)
    return unless grant
    return if active_connectors_for?(app.oauth_provider)

    OauthBroker.revoke(grant)
    grant.destroy
  end

  def active_connectors_for?(provider)
    catalog_keys = ConnectorCatalog.all.select { |a| a.oauth_provider == provider }.map(&:key)
    current_user.connector_credentials
                .joins(:connector)
                .where(connectors: { catalog_key: catalog_keys })
                .exists?
  end
end
