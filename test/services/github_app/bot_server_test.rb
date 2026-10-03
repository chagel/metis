require "test_helper"

class GithubApp::BotServerTest < ActiveSupport::TestCase
  def team
    @team ||= User.create!(email: "bot-#{SecureRandom.hex(4)}@example.com", password: "password123").personal_team
  end

  def add_github_connector(bot_enabled: true)
    team.connectors.create!(name: "github", transport: :http, catalog_key: "github",
                            definition: { "url" => "https://mcp.example/" }, bot_enabled: bot_enabled)
  end

  def server
    GithubApp::BotServer.for(team.connectors.to_a)
  end

  def with_app_auth(configured: true, mint: ->(id = nil) { "ghs_bot" })
    with_stub(GithubApp::Config, :app_auth_configured?, -> { configured }) do
      with_stub(GithubApp::InstallationToken, :for, mint) { yield }
    end
  end

  test "stages github_bot with a minted installation token and its description" do
    add_github_connector
    with_app_auth do
      name, entry = server

      assert_equal "github_bot", name
      assert_equal({ "Authorization" => "Bearer ghs_bot" }, entry["headers"])
      assert_equal GithubApp::BotServer::DESCRIPTION, entry["description"]
    end
  end

  test "mints the token for the connector's chosen installation" do
    add_github_connector.update!(bot_installation_id: "777")
    minted_for = :unset
    with_app_auth(mint: ->(id = nil) { minted_for = id; "ghs_bot" }) { server }

    assert_equal "777", minted_for
  end

  test "nil when the connector has not enabled the bot" do
    add_github_connector(bot_enabled: false)
    with_app_auth { assert_nil server }
  end

  test "nil when the deployment lacks App auth" do
    add_github_connector
    with_app_auth(configured: false) { assert_nil server }
  end

  test "nil when the team has no github connector" do
    team.connectors.create!(name: "fs", transport: :stdio, definition: { "command" => "npx" })
    with_app_auth { assert_nil server }
  end

  test "nil when minting fails" do
    add_github_connector
    with_app_auth(mint: ->(_id = nil) { raise GithubApp::InstallationToken::Error, "no install" }) do
      assert_nil server
    end
  end
end
