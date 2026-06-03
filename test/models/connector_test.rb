require "test_helper"

class ConnectorTest < ActiveSupport::TestCase
  def team
    @team ||= Team.create!(name: "Acme")
  end

  def make_user
    User.create!(email: "cn-#{SecureRandom.hex(4)}@example.com", password: "password123")
  end

  # A valid stdio connector, with overrides merged in.
  def stdio_connector(**attrs)
    Connector.new({
      team: team, name: "filesystem", transport: :stdio,
      definition: { "command" => "npx", "args" => [ "-y", "server-filesystem" ] }
    }.merge(attrs))
  end

  test "a valid stdio connector saves" do
    assert stdio_connector.save
  end

  test "a valid http connector saves" do
    assert Connector.new(team: team, name: "github", transport: :http,
                         definition: { "url" => "https://mcp.example/" }).save
  end

  test "name is required" do
    assert_not stdio_connector(name: nil).valid?
  end

  test "name must be a safe identifier" do
    assert_not stdio_connector(name: "bad name!").valid?
    assert stdio_connector(name: "metabase-prod").valid?
  end

  test "name is unique per team" do
    stdio_connector.save!
    assert_not stdio_connector.valid?
  end

  test "the same name is allowed for a different team" do
    stdio_connector.save!
    other = Team.create!(name: "Other")
    assert Connector.new(team: other, name: "filesystem", transport: :stdio,
                         definition: { "command" => "npx" }).valid?
  end

  test "transport is required" do
    connector = stdio_connector
    connector.transport = nil
    assert_not connector.valid?
  end

  test "a stdio connector needs a command in its definition" do
    assert_not stdio_connector(definition: { "args" => [] }).valid?
  end

  test "an http connector needs a url in its definition" do
    assert_not Connector.new(team: team, name: "x", transport: :http, definition: {}).valid?
  end

  test "a cli connector saves with an empty definition (no MCP server to validate)" do
    # CLI connectors (Gmail, Calendar, Drive via gws) skip the
    # definition-shape check entirely — they don't render into
    # .mcp.json at all.
    assert Connector.new(team: team, name: "gmail", transport: :cli,
                          catalog_key: "gmail", definition: {}).valid?
  end

  test "credential_for prefers the member's own credential over the shared one" do
    connector = stdio_connector
    connector.save!
    user = make_user
    connector.connector_credentials.create!(user: nil)
    own = connector.connector_credentials.create!(user: user)

    assert_equal own, connector.credential_for(user)
  end

  test "credential_for falls back to the team's shared credential" do
    connector = stdio_connector
    connector.save!
    shared = connector.connector_credentials.create!(user: nil)

    assert_equal shared, connector.credential_for(make_user)
  end

  test "credential_for is nil when neither own nor shared exists" do
    connector = stdio_connector
    connector.save!

    assert_nil connector.credential_for(make_user)
  end

  test "destroying a connector destroys its credentials" do
    connector = stdio_connector
    connector.save!
    connector.connector_credentials.create!(user: nil)

    assert_difference("ConnectorCredential.count", -1) { connector.destroy }
  end

  test "bot_enabled? is false by default and coerces stored values" do
    connector = stdio_connector

    assert_not connector.bot_enabled?

    connector.bot_enabled = "1"
    assert connector.bot_enabled?

    connector.bot_enabled = "0"
    assert_not connector.bot_enabled?
  end
end
