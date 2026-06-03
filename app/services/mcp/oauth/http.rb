require "net/http"
require "json"

module Mcp
  module Oauth
    # Thin JSON/form HTTP for the OAuth discovery + token endpoints.
    # Discovery probes are best-effort (nil on miss so the caller can try
    # the next well-known URL); registration/token calls raise on failure.
    module Http
      module_function

      # GET JSON, or nil on any non-2xx / network / parse error — lets
      # Discovery fall through to the next candidate URL.
      def get_json(url)
        uri = URI(url)
        request = Net::HTTP::Get.new(uri)
        request["Accept"] = "application/json"
        response = perform(request, uri)
        return nil unless ok?(response)

        JSON.parse(response.body)
      rescue StandardError
        nil
      end

      def post_json(url, payload)
        uri = URI(url)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request.body = payload.to_json
        parse_or_raise(perform(request, uri), url)
      end

      def post_form(url, payload)
        uri = URI(url)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/x-www-form-urlencoded"
        request["Accept"] = "application/json"
        request.body = URI.encode_www_form(payload)
        parse_or_raise(perform(request, uri), url)
      end

      def perform(request, uri)
        request["User-Agent"] = user_agent
        http = Net::HTTP.new(uri.hostname, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 5
        http.read_timeout = 10
        http.request(request)
      end

      # An honest product User-Agent pointing at this deployment. Some MCP
      # servers sit behind a WAF (Cloudflare) that 403s requests with a
      # missing or known-bot UA (e.g. Sentry/Asana/PayPal blocked
      # Python-urllib's default) — an explicit one avoids the block.
      def user_agent
        host = ENV["METIS_APP_HOST"].presence || ENV["METIS_DEV_HOST"].presence || "metis.local"
        "Metis-MCP/1.0 (+https://#{host})"
      end

      def ok?(response)
        response.code.to_i.between?(200, 299)
      end

      def parse_or_raise(response, url)
        unless ok?(response)
          raise Error, "#{url} -> #{response.code}: #{response.body.to_s.truncate(200)}"
        end

        JSON.parse(response.body)
      end
    end
  end
end
