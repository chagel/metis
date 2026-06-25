require "net/http"
require "json"

module LinearApp
  # The authorization-code dance for the direct Linear OAuth app: build the
  # consent URL, exchange the returned code for tokens, and refresh them.
  # Linear access tokens expire in 24h and the exchange returns a
  # refresh_token, so ConnectorCredential refreshes before use. See
  # Connectors::LinearOauthController.
  module Oauth
    Error = Class.new(StandardError)

    class << self
      def authorize_url(redirect_uri:, state:)
        query = {
          client_id: Config.client_id,
          redirect_uri: redirect_uri,
          response_type: "code",
          scope: Config::SCOPE,
          state: state
        }
        "#{Config::AUTHORIZE_URL}?#{URI.encode_www_form(query)}"
      end

      # Exchange the auth code for tokens; returns the parsed JSON
      # (access_token, refresh_token, expires_in, scope, …).
      def exchange(code:, redirect_uri:)
        post_token({
          "client_id" => Config.client_id,
          "client_secret" => Config.client_secret,
          "redirect_uri" => redirect_uri,
          "code" => code,
          "grant_type" => "authorization_code"
        }, action: "exchange")
      end

      # Trade a refresh token for a fresh access (and refresh) token.
      def refresh(refresh_token:)
        post_token({
          "client_id" => Config.client_id,
          "client_secret" => Config.client_secret,
          "refresh_token" => refresh_token,
          "grant_type" => "refresh_token"
        }, action: "refresh")
      end

      private

      def post_token(params, action:)
        response = Net::HTTP.post_form(URI(Config::TOKEN_URL), params)
        raise Error, "linear token #{action} status #{response.code}" unless response.code == "200"

        JSON.parse(response.body)
      rescue Error
        raise
      rescue StandardError => error
        raise Error, "#{error.class}: #{error.message}"
      end
    end
  end
end
