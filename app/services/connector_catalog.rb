require "yaml"
require "erb"

# The connector marketplace catalog: curated MCP-server "apps", loaded
# from config/connector_catalog.yml. Each App is a template — connecting
# one resolves it into a team's Connector. See docs/connectors.md.
class ConnectorCatalog
  PATH = Rails.root.join("config/connector_catalog.yml")

  # One catalog entry — a connectable app.
  App = Data.define(:key, :name, :category, :description,
                    :transport, :definition, :auth, :oauth_provider,
                    :oauth_scopes, :credential, :inputs) do
    def token_auth? = auth == "token"
    def oauth? = auth == "oauth"
    # OAuth via the MCP authorization spec — discovery + Dynamic Client
    # Registration, no pre-registered provider app. See docs/mcp-oauth-connectors.md.
    def mcp_oauth? = auth == "mcp_oauth"

    # The MCP server definition with any %{input} placeholders filled
    # from the user-supplied values.
    def resolved_definition(inputs)
      definition.transform_values do |value|
        next value unless value.is_a?(String)

        value.gsub(/%\{(\w+)\}/) { inputs[Regexp.last_match(1)].to_s }
      end
    end

    # The user's secret, shaped into the credential map (header => value)
    # a ConnectorCredential holds. Empty when the app needs no credential.
    def credential_map_for(secret)
      return {} unless credential

      { credential["header"] => format(credential["format"], token: secret) }
    end
  end

  class << self
    # Every app, in catalog order.
    def all
      @all ||= load_apps
    end

    # The app for a key, or nil.
    def find(key)
      return if key.blank?

      all.find { |app| app.key == key.to_s }
    end

    # Apps grouped by category, for the marketplace gallery.
    def by_category
      all.group_by(&:category)
    end

    private

    def load_apps
      # Process ERB before YAML so entries can interpolate deployment
      # config (e.g. a self-hosted MCP server URL) from the environment.
      raw = ERB.new(File.read(PATH), trim_mode: "-").result
      YAML.safe_load(raw).map do |key, attrs|
        App.new(
          key: key,
          name: attrs["name"],
          category: attrs["category"],
          description: attrs["description"],
          transport: attrs["transport"],
          definition: attrs["definition"] || {},
          auth: attrs["auth"],
          oauth_provider: attrs["oauth_provider"],
          oauth_scopes: Array(attrs["oauth_scopes"]),
          credential: attrs["credential"],
          inputs: attrs["inputs"] || []
        )
      end
    end
  end
end
