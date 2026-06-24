require "base64"

module GithubApp
  # GitHub App OAuth credentials, supplied per deployment as environment
  # variables (.env in development, foreman-loaded). The GitHub App is
  # used here through its user-to-server OAuth side: each member
  # authorizes Metis once and we hold an access + refresh token bound
  # to that member. See docs/connectors.md.
  #
  #   GITHUB_APP_CLIENT_ID      the app's OAuth client id
  #   GITHUB_APP_CLIENT_SECRET  the app's OAuth client secret
  #   GITHUB_APP_SLUG           the app's URL slug (the part after
  #                             `apps/` in https://github.com/apps/<slug>).
  #                             Optional, but without it metis can't
  #                             send the user to install the App on
  #                             their repos after the connect flow —
  #                             and the issued user-to-server token
  #                             can't see anything until they do.
  #
  # The GitHub App must have **"User-to-server token expiration"** active
  # under Settings → Optional features (new Apps default to it) — without
  # it GitHub returns no refresh token and renewals fail when the 8-hour
  # access token lapses.
  class Config
    class << self
      def client_id
        ENV.fetch("GITHUB_APP_CLIENT_ID")
      end

      def client_secret
        ENV.fetch("GITHUB_APP_CLIENT_SECRET")
      end

      def app_slug
        ENV["GITHUB_APP_SLUG"].presence
      end

      # URL that lets the user pick which account/org/repos to install
      # the App on. nil when the deployment hasn't configured the slug
      # — callers fall back to skipping the install redirect.
      def install_url
        return nil if app_slug.blank?

        "https://github.com/apps/#{app_slug}/installations/new"
      end

      # True once the deployment has registered a GitHub App and put
      # the OAuth credentials in the environment.
      def configured?
        ENV["GITHUB_APP_CLIENT_ID"].present? && ENV["GITHUB_APP_CLIENT_SECRET"].present?
      end

      # The App's numeric id (Settings → General → App ID). Drives the
      # server-to-server side: signing the JWT that mints installation
      # tokens. Separate from the user-to-server OAuth client_id above.
      def app_id
        ENV["GITHUB_APP_ID"].presence
      end

      # The App's RSA private key (PEM). Env vars can't hold the PEM's
      # real newlines, and pasting a multiline key breaks dotenv — so the
      # canonical form is **base64 of the whole .pem**, one opaque line
      # (`base64 < key.pem | tr -d '\n'`). For resilience we still accept
      # a raw PEM (if real newlines survived) or a `\n`-escaped one — a
      # value carrying the PEM `-----` banner is used as-is (escapes
      # unwound), anything else is base64-decoded.
      def private_key
        raw = ENV["GITHUB_APP_PRIVATE_KEY"].presence
        return unless raw
        return raw.gsub('\n', "\n") if raw.include?("-----")

        Base64.decode64(raw).presence
      end

      # True once the deployment can mint installation tokens — i.e. it
      # has the App's id and private key, not just the OAuth secrets.
      def app_auth_configured?
        app_id.present? && private_key.present?
      end

      # Which installation to mint `github_bot` tokens for. Optional —
      # when the App is installed in exactly one place it's auto-resolved.
      # Set it (to the numeric id from GET /app/installations) only when
      # the App is installed on more than one account/org, to pick which.
      def installation_id
        ENV["GITHUB_APP_INSTALLATION_ID"].presence
      end

      # Shared secret GitHub signs every webhook delivery with (App
      # Settings → Webhook → Secret). One per deployment — the App has a
      # single webhook URL; `Webhooks::GithubController` rejects any
      # delivery whose HMAC doesn't match. Blank → webhooks are refused.
      def webhook_secret
        ENV["GITHUB_APP_WEBHOOK_SECRET"].presence
      end
    end
  end
end
