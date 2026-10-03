module GithubApp
  # A second GitHub MCP server, `github_bot`, bearing a freshly minted
  # installation token so the agent can act as `<slug>[bot]` — used by
  # the reviewing-code skill to post PR reviews (GitHub forbids
  # approving your own PR, so the personal `github` server can't).
  # Staged only when the deployment is App-auth configured and an admin
  # has enabled the bot on the team's github connector (`bot_enabled`,
  # off by default — the token is installation-wide). See
  # docs/connectors.md.
  module BotServer
    NAME = "github_bot".freeze
    # Same URL and tools as `github`; without this the agent can't tell
    # which identity a call will carry.
    DESCRIPTION = "Same GitHub tools as `github`, but acting as the GitHub App bot " \
                  "instead of the operator. Use it to post PR reviews (approve / request " \
                  "changes) or when an action must come from the bot; otherwise use `github`.".freeze

    # `[NAME, entry]` for Agent::McpConfig, or nil when not eligible or
    # the mint fails — never crashes the turn.
    def self.for(connectors)
      return unless Config.app_auth_configured?

      github = connectors.find { |connector| connector.catalog_app&.oauth_provider == "github" }
      return unless github&.bot_enabled?

      token = InstallationToken.for(github.bot_installation_id)
      entry = github.definition.deep_dup.merge("description" => DESCRIPTION)
      entry["headers"] = (entry["headers"] || {}).merge(github.catalog_app.credential_map_for(token))
      [ NAME, entry ]
    rescue InstallationToken::Error => error
      Rails.logger.error("GithubApp::BotServer: #{NAME} skipped — #{error.message}")
      nil
    end
  end
end
