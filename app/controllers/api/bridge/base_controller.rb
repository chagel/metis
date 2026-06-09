module Api
  module Bridge
    # Base for the bridge pull API. Authenticated by a Device enrollment
    # token (Authorization: Bearer <token>), not a Devise session — the
    # caller is a daemon / MCP client, not a browser. Each authenticated
    # call doubles as a presence heartbeat.
    class BaseController < ActionController::API
      before_action :authenticate_device!

      private

      attr_reader :current_device

      def authenticate_device!
        @current_device = Device.authenticate(bearer_token)
        return head :unauthorized unless @current_device

        @current_device.seen!
      end

      def bearer_token
        request.headers["Authorization"].to_s[/\ABearer (.+)\z/, 1]
      end
    end
  end
end
