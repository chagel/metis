require "test_helper"

class Connectors::XOauthControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "xo-#{SecureRandom.hex(4)}@example.com", password: "password123")
    sign_in @user
  end

  TOKENS = {
    "access_token" => "xat", "refresh_token" => "xrt", "expires_in" => 7200,
    "scope" => "tweet.read tweet.write users.read bookmark.read bookmark.write offline.access"
  }.freeze

  def with_config(&block)
    with_stub(XApp::Config, :configured?, ->(env: ENV) { true }) do
      with_stub(XApp::Config, :client_id, -> { "cid" }) do
        with_stub(XApp::Config, :redirect_uri, -> { "https://m/settings/connectors/x/callback" }, &block)
      end
    end
  end

  def start_flow
    with_config { post connector_x_authorize_path }
    Rack::Utils.parse_query(URI(response.location).query)["state"]
  end

  test "start redirects to X consent with PKCE and the exact scopes" do
    start_flow
    query = Rack::Utils.parse_query(URI(response.location).query)

    assert_response :redirect
    assert_match %r{\Ahttps://x\.com/i/oauth2/authorize}, response.location
    assert_equal "code", query["response_type"]
    assert_equal "cid", query["client_id"]
    assert_equal XApp::Config::SCOPES.join(" "), query["scope"]
    assert_equal "S256", query["code_challenge_method"]
    assert query["state"].present?
    assert query["code_challenge"].present?
  end

  test "start is refused when the deployment isn't configured" do
    post connector_x_authorize_path

    assert_redirected_to connectors_path
    assert_equal I18n.t("flash.connectors.x_oauth.unconfigured"), flash[:alert]
  end

  test "callback stores the grant and marks the connector connected" do
    state = start_flow

    with_config do
      with_stub(XApp::Oauth, :exchange, ->(**) { TOKENS.dup }) do
        get connector_x_callback_path(code: "abc", state: state)
      end
    end

    assert_redirected_to connectors_path
    grant = @user.oauth_grants.find_by(provider: "x")
    assert_equal "xat", grant.access_token
    assert_equal "xrt", grant.refresh_token
    assert grant.covers?(XApp::Config::SCOPES)

    connector = @user.personal_team.connectors.find_by(catalog_key: "x")
    assert_equal "http", connector.transport
    assert_equal({ "url" => "https://api.x.com/mcp" }, connector.definition)
    assert connector.connector_credentials.exists?(user: @user)
  end

  test "callback with a mismatched state never exchanges" do
    start_flow

    exchanged = false
    with_config do
      with_stub(XApp::Oauth, :exchange, ->(**) { exchanged = true; TOKENS.dup }) do
        get connector_x_callback_path(code: "abc", state: "wrong")
      end
    end

    assert_redirected_to connectors_path
    assert_not exchanged
    assert_nil @user.oauth_grants.find_by(provider: "x")
  end

  test "a replayed callback is rejected — state is one-time" do
    state = start_flow

    calls = 0
    with_config do
      with_stub(XApp::Oauth, :exchange, ->(**) { calls += 1; TOKENS.dup }) do
        get connector_x_callback_path(code: "abc", state: state)
        get connector_x_callback_path(code: "abc", state: state)
      end
    end

    assert_equal 1, calls
    assert_equal I18n.t("flash.connectors.x_oauth.expired"), flash[:alert]
  end

  test "an expired callback state never exchanges" do
    state = start_flow
    exchanged = false

    travel Connectors::XOauthController::STATE_TTL + 1.second do
      with_config do
        with_stub(XApp::Oauth, :exchange, ->(**) { exchanged = true; TOKENS.dup }) do
          get connector_x_callback_path(code: "abc", state: state)
        end
      end
    end

    assert_not exchanged
    assert_equal I18n.t("flash.connectors.x_oauth.expired"), flash[:alert]
  end

  test "consent denial consumes the state and keeps the prior grant" do
    @user.oauth_grants.create!(provider: "x", access_token: "prior", refresh_token: "prior-rt",
                               expires_at: 1.hour.from_now, scopes: "tweet.read")
    state = start_flow

    with_config { get connector_x_callback_path(error: "access_denied", state: state) }

    assert_equal I18n.t("flash.connectors.x_oauth.cancelled"), flash[:alert]
    assert_equal "prior", @user.oauth_grants.find_by(provider: "x").access_token
  end

  test "an exchange failure leaves no grant and shows a fixed localized error" do
    state = start_flow

    failing = ->(**) { raise XApp::Oauth::Error, "x oauth exchange status 400: invalid_request" }
    with_config do
      with_stub(XApp::Oauth, :exchange, failing) do
        get connector_x_callback_path(code: "abc", state: state)
      end
    end

    assert_redirected_to connectors_path
    assert_equal I18n.t("flash.connectors.x_oauth.failed"), flash[:alert]
    assert_nil @user.oauth_grants.find_by(provider: "x")
  end

  test "disconnect removes the grant, the presence marker, and an orphaned connector" do
    connector = @user.personal_team.connectors.create!(
      name: "x", transport: :http, catalog_key: "x", definition: { "url" => "https://api.x.com/mcp" }
    )
    connector.connector_credentials.create!(user: @user)
    @user.oauth_grants.create!(provider: "x", access_token: "xat", refresh_token: "xrt",
                               expires_at: 1.hour.from_now, scopes: "tweet.read")

    with_stub(XApp::Oauth, :revoke, ->(_token) { }) do
      delete connector_x_disconnect_path
    end

    assert_redirected_to connectors_path
    assert_nil @user.oauth_grants.find_by(provider: "x")
    assert_not Connector.exists?(connector.id)
  end

  test "disconnect keeps the team connector while another member still uses it" do
    team = Team.create!(name: "Shared")
    team.memberships.create!(user: @user, role: :owner)
    other = User.create!(email: "xo2-#{SecureRandom.hex(4)}@example.com", password: "password123")
    team.memberships.create!(user: other, role: :member)
    post switch_team_path(team)

    connector = team.connectors.create!(
      name: "x", transport: :http, catalog_key: "x", definition: { "url" => "https://api.x.com/mcp" }
    )
    connector.connector_credentials.create!(user: @user)
    connector.connector_credentials.create!(user: other)
    @user.oauth_grants.create!(provider: "x", access_token: "xat", refresh_token: "xrt",
                               expires_at: 1.hour.from_now, scopes: "tweet.read")

    with_stub(XApp::Oauth, :revoke, ->(_token) { }) do
      delete connector_x_disconnect_path
    end

    assert Connector.exists?(connector.id)
    assert_not connector.connector_credentials.exists?(user: @user)
    assert connector.connector_credentials.exists?(user: other)
  end
end
