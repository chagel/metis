require "test_helper"

class Connectors::LinearOauthControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "lo-#{SecureRandom.hex(4)}@example.com", password: "password123")
    sign_in @user
    @connector = @user.personal_team.connectors.create!(name: "linear", transport: :http,
                                                        catalog_key: "linear",
                                                        definition: { "url" => "https://mcp.linear.app/mcp" })
  end

  def start_flow(&block)
    with_stub(LinearApp::Config, :configured?, -> { true }) do
      with_stub(LinearApp::Config, :client_id, -> { "cid" }, &block)
    end
  end

  test "start redirects to Linear consent" do
    start_flow { post connector_linear_authorize_path }

    assert_response :redirect
    assert_match %r{\Ahttps://linear\.app/oauth/authorize}, response.location
    assert_includes response.location, "client_id=cid"
  end

  test "start is refused when the deployment isn't configured" do
    with_stub(LinearApp::Config, :configured?, -> { false }) do
      post connector_linear_authorize_path
    end
    assert_redirected_to connectors_path
  end

  test "callback stores the api token and captures the workspace org id" do
    start_flow { post connector_linear_authorize_path }
    state = Rack::Utils.parse_query(URI(response.location).query)["state"]

    fake_api = Struct.new(:org) { def organization_id = org }.new("org-xyz")
    with_stub(Linear::Api, :new, ->(_token) { fake_api }) do
      with_stub(LinearApp::Oauth, :exchange, ->(**) { { "access_token" => "lin-tok" } }) do
        get connector_linear_callback_path(code: "abc", state: state)
      end
    end

    assert_redirected_to edit_connector_path(@connector)
    assert_equal "lin-tok", @connector.connector_credentials.find_by(user: @user).linear_api_bearer
    assert_equal "org-xyz", @connector.reload.linear_organization_id
  end

  test "callback with a mismatched state is rejected" do
    start_flow { post connector_linear_authorize_path }

    assert_no_changes -> { @connector.connector_credentials.count } do
      get connector_linear_callback_path(code: "abc", state: "wrong")
    end
    assert_redirected_to connectors_path
  end

  test "a non-admin member can't start the authorize flow" do
    team = Team.create!(name: "Shared")
    team.memberships.create!(user: User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com",
                                                password: "password123"), role: :owner)
    team.memberships.create!(user: @user, role: :member)
    post switch_team_path(team)

    start_flow { post connector_linear_authorize_path }

    assert_redirected_to team_path
    assert_equal I18n.t("flash.authorization.not_team_admin"), flash[:alert]
  end
end
