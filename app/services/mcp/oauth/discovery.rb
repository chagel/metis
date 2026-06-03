module Mcp
  module Oauth
    # Walks the MCP discovery chain for a resource (the MCP endpoint URL):
    #   resource → protected-resource metadata (RFC 9728)
    #            → authorization_servers[0] → AS metadata (RFC 8414)
    # and returns the endpoints a client needs.
    #
    # The well-known URL is *host-inserted* — the resource path goes after
    # the well-known name (`/.well-known/oauth-protected-resource/mcp`),
    # not before it. Getting this wrong reads as "no DCR" (it's what hid
    # Stripe's registration endpoint on first probe), so we try the
    # host-inserted form first and a bare fallback second.
    class Discovery
      Metadata = Data.define(
        :issuer, :authorization_endpoint, :token_endpoint,
        :registration_endpoint, :code_challenge_methods, :scopes_supported
      )

      def self.call(resource_url)
        new(resource_url).call
      end

      def initialize(resource_url)
        @resource = URI(resource_url)
      end

      def call
        prm = fetch_first(well_known("oauth-protected-resource", @resource))
        raise Error, "no protected-resource metadata for #{@resource}" unless prm

        as = Array(prm["authorization_servers"]).first
        raise Error, "#{@resource} advertises no authorization_servers" if as.blank?

        as_uri = URI(as)
        md = fetch_first(
          well_known("oauth-authorization-server", as_uri) +
          well_known("openid-configuration", as_uri)
        )
        raise Error, "no authorization-server metadata at #{as}" unless md

        Metadata.new(
          issuer: md["issuer"] || as,
          authorization_endpoint: require_field(md, "authorization_endpoint", as),
          token_endpoint: require_field(md, "token_endpoint", as),
          registration_endpoint: md["registration_endpoint"],
          code_challenge_methods: Array(md["code_challenge_methods_supported"]),
          scopes_supported: Array(prm["scopes_supported"]).presence || Array(md["scopes_supported"])
        )
      end

      private

      def well_known(name, base)
        port = base.port == base.default_port ? "" : ":#{base.port}"
        host = "#{base.scheme}://#{base.host}#{port}"
        path = base.path.chomp("/")
        [ "#{host}/.well-known/#{name}#{path}", "#{host}/.well-known/#{name}" ].uniq
      end

      def fetch_first(urls)
        urls.each { |url| (body = Http.get_json(url)) and return body }
        nil
      end

      def require_field(metadata, key, source)
        metadata[key].presence || raise(Error, "#{source} metadata missing #{key}")
      end
    end
  end
end
