require "net/http"
require "json"
require "jwt"

module GithubApp
  # The server-to-server side of the GitHub App: mints a short-lived
  # installation access token for one installation, so the agent can act
  # as the App itself (`metis[bot]`) rather than as a member. Used for
  # team-shared GitHub connectors — e.g. an automated code review that
  # must post as a bot, not impersonate the PR author. See
  # docs/connectors.md.
  #
  # GitHub installation tokens live one hour; we cache a little under
  # that and re-mint on expiry. Minting needs the App's id + private key
  # (GithubApp::Config.app_auth_configured?) — distinct from the
  # user-to-server OAuth credentials.
  class InstallationToken
    Error = Class.new(StandardError)

    API_HOST = "api.github.com".freeze
    CACHE_TTL = 50.minutes
    # GitHub caps the App JWT at 10 minutes; stay safely under it.
    JWT_TTL = 9.minutes

    class << self
      # A usable installation token, cached across turns. Raises Error
      # when the deployment can't mint (unconfigured) or GitHub rejects
      # the request — callers treat that as "drop this connector".
      # `installation_id` may be nil — then we use the deployment's
      # GITHUB_APP_INSTALLATION_ID, else resolve the App's sole
      # installation (the common single-org case). With >1 installs and
      # no choice anywhere, raises naming where to pick one.
      def for(installation_id = nil)
        raise Error, "GitHub App auth not configured" unless Config.app_auth_configured?

        id = installation_id.presence || Config.installation_id || sole_installation_id
        Rails.cache.fetch("github_app/installation_token/#{id}", expires_in: CACHE_TTL) do
          mint(id)
        end
      rescue Error
        raise
      rescue StandardError => error
        # Network (Net::*Timeout, Errno::*), signing (OpenSSL::PKey::RSAError),
        # and parsing (JSON::ParserError) failures all become Error, so the
        # one caller (McpConfig#bot_entry, run every turn) needs to rescue
        # only Error — a GitHub blip can't crash an unrelated turn.
        raise Error, "#{error.class}: #{error.message}"
      end

      # The App's installations — [{ "id" =>, "login" =>, "type" => }] —
      # for the connector manage page's picker and for id resolution.
      # Cached like the token; raises Error on the same terms as `for`.
      def installations
        raise Error, "GitHub App auth not configured" unless Config.app_auth_configured?

        Rails.cache.fetch("github_app/installations", expires_in: CACHE_TTL) do
          response = signed_request(Net::HTTP::Get, "/app/installations")
          raise Error, "github installations status #{response.code}" unless response.code == "200"

          JSON.parse(response.body).map do |install|
            { "id" => install["id"].to_s,
              "login" => install.dig("account", "login"),
              "type" => install.dig("account", "type") }
          end
        end
      rescue Error
        raise
      rescue StandardError => error
        raise Error, "#{error.class}: #{error.message}"
      end

      private

      def mint(installation_id)
        parse(signed_request(Net::HTTP::Post, "/app/installations/#{installation_id}/access_tokens"))
      end

      # The id of the App's one installation, for connectors that haven't
      # picked an explicit one.
      def sole_installation_id
        ids = installation_ids
        raise Error, "GitHub App has no installations" if ids.empty?
        if ids.size > 1
          raise Error, "GitHub App has #{ids.size} installations (#{ids.join(', ')}); " \
                       "pick one on the connector's manage page or set GITHUB_APP_INSTALLATION_ID"
        end

        ids.first
      end

      def installation_ids
        installations.map { |install| install["id"] }
      end

      # An App-JWT-authenticated request to the GitHub API.
      def signed_request(klass, path)
        uri = URI("https://#{API_HOST}#{path}")
        request = klass.new(uri)
        request["Authorization"] = "Bearer #{app_jwt}"
        request["Accept"] = "application/vnd.github+json"
        request["X-GitHub-Api-Version"] = "2022-11-28"
        https_client(uri).request(request)
      end

      def parse(response)
        unless response.code == "201"
          raise Error, "github installation token status #{response.code}: #{response.body.to_s.truncate(200)}"
        end

        JSON.parse(response.body).fetch("token")
      end

      # A 9-minute App JWT signed with the deployment's private key. iat
      # is backdated 60s to tolerate clock skew between us and GitHub.
      def app_jwt
        now = Time.now.to_i
        payload = { iat: now - 60, exp: now + JWT_TTL.to_i, iss: Config.app_id }
        JWT.encode(payload, OpenSSL::PKey::RSA.new(Config.private_key), "RS256")
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
