module LinearApp
  # Linear OAuth app credentials, per deployment via environment variables.
  # This is the *direct* Linear OAuth (linear.app/oauth) — separate from the
  # connector's MCP-OAuth: the MCP token only authenticates the MCP gateway,
  # whereas this token works against api.linear.app/graphql, which is what
  # the project picker needs. Read-only scope; webhooks stay manual.
  #
  #   LINEAR_CLIENT_ID      the OAuth app's client id
  #   LINEAR_CLIENT_SECRET  the OAuth app's client secret
  #
  # Register the app (and this callback URL) at
  # linear.app/settings/api/applications. See docs/connectors.md.
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
    end
  end
end
