require "test_helper"

class ConnectorsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "cc-#{SecureRandom.hex(4)}@example.com", password: "password123")
    sign_in @user
  end

  def team = @user.personal_team

  def github_connector
    team.connectors.create!(catalog_key: "github", name: "github",
                            transport: :http, definition: { "url" => "https://mcp.example/" })
  end

  test "the gallery lists catalog apps" do
    get connectors_path
    assert_response :success
    assert_select ".app-tile"
  end

  test "new with an oauth app redirects to the marketplace" do
    get new_connector_path(app: "github")
    assert_redirected_to connectors_path
  end

  test "the marketplace tile for github posts to the connector authorize URL with incremental scopes" do
    with_stub(GithubApp::Config, :configured?, -> { true }) do
      get connectors_path
      assert_response :success
      # The Connect button posts to the omniauth authorize URL with the
      # connector's required scopes appended + prompt=consent — the
      # incremental-scope flow that themis-style sign-up uses.
      assert_select %(form[action^="#{user_github_omniauth_authorize_path}"]) do |forms|
        action = forms.first[:action]
        assert_includes action, "connect=github"
        assert_includes action, "prompt=consent"
        assert_includes action, "include_granted_scopes=true"
        assert_match(/scope=[^&]*user(%3A|:)email/, action)
        assert_match(/scope=[^&]*repo/, action)
      end
    end
  end

  test "the marketplace does not show an oauth connect button when provider config is absent" do
    with_stub(GoogleApp::Config, :configured?, -> { false }) do
      get connectors_path
      assert_response :success

      assert_select %(form[action^="#{user_google_oauth2_omniauth_authorize_path}"]), false
      assert_select ".app-state", text: "OAuth — coming soon"
    end
  end

  test "oauth manage page explains missing provider config" do
    connector = github_connector

    with_stub(GithubApp::Config, :configured?, -> { false }) do
      get edit_connector_path(connector)
      assert_response :success

      assert_select ".conn-status-title", text: "GitHub OAuth is not configured"
      assert_select %(form[action^="#{user_github_omniauth_authorize_path}"]), false
    end
  end

  test "new with an already-connected app redirects to manage" do
    connector = github_connector
    get new_connector_path(app: "github")
    assert_redirected_to edit_connector_path(connector)
  end

  test "new without an app redirects to the marketplace" do
    get new_connector_path
    assert_redirected_to connectors_path
  end

  test "POSTing to connect an oauth app redirects to the marketplace" do
    assert_no_difference([ "Connector.count", "ConnectorCredential.count" ]) do
      post connectors_path, params: { catalog_key: "github", credential: "ghp_secret" }
    end

    assert_redirected_to connectors_path
  end

  test "posting without a catalog_key redirects to the marketplace" do
    assert_no_difference("Connector.count") do
      post connectors_path, params: { connector: { name: "fs", transport: "http" } }
    end
    assert_redirected_to connectors_path
  end

  test "the manage page renders for a connected app" do
    get edit_connector_path(github_connector)
    assert_response :success
  end

  test "updating an oauth app ignores any typed-in credential" do
    connector = github_connector
    patch connector_path(connector), params: { credential: "ghp_new" }

    assert_nil connector.credential_for(@user)
  end

  test "an admin can enable and disable the github bot on the connector" do
    connector = github_connector

    patch connector_path(connector), params: { connector: { bot_enabled: "1" } }
    assert connector.reload.bot_enabled?

    patch connector_path(connector), params: { connector: { bot_enabled: "0" } }
    assert_not connector.reload.bot_enabled?
  end

  test "an admin can pick which installation the bot acts through" do
    connector = github_connector

    patch connector_path(connector), params: { connector: { bot_enabled: "1", bot_installation_id: "139780379" } }
    assert_equal "139780379", connector.reload.bot_installation_id

    # No picker submitted (single-install App) clears the choice — back to
    # the deployment default.
    patch connector_path(connector), params: { connector: { bot_enabled: "1" } }
    assert_nil connector.reload.bot_installation_id
  end

  test "the manage page offers an installation picker when the App has several" do
    connector = github_connector
    connector.update!(bot_enabled: true)
    installs = [
      { "id" => "1", "login" => "chagel", "type" => "User" },
      { "id" => "2", "login" => "pipihosting", "type" => "Organization" }
    ]

    with_stub(GithubApp::Config, :app_auth_configured?, -> { true }) do
      with_stub(GithubApp::InstallationToken, :installations, -> { installs }) do
        get edit_connector_path(connector)
        assert_select %(select[name="connector[bot_installation_id]"] option), 3
      end

      with_stub(GithubApp::InstallationToken, :installations, -> { installs.take(1) }) do
        get edit_connector_path(connector)
        assert_select %(select[name="connector[bot_installation_id]"]), 0
      end
    end
  end

  test "the manage form's hidden companion disables the bot when the box is unchecked" do
    connector = github_connector
    connector.update!(bot_enabled: true)

    # An unchecked check_box_tag sends no "1"; the hidden field supplies "0".
    patch connector_path(connector), params: { connector: { bot_enabled: "0" } }
    assert_not connector.reload.bot_enabled?

    # Form rendering: the hidden companion is present so the param is never absent.
    with_stub(GithubApp::Config, :app_auth_configured?, -> { true }) do
      get edit_connector_path(connector)
      assert_select %(input[type=hidden][name="connector[bot_enabled]"][value="0"])
    end
  end

  test "disconnect removes the connector" do
    connector = github_connector
    assert_difference("Connector.count", -1) { delete connector_path(connector) }
  end

  test "another team's connector is out of scope" do
    other = Team.create!(name: "Other")
    connector = other.connectors.create!(name: "x", transport: :stdio, definition: { "command" => "npx" })

    get edit_connector_path(connector)
    assert_response :not_found
  end

  test "the github tile reads Connect when I have no credential, even if a teammate wired it" do
    github_connector # team Connector row exists; current user has no credential on it

    with_stub(GithubApp::Config, :configured?, -> { true }) do
      get connectors_path
      assert_select %(form[action^="#{user_github_omniauth_authorize_path}"] button), text: "Connect"
    end
  end

  test "the github tile reads Reconnect when I connected before but the grant lapsed" do
    github_connector.connector_credentials.create!(user: @user) # my credential exists, no usable grant

    with_stub(GithubApp::Config, :configured?, -> { true }) do
      get connectors_path
      assert_select %(form[action^="#{user_github_omniauth_authorize_path}"] button), text: "Reconnect"
    end
  end

  test "an mcp_oauth tile connects through the DCR flow, not omniauth" do
    get connectors_path
    assert_select %(form[action="#{connector_oauth_start_path("notion")}"] button), text: "Connect"
  end

  test "a per-instance mcp_oauth tile links to a form to collect the server URL" do
    get connectors_path
    assert_select %(a[href="#{new_connector_path(app: "metabase")}"]), text: "Connect"
  end

  test "the per-instance connect form posts the URL to the DCR flow" do
    get new_connector_path(app: "metabase")
    assert_response :success
    assert_select %(form[action="#{connector_oauth_start_path("metabase")}"])
    assert_select %(input[name="inputs[instance_url]"])
  end
end
