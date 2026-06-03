require "test_helper"

class Agent::McpConfigTest < ActiveSupport::TestCase
  def conversation
    @conversation ||= begin
      user = User.create!(email: "mcp-#{SecureRandom.hex(4)}@example.com", password: "password123")
      user.conversations.create!
    end
  end

  def team = conversation.team

  def member = conversation.user

  def add_connector(**attrs)
    team.connectors.create!({
      name: "filesystem", transport: :stdio, definition: { "command" => "npx" }
    }.merge(attrs))
  end

  def rendered
    JSON.parse(Agent::McpConfig.new(conversation).content)
  end

  test "renders an empty mcpServers map when the team has no connectors" do
    assert_equal({ "mcpServers" => {} }, rendered)
  end

  test "renders a no-credential connector as its definition unchanged" do
    add_connector(name: "fs", definition: { "command" => "npx", "args" => [ "-y", "x" ] })

    assert_equal({ "command" => "npx", "args" => [ "-y", "x" ] }, rendered["mcpServers"]["fs"])
  end

  test "merges the member's own credential into a stdio connector's env" do
    connector = add_connector(name: "fs", definition: { "command" => "npx" })
    connector.connector_credentials.create!(user: member, credential_map: { "API_KEY" => "mine" })

    assert_equal({ "API_KEY" => "mine" }, rendered["mcpServers"]["fs"]["env"])
  end

  test "merges a credential into an http connector's headers" do
    connector = add_connector(name: "gh", transport: :http,
                              definition: { "url" => "https://mcp.example/" })
    connector.connector_credentials.create!(user: nil, credential_map: { "Authorization" => "Bearer t" })

    assert_equal({ "Authorization" => "Bearer t" }, rendered["mcpServers"]["gh"]["headers"])
  end

  test "falls back to the team's shared credential" do
    connector = add_connector(name: "fs", definition: { "command" => "npx" })
    connector.connector_credentials.create!(user: nil, credential_map: { "API_KEY" => "shared" })

    assert_equal({ "API_KEY" => "shared" }, rendered["mcpServers"]["fs"]["env"])
  end

  test "the member's own credential wins over the shared one" do
    connector = add_connector(name: "fs", definition: { "command" => "npx" })
    connector.connector_credentials.create!(user: nil, credential_map: { "API_KEY" => "shared" })
    connector.connector_credentials.create!(user: member, credential_map: { "API_KEY" => "mine" })

    assert_equal({ "API_KEY" => "mine" }, rendered["mcpServers"]["fs"]["env"])
  end

  test "omits a connector the member has no credential for" do
    connector = add_connector(name: "github", transport: :http,
                              definition: { "url" => "https://mcp.example/" })
    other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: "password123")
    connector.connector_credentials.create!(user: other, credential_map: { "T" => "x" })

    assert_equal [], rendered["mcpServers"].keys
  end

  test "an oauth credential projects its grant's live access token as a bearer header" do
    connector = add_connector(name: "github", transport: :http,
                              definition: { "url" => "https://mcp.example/" },
                              catalog_key: "github")
    connector.connector_credentials.create!(user: member)
    member.oauth_grants.create!(
      provider: "github", access_token: "live", refresh_token: "rt",
      expires_at: 1.hour.from_now, scopes: "repo read:user user:email"
    )

    assert_equal({ "Authorization" => "Bearer live" }, rendered["mcpServers"]["github"]["headers"])
  end

  test "an oauth connector is omitted when its refresh fails" do
    connector = add_connector(name: "github", transport: :http,
                              definition: { "url" => "https://mcp.example/" },
                              catalog_key: "github")
    connector.connector_credentials.create!(user: member)
    member.oauth_grants.create!(
      provider: "github", access_token: "expired", refresh_token: "rt",
      expires_at: 10.seconds.ago, scopes: "repo read:user user:email"
    )

    with_stub(GithubApp::OauthClient, :refresh, ->(_) { raise OauthBroker::Error, "boom" }) do
      assert_equal [], rendered["mcpServers"].keys
    end
  end

  test "an oauth connector with no grant for the user is dropped" do
    connector = add_connector(name: "github", transport: :http,
                              definition: { "url" => "https://mcp.example/" },
                              catalog_key: "github")
    connector.connector_credentials.create!(user: member)
    # No OauthGrant for this user — they never completed the connect flow.

    assert_equal [], rendered["mcpServers"].keys
  end

  test "a scope-meaningful oauth connector whose grant lacks required scopes is dropped" do
    # Gmail (Google) uses classic OAuth — scope coverage is enforced.
    # An incomplete grant must drop the connector from .mcp.json so
    # the agent doesn't try gmail.send with only gmail.readonly.
    connector = add_connector(name: "gmail", transport: :http,
                              definition: { "url" => "https://mcp.example/" },
                              catalog_key: "gmail")
    connector.connector_credentials.create!(user: member)
    member.oauth_grants.create!(
      provider: "google", access_token: "live", refresh_token: "rt",
      expires_at: 1.hour.from_now, scopes: "email" # missing gmail.* scopes
    )

    assert_equal [], rendered["mcpServers"].keys
  end

  test "a GitHub oauth connector with empty grant scopes is still staged (App OAuth)" do
    # GitHub Apps don't echo OAuth scopes in their OAuth response, so
    # grant.scopes is empty for every legitimately-connected user.
    # Old gate ("covers?(repo, read:user)") would drop every GitHub
    # connector from every turn forever; new gate is grant + token.
    connector = add_connector(name: "github", transport: :http,
                              definition: { "url" => "https://mcp.example/" },
                              catalog_key: "github")
    connector.connector_credentials.create!(user: member)
    member.oauth_grants.create!(
      provider: "github", access_token: "ghu_live", refresh_token: "rt",
      expires_at: 1.hour.from_now, scopes: nil
    )

    assert_includes rendered["mcpServers"].keys, "github"
    assert_equal({ "Authorization" => "Bearer ghu_live" }, rendered["mcpServers"]["github"]["headers"])
  end

  test "cli-transport connectors are never staged in .mcp.json" do
    # The Google connectors (gmail/google_calendar/google_drive) are
    # reached through the gws CLI, not an MCP server. Even with a
    # valid OAuth grant on file they must not show up in mcpServers.
    connector = add_connector(name: "gmail", transport: :cli,
                              catalog_key: "gmail", definition: {})
    connector.connector_credentials.create!(user: member)
    member.oauth_grants.create!(
      provider: "google", access_token: "ya29.live", refresh_token: "rt",
      expires_at: 1.hour.from_now,
      scopes: "https://www.googleapis.com/auth/gmail.readonly " \
              "https://www.googleapis.com/auth/gmail.labels " \
              "https://www.googleapis.com/auth/gmail.modify " \
              "https://www.googleapis.com/auth/gmail.compose"
    )

    assert_equal({ "mcpServers" => {} }, rendered)
  end

  test "an oauth credential whose catalog entry has gone missing is dropped" do
    connector = add_connector(name: "ghost", transport: :http,
                              definition: { "url" => "https://mcp.example/" },
                              catalog_key: "nope-removed")
    connector.connector_credentials.create!(user: member)

    assert_equal [], rendered["mcpServers"].keys,
                 "connector with no catalog entry must be dropped, not rendered without auth"
  end

  # A second `github_bot` server (installation token) is staged next to
  # the user's own `github` server when the deployment is App-auth
  # configured AND an admin has turned the bot on for the connector, so
  # the agent can act as the bot for PR reviews.
  def add_github_connector(bot_enabled: true)
    connector = add_connector(name: "github", transport: :http,
                              definition: { "url" => "https://mcp.example/" }, catalog_key: "github")
    connector.update!(bot_enabled: bot_enabled)
    connector
  end

  test "stages a github_bot server with a minted installation token when configured and enabled" do
    add_github_connector
    with_stub(GithubApp::Config, :app_auth_configured?, -> { true }) do
      with_stub(GithubApp::InstallationToken, :for, ->(id = nil) { "ghs_bot" }) do
        assert_equal({ "Authorization" => "Bearer ghs_bot" },
                     rendered["mcpServers"]["github_bot"]["headers"])
      end
    end
  end

  test "no github_bot server when the connector has not enabled the bot" do
    add_github_connector(bot_enabled: false)
    with_stub(GithubApp::Config, :app_auth_configured?, -> { true }) do
      with_stub(GithubApp::InstallationToken, :for, ->(id = nil) { "ghs_bot" }) do
        assert_not_includes rendered["mcpServers"].keys, "github_bot"
      end
    end
  end

  test "no github_bot server when the deployment lacks App auth" do
    add_github_connector
    with_stub(GithubApp::Config, :app_auth_configured?, -> { false }) do
      assert_not_includes rendered["mcpServers"].keys, "github_bot"
    end
  end

  test "no github_bot server when the team has no github connector" do
    add_connector(name: "fs", definition: { "command" => "npx" })
    with_stub(GithubApp::Config, :app_auth_configured?, -> { true }) do
      assert_not_includes rendered["mcpServers"].keys, "github_bot"
    end
  end

  test "the github_bot server is omitted when minting fails" do
    add_github_connector
    failing = ->(_id = nil) { raise GithubApp::InstallationToken::Error, "no install" }
    with_stub(GithubApp::Config, :app_auth_configured?, -> { true }) do
      with_stub(GithubApp::InstallationToken, :for, failing) do
        assert_not_includes rendered["mcpServers"].keys, "github_bot"
      end
    end
  end
end
