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
    @custom = team.connectors.where(catalog_key: nil).order(:name)
  end

  # ?app=<key> opens the catalog connect form; without it, the custom-MCP form.
  def new
    if (@app = ConnectorCatalog.find(params[:app]))
      existing = team.connectors.find_by(catalog_key: @app.key)
      return redirect_to edit_connector_path(existing) if existing
      return redirect_to connectors_path if @app.oauth? # handled by Devise omniauth

      render :connect
    else
      @connector = team.connectors.new(transport: :stdio)
    end
  end

  def create
    if (app = ConnectorCatalog.find(params[:catalog_key]))
      connect_app(app)
    else
      create_custom
    end
  end

  def edit
    @app = @connector.catalog_app
    @credential = @connector.credential_for(current_user)
  end

  def update
    @connector.assign_attributes(custom_params) unless @connector.catalog_key
    apply_bot_setting
    if @connector.save
      save_credential
      redirect_to edit_connector_path(@connector), notice: "Connector saved."
    else
      @app = @connector.catalog_app
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

  def create_custom
    @connector = team.connectors.new(custom_params)
    if @connector.save
      redirect_to edit_connector_path(@connector), notice: "Connector created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def custom_params
    form = connector_form
    {
      name: form[:name], transport: form[:transport],
      definition: definition_from(form)
    }
  end

  def connector_form
    params.require(:connector).permit(:name, :transport, :command, :args, :url)
  end

  def definition_from(form)
    case form[:transport]
    when "stdio"
      { "command" => form[:command].to_s.strip,
        "args" => form[:args].to_s.split("\n").map(&:strip).reject(&:blank?) }
    when "http"
      { "url" => form[:url].to_s.strip }
    else
      {}
    end
  end

  # Admin toggle for the github_bot token (github connector only; no
  # param elsewhere). require_team_admin! already gates this action.
  def apply_bot_setting
    return unless params[:connector]&.key?(:bot_enabled)

    @connector.bot_enabled = ActiveModel::Type::Boolean.new.cast(params[:connector][:bot_enabled])
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
