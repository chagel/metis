require "net/http"
require "json"

module LinearApp
  # The authorization-code dance for the direct Linear OAuth app: build the
  # consent URL, then exchange the returned code for an access token. Linear
  # tokens are long-lived (no refresh in practice), so we just store the
  # access token. See Connectors::LinearOauthController.
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
      # (access_token, token_type, scope, …).
      def exchange(code:, redirect_uri:)
        uri = URI(Config::TOKEN_URL)
        response = Net::HTTP.post_form(uri, {
          "client_id" => Config.client_id,
          "client_secret" => Config.client_secret,
          "redirect_uri" => redirect_uri,
          "code" => code,
          "grant_type" => "authorization_code"
        })
        raise Error, "linear token exchange status #{response.code}" unless response.code == "200"

        JSON.parse(response.body)
      rescue Error
        raise
      rescue StandardError => error
        raise Error, "#{error.class}: #{error.message}"
      end
    end
  end
end
