module LinearApp
  # Linear OAuth app credentials, per deployment via env vars. This is the
  # *direct* Linear OAuth (linear.app/oauth), separate from the connector's
  # MCP-OAuth: the MCP token only authenticates the MCP gateway, whereas this
  # token works against api.linear.app/graphql — what the project picker
  # needs, and the same app whose webhook feeds the activity feed. Register it
  # at linear.app/settings/api/applications; see docs/connectors.md.
  class Config
    AUTHORIZE_URL = "https://linear.app/oauth/authorize".freeze
    TOKEN_URL = "https://api.linear.app/oauth/token".freeze
    SCOPE = "read".freeze

    class << self
      def client_id
        ENV["LINEAR_CLIENT_ID"].presence
      end

      def client_secret
        ENV["LINEAR_CLIENT_SECRET"].presence
      end

      def configured?
        client_id.present? && client_secret.present?
      end

      # The app's webhook signing secret (the lin_wh_… on its settings page);
      # blank → Webhooks::LinearController refuses every delivery.
      def webhook_secret
        ENV["LINEAR_WEBHOOK_SECRET"].presence
      end
    end
  end
end
