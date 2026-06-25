# One configured MCP server, owned by a team. Each connector becomes a
# `mcpServers` entry in the `.mcp.json` the runtime stages for a turn;
# pi-mcp-adapter then exposes its tools to the agent. The non-secret
# server definition lives here; secrets are separate
# ConnectorCredentials, shared or per-member. See docs/connectors.md.
class Connector < ApplicationRecord
  belongs_to :team
  has_many :connector_credentials, dependent: :destroy

  # stdio — a `command` server entry; http — a `url` server entry;
  # cli — no MCP entry at all (the agent reaches the service through a
  # CLI on PATH, authorised by Runtime::Base#sandbox_env). cli connectors
  # are catalog-only — they exist as marketplace tiles and OAuth-grant
  # markers, and McpConfig skips them when rendering .mcp.json.
  enum :transport, { stdio: 0, http: 1, cli: 2 }

  # Admin opt-in for the github_bot installation token, off by default —
  # it's installation-wide and shared team-wide, so staging it is a
  # deliberate choice, not a deployment default. bot_installation_id picks
  # which installation the bot acts through when the App has several
  # (nil → GITHUB_APP_INSTALLATION_ID, else the App's sole install).
  # linear_webhook_token is the per-connector routing id baked into the
  # inbound Linear webhook URL — non-secret (the signing secret authes),
  # it just maps a delivery back to this connector. See docs/connectors.md.
  store_accessor :settings, :bot_enabled, :bot_installation_id, :linear_webhook_token

  # The linear connector an inbound webhook delivery routes to, by the
  # opaque token in its URL path. Unlike GitHub (one deployment-wide App
  # webhook resolved by installation id), each team's Linear webhook is
  # its own — the token is how Webhooks::LinearController finds it.
  scope :for_linear_webhook, ->(token) {
    where(catalog_key: "linear").where("settings ->> 'linear_webhook_token' = ?", token.to_s)
  }

  validates :name, presence: true,
                    format: { with: /\A[a-z0-9][a-z0-9_-]*\z/i },
                    uniqueness: { scope: :team_id }
  validates :transport, presence: true
  validate :definition_matches_transport

  def bot_enabled?
    ActiveModel::Type::Boolean.new.cast(bot_enabled)
  end

  # Mint the webhook routing token on first setup, idempotent thereafter.
  def ensure_linear_webhook_token!
    return linear_webhook_token if linear_webhook_token.present?

    update!(linear_webhook_token: SecureRandom.urlsafe_base64(24))
    linear_webhook_token
  end

  # The Linear webhook signing secret lives on the team's shared (no-user)
  # credential — it's encrypted there and team-wide, like the webhook
  # itself. The per-member mcp_oauth tokens are a separate axis.
  def linear_webhook_secret
    connector_credentials.find_by(user: nil)&.linear_webhook_secret
  end

  def store_linear_webhook_secret!(secret)
    credential = connector_credentials.find_or_initialize_by(user: nil)
    credential.linear_webhook_secret = secret
    credential.save!
  end

  # The credential a given member connects with: their own if set, else
  # the team's shared credential, else nil.
  def credential_for(user)
    connector_credentials.find_by(user: user) || connector_credentials.find_by(user: nil)
  end

  # The marketplace app this connector was created from, or nil for a
  # custom connector. See ConnectorCatalog, docs/connectors.md.
  def catalog_app
    ConnectorCatalog.find(catalog_key)
  end

  private

  # A stdio server entry needs a command; an http one needs a url; a
  # cli one has no MCP server entry at all (definition is unused).
  def definition_matches_transport
    return unless transport
    return if cli?

    required = stdio? ? "command" : "url"
    return if definition[required].present?

    errors.add(:definition, :missing_field, required: required, transport: transport)
  end
end
