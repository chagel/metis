require "net/http"
require "json"

module Linear
  # Minimal read-only Linear GraphQL client, authed with a member's
  # connector bearer. Used to populate the project picker on the project
  # form — a Rails-side metadata fetch for a UI list, the same shape as
  # GithubApp::InstallationToken.installations. It is *not* an MCP runtime
  # (the agent still reaches Linear through pi-mcp-adapter); this is just a
  # direct API call so the operator can bind a project by name, not UUID.
  class Api
    Error = Class.new(StandardError)

    ENDPOINT = "https://api.linear.app/graphql".freeze
    PROJECTS_QUERY = "{ projects(first: 250) { nodes { id name } } }".freeze

    def initialize(token)
      @token = token
    end

    # The projects this member can see — [{ "id" =>, "name" => }], sorted
    # by name so the picker reads sensibly.
    def projects
      nodes = query(PROJECTS_QUERY).dig("projects", "nodes").to_a
      nodes.map { |node| { "id" => node["id"], "name" => node["name"] } }
           .sort_by { |project| project["name"].to_s.downcase }
    end

    private

    def query(graphql)
      uri = URI(ENDPOINT)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Content-Type"] = "application/json"
      request.body = { query: graphql }.to_json

      response = https_client(uri).request(request)
      raise Error, "linear graphql status #{response.code}" unless response.code == "200"

      body = JSON.parse(response.body)
      raise Error, body["errors"].to_s if body["errors"].present?

      body.fetch("data")
    rescue Error
      raise
    rescue StandardError => error
      raise Error, "#{error.class}: #{error.message}"
    end

    def https_client(uri)
      http = Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 10
      http
    end
  end
end
