require "net/http"
require "json"

module XApp
  # The authorization-code + PKCE dance for the deployment's X OAuth app:
  # build the consent URL, exchange the code, refresh and revoke tokens.
  # X authenticates confidential clients with HTTP Basic on the token
  # endpoint and rotates the refresh token on every refresh. invalid_grant
  # raises OauthBroker::InvalidGrantError so the broker clears the dead
  # grant; every other failure is an Error whose message carries only the
  # provider's error code — never tokens or response bodies.
  module Oauth
    Error = Class.new(StandardError)

    AUTHORIZE_URL = "https://x.com/i/oauth2/authorize".freeze
    TOKEN_URL = "https://api.x.com/2/oauth2/token".freeze
    REVOKE_URL = "https://api.x.com/2/oauth2/revoke".freeze

    class << self
      def authorize_url(state:, code_challenge:)
        query = {
          response_type: "code",
          client_id: Config.client_id,
          redirect_uri: Config.redirect_uri,
          scope: Config::SCOPES.join(" "),
          state: state,
          code_challenge: code_challenge,
          code_challenge_method: "S256"
        }
        "#{AUTHORIZE_URL}?#{URI.encode_www_form(query)}"
      end

      def exchange(code:, code_verifier:)
        post_token({
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => Config.redirect_uri,
          "client_id" => Config.client_id,
          "code_verifier" => code_verifier
        }, action: "exchange")
      end

      def refresh(refresh_token)
        post_token({
          "grant_type" => "refresh_token",
          "refresh_token" => refresh_token,
          "client_id" => Config.client_id
        }, action: "refresh")
      end

      # POST the token to X's revoke endpoint — severs the grant on X's
      # side so the next connect lands as a fresh consent.
      def revoke(token)
        uri = URI(REVOKE_URL)
        request = Net::HTTP::Post.new(uri)
        request.basic_auth(Config.client_id, Config.client_secret)
        request.set_form_data("token" => token, "token_type_hint" => "refresh_token")
        response = https_client(uri).request(request)
        raise Error, "x revoke status #{response.code}" unless response.code == "200"
      end

      private

      def post_token(params, action:)
        uri = URI(TOKEN_URL)
        request = Net::HTTP::Post.new(uri)
        request.basic_auth(Config.client_id, Config.client_secret)
        request["Accept"] = "application/json"
        request.set_form_data(params)
        parse(https_client(uri).request(request), action: action)
      rescue Error, OauthBroker::InvalidGrantError
        raise
      rescue StandardError => error
        raise Error, "x oauth #{action}: #{error.class}"
      end

      def parse(response, action:)
        parsed = JSON.parse(response.body) rescue {}

        if parsed["error"] == "invalid_grant"
          raise OauthBroker::InvalidGrantError, "x invalid_grant: token revoked or expired"
        end

        if response.code != "200" || parsed["error"].present?
          raise Error, "x oauth #{action} status #{response.code}: #{parsed["error"].presence || "unexpected response"}"
        end
        raise Error, "x oauth #{action} response missing access_token" if parsed["access_token"].blank?

        parsed
      end

      def https_client(uri)
        http = Net::HTTP.new(uri.hostname, uri.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)
        http.open_timeout = 5
        http.read_timeout = 10
        http
      end
    end
  end
end
