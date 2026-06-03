require "test_helper"

class ConnectorCatalogTest < ActiveSupport::TestCase
  test "loads apps from the catalog yaml" do
    assert ConnectorCatalog.all.any?
    assert ConnectorCatalog.all.all? { |app| app.is_a?(ConnectorCatalog::App) }
  end

  test "find returns an app by key" do
    github = ConnectorCatalog.find("github")

    assert_equal "GitHub", github.name
    assert_equal "http", github.transport
    assert_equal "https://api.githubcopilot.com/mcp/", github.definition["url"]
    assert github.oauth?
    assert_equal "github", github.oauth_provider
  end

  test "find is nil for an unknown or blank key" do
    assert_nil ConnectorCatalog.find("nope")
    assert_nil ConnectorCatalog.find(nil)
  end

  test "by_category groups the apps" do
    assert_includes ConnectorCatalog.by_category.keys, "Development"
  end

  test "the Google connectors are cli-transport OAuth apps with no MCP definition" do
    %w[gmail google_calendar google_drive].each do |key|
      app = ConnectorCatalog.find(key)

      assert app, "expected catalog entry #{key.inspect}"
      assert_equal "cli", app.transport,
        "#{key} should be cli-transport (reached via the gws CLI, not an MCP server)"
      assert app.oauth?, "#{key} should authenticate via OAuth"
      assert_equal "google", app.oauth_provider
      assert_empty app.definition,
        "#{key} should not declare an MCP server definition"
      assert_nil app.credential,
        "#{key} should not declare a credential map (token flows through GOOGLE_WORKSPACE_CLI_TOKEN)"
      assert app.oauth_scopes.any?, "#{key} should declare oauth scopes for the consent screen"
    end
  end

  test "google_calendar advertises read/write calendar scopes" do
    calendar = ConnectorCatalog.find("google_calendar")

    assert_equal "Google Calendar", calendar.name
    assert_includes calendar.oauth_scopes, "https://www.googleapis.com/auth/calendar"
    assert_includes calendar.oauth_scopes, "https://www.googleapis.com/auth/calendar.events"
  end

  test "every mcp_oauth app is an http connector with a server URL and no brokered provider" do
    mcp_oauth = ConnectorCatalog.all.select(&:mcp_oauth?)

    assert mcp_oauth.any?, "expected at least one mcp_oauth connector"
    mcp_oauth.each do |app|
      assert_equal "http", app.transport, "#{app.key} must be http-transport"
      assert app.definition["url"].present?, "#{app.key} must declare a server URL"
      assert_nil app.oauth_provider, "#{app.key} is DCR — it must not pin a brokered provider"
    end
  end

  test "the DCR-connected popular servers are present" do
    %w[notion monday stripe close sentry asana paypal linear].each do |key|
      assert ConnectorCatalog.find(key)&.mcp_oauth?, "expected mcp_oauth catalog entry #{key.inspect}"
    end
  end

  test "metabase is a per-instance mcp_oauth connector with a URL placeholder + input" do
    metabase = ConnectorCatalog.find("metabase")

    assert metabase.mcp_oauth?
    assert_includes metabase.definition["url"], "%{instance_url}"
    assert_equal "instance_url", metabase.inputs.first["key"]
    # The placeholder resolves from the input.
    assert_equal "https://mb.test/api/mcp",
                 metabase.resolved_definition("instance_url" => "https://mb.test")["url"]
  end
end
