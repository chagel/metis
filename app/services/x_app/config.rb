module XApp
  # X OAuth 2.0 app credentials, per deployment: ENV first (X_CLIENT_ID,
  # X_CLIENT_SECRET, X_REDIRECT_URI), then Rails credentials (x.client_id,
  # x.client_secret, x.redirect_uri), resolved per key. The redirect URI is
  # configured rather than derived from routes because X rejects any
  # callback that doesn't exactly match the app's registered URI. Register
  # the app at https://developer.x.com; see docs/connectors.md.
  class Config
    SCOPES = %w[tweet.read tweet.write users.read bookmark.read bookmark.write offline.access].freeze
    KEYS = { client_id: "X_CLIENT_ID", client_secret: "X_CLIENT_SECRET", redirect_uri: "X_REDIRECT_URI" }.freeze

    class << self
      def client_id(env: ENV) = resolve(:client_id, env)

      def client_secret(env: ENV) = resolve(:client_secret, env)

      def redirect_uri(env: ENV) = resolve(:redirect_uri, env)

      def configured?(env: ENV) = missing_keys(env: env).empty?

      # The ENV names of the keys with no effective value — what the
      # doctor prints. Names only, never values.
      def missing_keys(env: ENV)
        KEYS.filter_map { |key, var| var if resolve(key, env).blank? }
      end

      private

      def resolve(key, env)
        env[KEYS.fetch(key)].presence || Rails.application.credentials.dig(:x, key).presence
      end
    end
  end
end
